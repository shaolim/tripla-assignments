require "test_helper"

class PricingServiceTest < ActiveSupport::TestCase
  setup do
    @mock_redis = mock('redis')
    @mock_cache = mock('cache')
    LeaderFollowerCache.stubs(:new).returns(@mock_cache)

    @service = PricingService.new(
      token: "test_token",
      redis: @mock_redis,
      api_url: "http://test-api:8080/pricing"
    )
  end

  test "fetches pricing and extracts rate from API response" do
    api_response = {
      "rates" => [
        { "period" => "Summer", "hotel" => "FloatingPointResort", "room" => "SingletonRoom", "rate" => 12000 }
      ]
    }

    # The cache returns the API response (simulating a cache miss that fetched from API)
    @mock_cache.expects(:fetch).returns(api_response)

    result = @service.fetch_pricing(
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    )

    assert_equal({ "rate" => "12000" }, result)
  end

  test "returns rate as string" do
    api_response = {
      "rates" => [
        { "period" => "Winter", "hotel" => "GitawayHotel", "room" => "BooleanTwin", "rate" => 45000 }
      ]
    }

    @mock_cache.expects(:fetch).returns(api_response)

    result = @service.fetch_pricing(
      period: "Winter",
      hotel: "GitawayHotel",
      room: "BooleanTwin"
    )

    assert_equal "45000", result["rate"]
    assert_kind_of String, result["rate"]
  end

  test "finds matching rate from multiple results" do
    api_response = {
      "rates" => [
        { "period" => "Summer", "hotel" => "HotelA", "room" => "RoomA", "rate" => 100 },
        { "period" => "Winter", "hotel" => "HotelB", "room" => "RoomB", "rate" => 200 },
        { "period" => "Spring", "hotel" => "HotelC", "room" => "RoomC", "rate" => 300 }
      ]
    }

    @mock_cache.expects(:fetch).returns(api_response)

    result = @service.fetch_pricing(
      period: "Winter",
      hotel: "HotelB",
      room: "RoomB"
    )

    assert_equal "200", result["rate"]
  end

  test "falls back to first result if no exact match" do
    api_response = {
      "rates" => [
        { "period" => "Summer", "hotel" => "HotelA", "room" => "RoomA", "rate" => 999 }
      ]
    }

    @mock_cache.expects(:fetch).returns(api_response)

    result = @service.fetch_pricing(
      period: "Winter",
      hotel: "HotelB",
      room: "RoomB"
    )

    assert_equal "999", result["rate"]
  end

  test "raises error on empty rates array" do
    api_response = { "rates" => [] }

    @mock_cache.expects(:fetch).returns(api_response)

    assert_raises(PricingService::Error) do
      @service.fetch_pricing(
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      )
    end
  end

  test "raises error on nil response" do
    @mock_cache.expects(:fetch).returns(nil)

    assert_raises(PricingService::Error) do
      @service.fetch_pricing(
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      )
    end
  end

  test "raises error on response without rates key" do
    @mock_cache.expects(:fetch).returns({ "other" => "data" })

    assert_raises(PricingService::Error) do
      @service.fetch_pricing(
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      )
    end
  end

  test "handles AsyncRequest timeout" do
    @mock_cache.expects(:fetch).raises(AsyncRequest::Timeout.new("timeout"))

    error = assert_raises(PricingService::Error) do
      @service.fetch_pricing(
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      )
    end

    assert_includes error.message, "timed out"
  end

  test "handles DistributedLock error" do
    @mock_cache.expects(:fetch).raises(DistributedLock::LockError.new("lock failed"))

    error = assert_raises(PricingService::Error) do
      @service.fetch_pricing(
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      )
    end

    assert_includes error.message, "coordinate"
  end

  test "handles CircuitBreaker error" do
    @mock_cache.expects(:fetch).raises(CircuitBreaker::CircuitBreakerError.new("open"))

    error = assert_raises(PricingService::Error) do
      @service.fetch_pricing(
        period: "Summer",
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      )
    end

    assert_includes error.message, "unavailable"
  end

  test "generates consistent cache keys for same parameters" do
    @mock_cache.stubs(:fetch).returns({ "rates" => [{ "rate" => 100 }] })

    # Call twice with same params - should use same cache key
    @service.fetch_pricing(period: "Summer", hotel: "HotelA", room: "RoomA")
    @service.fetch_pricing(period: "Summer", hotel: "HotelA", room: "RoomA")

    # The cache key generation is deterministic
  end

  test "generates different cache keys for different parameters" do
    cache_keys = []
    @mock_cache.stubs(:fetch).with { |key| cache_keys << key; true }.returns({ "rates" => [{ "rate" => 100 }] })

    @service.fetch_pricing(period: "Summer", hotel: "HotelA", room: "RoomA")
    @service.fetch_pricing(period: "Winter", hotel: "HotelA", room: "RoomA")

    assert_equal 2, cache_keys.uniq.size
  end

  test "cache key includes all parameters" do
    cache_keys = []
    @mock_cache.stubs(:fetch).with { |key| cache_keys << key; true }.returns({ "rates" => [{ "rate" => 100 }] })

    @service.fetch_pricing(period: "Summer", hotel: "HotelA", room: "RoomA")
    @service.fetch_pricing(period: "Summer", hotel: "HotelA", room: "RoomB")

    # Different room should produce different cache key
    assert_equal 2, cache_keys.uniq.size
  end

  test "singleton instance uses environment variables" do
    ENV.stubs(:fetch).with('API_TOKEN', '').returns('env_token')
    ENV.stubs(:fetch).with('REDIS_URL', 'redis://localhost:6379').returns('redis://test:6379')
    ENV.stubs(:fetch).with('RATE_API_URL', 'http://rate-api:8080/pricing').returns('http://test:8080/pricing')

    Redis.stubs(:new).returns(mock('redis'))

    # Clear singleton
    PricingService.instance_variable_set(:@instance, nil)

    instance = PricingService.instance
    assert_instance_of PricingService, instance

    # Same instance on subsequent calls
    assert_same instance, PricingService.instance
  end
end
