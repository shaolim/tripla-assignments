require "test_helper"

class LeaderFollowerCacheTest < ActiveSupport::TestCase
  setup do
    @mock_redis = MockRedis.new
    @cache = LeaderFollowerCache.new(redis: @mock_redis, ttl: 300)
  end

  test "returns cached value on cache hit" do
    @mock_redis.set("test:key", '{"rate": 12000}')

    result = @cache.fetch("test:key") { raise "should not be called" }

    assert_equal({ "rate" => 12000 }, result)
  end

  test "returns nil for non-existent key via get" do
    result = @cache.get("missing:key")

    assert_nil result
  end

  test "sets value with correct JSON encoding" do
    @cache.set("test:key", { "rate" => 100 })

    stored = @mock_redis.get("test:key")
    assert_equal '{"rate":100}', stored
  end

  test "deletes key and stale key" do
    @mock_redis.set("test:key", "value")
    @mock_redis.set("stale:test:key", "stale_value")

    @cache.delete("test:key")

    assert_nil @mock_redis.get("test:key")
    assert_nil @mock_redis.get("stale:test:key")
  end

  test "handles invalid JSON in cache gracefully" do
    @mock_redis.set("bad:key", "not json")

    result = @cache.get("bad:key")

    assert_nil result
  end

  test "returns circuit breaker state" do
    state = @cache.circuit_breaker_state

    assert_includes state.keys, :state
    assert_includes state.keys, :failure_count
    assert_includes state.keys, :last_failure
    assert_equal :closed, state[:state]
  end

  test "reset_circuit_breaker delegates to circuit breaker" do
    # Open the circuit breaker first by simulating failures
    breaker = @cache.instance_variable_get(:@circuit_breaker)
    5.times { breaker.record_failure }

    assert breaker.open?

    @cache.reset_circuit_breaker

    assert breaker.closed?
  end

  test "uses stale cache when circuit breaker is open" do
    # Open the circuit breaker
    breaker = @cache.instance_variable_get(:@circuit_breaker)
    5.times { breaker.record_failure }

    # Setup stale cache
    @mock_redis.set("stale:test:key", '{"rate": 9999}')

    result = @cache.fetch("test:key") { raise "should not call API" }

    assert_equal({ "rate" => 9999 }, result)
  end

  test "raises error when no fallback available" do
    # Open the circuit breaker
    breaker = @cache.instance_variable_get(:@circuit_breaker)
    5.times { breaker.record_failure }

    # No cache at all

    assert_raises(PricingService::Error) do
      @cache.fetch("test:key") { raise "should not call API" }
    end
  end

  test "fetches and caches value when cache miss" do
    result = @cache.fetch("new:key") { { "rate" => 500 } }

    assert_equal({ "rate" => 500 }, result)

    # Verify it was cached
    cached = @mock_redis.get("new:key")
    assert_equal '{"rate":500}', cached

    # Verify stale copy was created
    stale = @mock_redis.get("stale:new:key")
    assert_equal '{"rate":500}', stale
  end

  test "returns cached value on subsequent fetch" do
    # First fetch - cache miss
    call_count = 0
    result1 = @cache.fetch("key1") do
      call_count += 1
      { "rate" => 100 }
    end

    # Second fetch - should use cache
    result2 = @cache.fetch("key1") do
      call_count += 1
      { "rate" => 999 }
    end

    assert_equal 1, call_count
    assert_equal({ "rate" => 100 }, result1)
    assert_equal({ "rate" => 100 }, result2)
  end
end

class LeaderFollowerCacheWithMocksTest < ActiveSupport::TestCase
  test "publishes result to followers after leader fetches" do
    mock_redis = mock('redis')

    # Cache miss
    mock_redis.stubs(:get).with("test:key").returns(nil)

    # Lock acquisition succeeds
    mock_redis.stubs(:set).returns(true)

    # Lock extension and release
    mock_redis.stubs(:eval).returns(1)

    # Cache the result
    mock_redis.stubs(:set).with("test:key", anything, ex: anything)
    mock_redis.stubs(:set).with("stale:test:key", anything, ex: anything)

    # Simulate followers waiting - return queue names then nil
    mock_redis.stubs(:rpop).with("waiters:test:key")
      .returns("waiter:queue:1")
      .then.returns("waiter:queue:2")
      .then.returns(nil)

    # Notify followers
    mock_redis.stubs(:lpush)

    # Cleanup
    mock_redis.stubs(:del)

    cache = LeaderFollowerCache.new(redis: mock_redis, ttl: 300)
    result = cache.fetch("test:key") { { "rate" => 500 } }

    assert_equal({ "rate" => 500 }, result)
  end

  test "becomes follower when lock acquisition fails and uses stale cache on timeout" do
    mock_redis = mock('redis')

    # Cache miss for fresh data
    mock_redis.stubs(:get).with("test:key").returns(nil)

    # Stale cache exists
    mock_redis.stubs(:get).with("stale:test:key").returns('{"rate": 111}')

    # Lock acquisition fails
    mock_redis.expects(:set).with("lock:test:key", anything, nx: true, ex: 60).returns(nil)

    # Follower registration
    mock_redis.stubs(:lpush)
    mock_redis.stubs(:expire)
    mock_redis.stubs(:del)

    # BRPOP times out (returns nil), then retries also timeout
    mock_redis.stubs(:brpop).returns(nil)

    cache = LeaderFollowerCache.new(redis: mock_redis, ttl: 300)
    result = cache.fetch("test:key") { raise "leader should not run" }

    # Should return stale cache after follower timeout
    assert_equal({ "rate" => 111 }, result)
  end

  test "follower receives result from leader via BRPOP" do
    mock_redis = mock('redis')

    # Cache miss
    mock_redis.stubs(:get).returns(nil)

    # Lock acquisition fails - become follower
    mock_redis.expects(:set).with("lock:test:key", anything, nx: true, ex: 60).returns(nil)

    # Follower registration
    mock_redis.stubs(:lpush)
    mock_redis.stubs(:expire)
    mock_redis.stubs(:del)

    # BRPOP returns result from leader
    mock_redis.expects(:brpop).returns(["waiter:queue", '{"rate": 222}'])

    cache = LeaderFollowerCache.new(redis: mock_redis, ttl: 300)
    result = cache.fetch("test:key") { raise "should not execute" }

    assert_equal({ "rate" => 222 }, result)
  end
end
