require "test_helper"

class CircuitBreakerTest < ActiveSupport::TestCase
  setup do
    @breaker = CircuitBreaker.new(threshold: 3, timeout: 1)
  end

  test "starts in closed state" do
    assert @breaker.closed?
    refute @breaker.open?
    refute @breaker.half_open?
  end

  test "remains closed after successful calls" do
    5.times do
      result = @breaker.call { "success" }
      assert_equal "success", result
    end

    assert @breaker.closed?
    assert_equal 0, @breaker.failure_count
  end

  test "opens after reaching failure threshold" do
    3.times do
      assert_raises(RuntimeError) do
        @breaker.call { raise "API error" }
      end
    end

    assert @breaker.open?
    assert_equal 3, @breaker.failure_count
  end

  test "rejects requests when open" do
    # Open the circuit
    3.times do
      assert_raises(RuntimeError) { @breaker.call { raise "error" } }
    end

    # Should reject without executing block
    block_executed = false
    assert_raises(CircuitBreaker::CircuitBreakerError) do
      @breaker.call { block_executed = true }
    end
    refute block_executed
  end

  test "transitions to half-open after timeout" do
    # Open the circuit
    3.times do
      assert_raises(RuntimeError) { @breaker.call { raise "error" } }
    end
    assert @breaker.open?

    # Wait for timeout
    sleep(1.1)

    # Next call should transition to half-open and execute
    result = @breaker.call { "recovered" }
    assert_equal "recovered", result
    assert @breaker.closed? # Success closes the circuit
  end

  test "reopens from half-open on failure" do
    # Open the circuit
    3.times do
      assert_raises(RuntimeError) { @breaker.call { raise "error" } }
    end

    # Wait for timeout
    sleep(1.1)

    # Fail in half-open state
    assert_raises(RuntimeError) do
      @breaker.call { raise "still failing" }
    end

    assert @breaker.open?
  end

  test "resets failure count on success" do
    # Record some failures (not enough to open)
    2.times do
      assert_raises(RuntimeError) { @breaker.call { raise "error" } }
    end
    assert_equal 2, @breaker.failure_count

    # Successful call resets count
    @breaker.call { "success" }
    assert_equal 0, @breaker.failure_count
  end

  test "manual reset works" do
    # Open the circuit
    3.times do
      assert_raises(RuntimeError) { @breaker.call { raise "error" } }
    end
    assert @breaker.open?

    # Manual reset
    @breaker.reset
    assert @breaker.closed?
    assert_equal 0, @breaker.failure_count
    assert_nil @breaker.last_failure_time
  end

  test "records last failure time" do
    assert_nil @breaker.last_failure_time

    assert_raises(RuntimeError) { @breaker.call { raise "error" } }

    refute_nil @breaker.last_failure_time
    assert_in_delta Time.current, @breaker.last_failure_time, 1
  end

  test "is thread-safe" do
    threads = 10.times.map do
      Thread.new do
        100.times do
          begin
            @breaker.call { "success" }
          rescue CircuitBreaker::CircuitBreakerError
            # Expected when circuit is open
          end
        end
      end
    end

    threads.each(&:join)
    # Should not raise any threading errors
  end
end
