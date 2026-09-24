module Kulla
  # Thread-safe bounded FIFO. When full, the oldest event is dropped and counted.
  class Buffer
    attr_reader :capacity

    def initialize(capacity)
      @capacity = [ capacity.to_i, 1 ].max
      @items = []
      @dropped = 0
      @mutex = Mutex.new
    end

    # Returns the size after the push.
    def push(event)
      @mutex.synchronize do
        if @items.size >= @capacity
          @items.shift
          @dropped += 1
        end
        @items << event
        @items.size
      end
    end
    alias_method :<<, :push

    def shift(count)
      @mutex.synchronize { @items.shift(count) }
    end

    def size
      @mutex.synchronize { @items.size }
    end

    def empty?
      size.zero?
    end

    # Returns the number of events dropped since the last call and resets the counter.
    def take_dropped
      @mutex.synchronize do
        dropped = @dropped
        @dropped = 0
        dropped
      end
    end

    def clear
      @mutex.synchronize do
        @items.clear
        @dropped = 0
      end
    end
  end
end
