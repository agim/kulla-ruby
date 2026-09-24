require "test_helper"

class BufferTest < Minitest::Test
  def test_push_and_shift_in_order
    buffer = Kulla::Buffer.new(10)
    3.times { |i| buffer.push(i) }

    assert_equal [ 0, 1 ], buffer.shift(2)
    assert_equal [ 2 ], buffer.shift(5)
    assert buffer.empty?
  end

  def test_overflow_drops_oldest_and_counts
    buffer = Kulla::Buffer.new(3)
    5.times { |i| buffer.push(i) }

    assert_equal 3, buffer.size
    assert_equal [ 2, 3, 4 ], buffer.shift(10)
    assert_equal 2, buffer.take_dropped
    assert_equal 0, buffer.take_dropped
  end

  def test_push_returns_size
    buffer = Kulla::Buffer.new(2)
    assert_equal 1, buffer.push(:a)
    assert_equal 2, buffer.push(:b)
    assert_equal 2, buffer.push(:c)
  end

  def test_concurrent_pushes_stay_bounded
    buffer = Kulla::Buffer.new(100)
    threads = 8.times.map { Thread.new { 1_000.times { |i| buffer.push(i) } } }
    threads.each(&:join)

    assert_equal 100, buffer.size
    assert_equal 7_900, buffer.take_dropped
  end
end
