require "fileutils"

module Kulla
  # A shared append-only journal. Network delivery holds its own lock, never
  # the append lock. Acknowledgements are atomic and tied to a generation.
  # Compaction replaces the journal before resetting the cursor: a crash between
  # the two is recoverable without skipping new logs.
  #
  # Bounded: at most max_events pending records and max_bytes of them. Past
  # either, the oldest tenth is dropped and one loss record (from on_drop) takes
  # its place, so an outage costs the oldest logs, never the host's disk.
  # A push writes and flushes to the OS (a crashed process loses nothing); the
  # worker calls #sync to fsync, so no request thread waits on the disk.
  class Spool
    Batch = Struct.new(:events, :generation, :start, :finish, keyword_init: true)
    MAX_EVENTS = 10_000
    MAX_BYTES = 64 * 1_048_576
    # Compact once the delivered or dropped prefix is larger than this and than the pending part.
    MIN_COMPACT_BYTES = 1_048_576
    # rejected.ndjson rotates to rejected.1.ndjson past this size; one rotation is kept.
    MAX_REJECTED_BYTES = 1_048_576
    attr_reader :directory, :max_events, :max_bytes

    def initialize(directory, max_events: MAX_EVENTS, max_bytes: MAX_BYTES, on_drop: nil)
      @directory = File.expand_path(directory)
      FileUtils.mkdir_p(@directory, mode: 0o700)
      raise IOError, "Kulla spool directory must not be a symlink" if File.symlink?(@directory)
      File.chmod(0o700, @directory)
      @max_events = [ max_events.to_i, 10 ].max
      @max_bytes = [ max_bytes.to_i, 65_536 ].max
      @on_drop = on_drop
      @mutex = Mutex.new
      @open_files = []
      @tally = nil
      @dirty = false
      @dropped = 0
    end

    def push(event)
      event = event.merge("id" => event["id"] || SecureRandom.uuid)
      line = JSON.generate(event) << "\n"
      locked do
        data do |file, header, start|
          repair_tail(file, start)
          append(file, header, start, line)
          enforce_limits(file, header, start)
        end
        @dirty = true
      end
    end

    # fsyncs what this process appended. Called from the worker, outside the append lock.
    def sync
      return false unless @dirty
      @dirty = false
      open_file("logs.ndjson", File::RDONLY) { |file| file.fsync }
      true
    rescue Errno::ENOENT
      false
    end

    def peek(limit)
      locked do
        data do |file, header, start|
          repair_tail(file, start)
          state = position(header, start, file.size)
          file.seek(state)
          events = []
          limit.times do
            line = file.gets
            break unless line
            raise IOError, "Kulla spool has an incomplete record; records retained" unless line.end_with?("\n")
            events << JSON.parse(line)
          end
          Batch.new(events: events, generation: header.fetch("generation"), start: state, finish: file.pos)
        end
      end
    end

    # Records the batch as delivered. Drops while the batch was in flight only move the cursor
    # forward, so they never undo an acknowledgement.
    def acknowledge(batch)
      locked do
        data do |file, header, start|
          raise IOError, "Kulla spool generation changed" unless header["generation"] == batch.generation
          current = position(header, start, file.size)
          raise IOError, "Kulla spool cursor changed" if current < batch.start
          offset = [ current, batch.finish ].max
          if offset == file.size
            reset
          else
            write_cursor(header, offset)
            @tally = nil
            compact(file, header, start, offset) if compact?(start, offset, file.size)
          end
        end
      end
    end

    def quarantine(events, reasons)
      return if events.empty?
      locked do
        content = JSON.generate({ "at" => Time.now.utc.iso8601, "reason" => reasons, "events" => events }) << "\n"
        path = File.join(@directory, "rejected.ndjson")
        if File.exist?(path) && File.size(path) + content.bytesize > MAX_REJECTED_BYTES
          File.rename(path, File.join(@directory, "rejected.1.ndjson"))
        end
        open_file("rejected.ndjson", File::WRONLY | File::CREAT | File::APPEND) { |file| file.write(content); file.flush; file.fsync }
      end
    end

    def with_delivery_lock
      open_file("delivery.lock") do |lock|
        return false unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        begin
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end
      true
    end

    def empty?
      size.zero?
    end

    # Pending records, across every process sharing the journal.
    def size
      locked { data { |file, header, start| pending(file, header, start)[:count] } }
    end

    # Records this process dropped since the last call (each drop also wrote a loss record).
    def take_dropped
      @mutex.synchronize { @dropped.tap { @dropped = 0 } }
    end

    def due_in(interval)
      locked do
        data { |_file, header, _start| [ interval.to_f - (Time.now - Time.iso8601(header.fetch("created_at"))), 0 ].max }
      end
    end

    # A fork must close inherited lock descriptors before starting its worker.
    # Closing the child's copy does not release descriptors the parent owns.
    def close_inherited_files
      @open_files.each { |file| file.close unless file.closed? }
      @open_files = []
    end

    private

    def locked(&block)
      @mutex.synchronize do
        open_file("append.lock") do |lock|
          lock.flock(File::LOCK_EX)
          begin
            block.call
          ensure
            lock.flock(File::LOCK_UN)
          end
        end
      end
    end

    def open_file(name, flags = File::RDWR | File::CREAT)
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      file = File.open(File.join(@directory, name), flags, 0o600)
      @open_files << file
      begin
        File.chmod(0o600, file.path) unless flags & (File::WRONLY | File::RDWR) == 0
        yield file
      ensure
        file.close unless file.closed?
        @open_files.delete(file)
      end
    end

    def data
      open_file("logs.ndjson") do |file|
        if file.size.zero?
          file.write(JSON.generate({ "generation" => SecureRandom.uuid, "created_at" => Time.now.utc.iso8601(6) }) << "\n")
          file.flush
          file.fsync
        end
        file.rewind
        header = JSON.parse(file.gets.to_s)
        raise IOError, "Invalid Kulla spool header; journal retained" unless header["generation"] && header["created_at"]
        yield file, header, file.pos
      end
    end

    def append(file, header, start, line)
      tally = pending(file, header, start)
      file.seek(0, IO::SEEK_END)
      file.write(line)
      file.flush
      @tally = tally.merge(size: file.size, count: tally[:count] + 1)
    end

    # { generation:, cursor:, size:, count: } for the records after the cursor. Counts only the
    # bytes appended since the last look when nothing else moved the cursor or replaced the file.
    def pending(file, header, start)
      size = file.size
      cursor = position(header, start, size)
      tally = @tally
      if tally && tally[:generation] == header["generation"] && tally[:cursor] == cursor && tally[:size] <= size
        count = tally[:count] + newlines(file, tally[:size], size)
      else
        count = newlines(file, cursor, size)
      end
      @tally = { generation: header["generation"], cursor: cursor, size: size, count: count }
    end

    def newlines(file, from, to)
      count = 0
      file.seek(from)
      while from < to
        chunk = file.read([ 1_048_576, to - from ].min) or break
        count += chunk.count("\n")
        from += chunk.bytesize
      end
      count
    end

    # Past either limit, drop the oldest records down to 90% of both and record the loss.
    def enforce_limits(file, header, start)
      tally = @tally
      return if tally[:count] <= @max_events && tally[:size] - tally[:cursor] <= @max_bytes

      keep_events = @max_events * 9 / 10
      keep_bytes = @max_bytes * 9 / 10
      offset = tally[:cursor]
      count = tally[:count]
      dropped = 0
      file.seek(offset)
      while count > keep_events || tally[:size] - offset > keep_bytes
        line = file.gets or break
        break unless line.end_with?("\n")
        offset += line.bytesize
        count -= 1
        dropped += 1
      end
      return if dropped.zero?

      write_cursor(header, offset)
      @tally = { generation: header["generation"], cursor: offset, size: tally[:size], count: count }
      @dropped += dropped
      Kulla.log("Kulla spool full; dropped the #{dropped} oldest records", level: :warn)
      if compact?(start, offset, tally[:size])
        compact(file, header, start, offset)
        file = nil
      end
      record_loss(dropped, file)
    end

    def record_loss(dropped, file)
      loss = @on_drop&.call(dropped)
      return unless loss
      line = JSON.generate(loss.merge("id" => loss["id"] || SecureRandom.uuid)) << "\n"
      if file
        file.seek(0, IO::SEEK_END)
        file.write(line)
        file.flush
        @tally = @tally.merge(size: file.size, count: @tally[:count] + 1)
      else
        data { |fresh, header, start| append(fresh, header, start, line) }
      end
    end

    def compact?(start, offset, size)
      dead = offset - start
      dead > MIN_COMPACT_BYTES && dead > size - offset
    end

    # Rewrites the journal as a new generation holding only the records after offset.
    def compact(file, header, start, offset)
      file.seek(offset)
      tail = file.read.to_s
      fresh = { "generation" => SecureRandom.uuid, "created_at" => header.fetch("created_at") }
      line = JSON.generate(fresh) << "\n"
      atomic("logs.ndjson", line + tail)
      atomic("cursor.json", JSON.generate({ "generation" => fresh["generation"], "offset" => line.bytesize }))
      @tally = nil
    end

    # Everything is delivered: start an empty generation (a new created_at restarts the interval).
    def reset
      fresh = { "generation" => SecureRandom.uuid, "created_at" => Time.now.utc.iso8601(6) }
      line = JSON.generate(fresh) << "\n"
      atomic("logs.ndjson", line)
      atomic("cursor.json", JSON.generate({ "generation" => fresh["generation"], "offset" => line.bytesize }))
      @tally = nil
    end

    def write_cursor(header, offset)
      atomic("cursor.json", JSON.generate({ "generation" => header.fetch("generation"), "offset" => offset }))
    end

    def position(header, start, size)
      state = JSON.parse(File.read(File.join(@directory, "cursor.json")))
      offset = Integer(state["offset"])
      state["generation"] == header["generation"] && offset >= start && offset <= size ? offset : start
    rescue Errno::ENOENT, JSON::ParserError, ArgumentError, TypeError
      start
    end

    def repair_tail(file, start)
      file.seek(-1, IO::SEEK_END)
      return if file.read(1) == "\n"
      offset = file.size
      keep = start
      while offset > start
        length = [ 65_536, offset - start ].min
        offset -= length
        file.seek(offset)
        newline = file.read(length).rindex("\n")
        if newline
          keep = offset + newline + 1
          break
        end
      end
      file.seek(keep)
      atomic("incomplete-#{SecureRandom.uuid}.ndjson", file.read)
      file.truncate(keep)
      file.flush
      file.fsync
      @tally = nil
      Kulla.log("incomplete spool tail retained separately after interrupted write", level: :warn)
    end

    def atomic(name, content)
      temp = ".#{name}.#{SecureRandom.uuid}.tmp"
      begin
        open_file(temp, File::WRONLY | File::CREAT | File::EXCL) { |file| file.write(content); file.flush; file.fsync }
        File.rename(File.join(@directory, temp), File.join(@directory, name))
        File.open(@directory, File::RDONLY, &:fsync)
      ensure
        File.unlink(File.join(@directory, temp)) if File.exist?(File.join(@directory, temp))
      end
    end
  end
end
