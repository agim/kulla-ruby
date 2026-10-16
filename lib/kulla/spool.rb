require "fileutils"

module Kulla
  # A shared append-only journal. Network delivery holds its own lock, never
  # the append lock. Acknowledgements are atomic and tied to a generation.
  # Compaction replaces an entirely acknowledged journal before resetting the
  # cursor: a crash between the two is recoverable without skipping new logs.
  class Spool
    Batch = Struct.new(:events, :generation, :start, :finish, keyword_init: true)
    attr_reader :directory

    def initialize(directory)
      @directory = File.expand_path(directory)
      FileUtils.mkdir_p(@directory, mode: 0o700)
      raise IOError, "Kulla spool directory must not be a symlink" if File.symlink?(@directory)
      File.chmod(0o700, @directory)
      @mutex = Mutex.new
      @open_files = []
      @pending = 0
    end

    def push(event)
      event = event.merge("id" => event["id"] || SecureRandom.uuid)
      locked do
        data do |file, _header, start|
          repair_tail(file, start)
          file.seek(0, IO::SEEK_END)
          file.write(JSON.generate(event) << "\n")
          file.flush
          file.fsync
        end
        @pending += 1
      end
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

    def acknowledge(batch)
      locked do
        data do |file, header, start|
          raise IOError, "Kulla spool generation changed" unless header["generation"] == batch.generation
          raise IOError, "Kulla spool cursor changed" unless position(header, start, file.size) == batch.start
          atomic("cursor.json", JSON.generate({ "generation" => batch.generation, "offset" => batch.finish }))
          @pending = [@pending - batch.events.size, 0].max
          if batch.finish == file.size
            fresh = { "generation" => SecureRandom.uuid, "created_at" => Time.now.utc.iso8601(6) }
            line = JSON.generate(fresh) << "\n"
            atomic("logs.ndjson", line)
            atomic("cursor.json", JSON.generate({ "generation" => fresh["generation"], "offset" => line.bytesize }))
          end
        end
      end
    end

    def quarantine(events, reasons)
      return if events.empty?
      locked do
        content = JSON.generate({ "at" => Time.now.utc.iso8601, "reason" => reasons, "events" => events }) << "\n"
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
      peek(1).events.empty?
    end

    def size
      empty? ? 0 : [@pending, 1].max
    end

    def due_in(interval)
      locked do
        data { |_file, header, _start| [interval.to_f - (Time.now - Time.iso8601(header.fetch("created_at"))), 0].max }
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
        File.chmod(0o600, file.path)
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
        length = [65_536, offset - start].min
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
