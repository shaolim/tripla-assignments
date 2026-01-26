require "test_helper"

class AsyncRequestTest < ActiveSupport::TestCase
  setup do
    @mock_redis = mock('redis')
  end

  test "creates request with unique waiter queue" do
    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)

    request1 = AsyncRequest.new("cache:key", redis: @mock_redis)
    request2 = AsyncRequest.new("cache:key", redis: @mock_redis)

    refute_equal request1.waiter_queue, request2.waiter_queue
    assert_match(/^waiter:cache:key:/, request1.waiter_queue)
  end

  test "registers in waiters list on create" do
    @mock_redis.expects(:lpush).with("waiters:cache:key", anything)
    @mock_redis.expects(:expire).with(anything, 60) # timeout + 5

    AsyncRequest.create("cache:key", redis: @mock_redis, timeout: 55)
  end

  test "sets expiration on waiter queue" do
    @mock_redis.stubs(:lpush)
    @mock_redis.expects(:expire).with(anything, 25) # 20 + 5

    AsyncRequest.create("cache:key", redis: @mock_redis, timeout: 20)
  end

  test "wait returns parsed JSON result" do
    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)
    @mock_redis.stubs(:del)
    @mock_redis.expects(:brpop).returns(["queue", '{"rate": 12000}'])

    request = AsyncRequest.create("cache:key", redis: @mock_redis, timeout: 5)
    result = request.wait!

    assert_equal({ "rate" => 12000 }, result)
  end

  test "raises Timeout when BRPOP returns nil" do
    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)
    @mock_redis.stubs(:del)
    @mock_redis.expects(:brpop).returns(nil)

    request = AsyncRequest.create("cache:key", redis: @mock_redis, timeout: 5)

    error = assert_raises(AsyncRequest::Timeout) do
      request.wait!
    end

    assert_includes error.message, "5s"
    assert_includes error.message, "cache:key"
  end

  test "cleans up waiter queue after successful wait" do
    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)
    @mock_redis.stubs(:brpop).returns(["queue", '{"rate": 100}'])
    @mock_redis.expects(:del).at_least_once

    request = AsyncRequest.create("cache:key", redis: @mock_redis)
    request.wait!
  end

  test "cleans up waiter queue after timeout" do
    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)
    @mock_redis.stubs(:brpop).returns(nil)
    @mock_redis.expects(:del).at_least_once

    request = AsyncRequest.create("cache:key", redis: @mock_redis, timeout: 1)

    assert_raises(AsyncRequest::Timeout) { request.wait! }
  end

  test "raises error on invalid JSON payload" do
    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)
    @mock_redis.stubs(:del)
    @mock_redis.expects(:brpop).returns(["queue", "not valid json"])

    request = AsyncRequest.create("cache:key", redis: @mock_redis)

    assert_raises(RuntimeError) do
      request.wait!
    end
  end

  test "handles complex JSON payloads" do
    complex_response = {
      "rates" => [
        { "period" => "Summer", "hotel" => "Hotel", "room" => "Room", "rate" => 99999 }
      ],
      "metadata" => { "cached" => true }
    }

    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)
    @mock_redis.stubs(:del)
    @mock_redis.expects(:brpop).returns(["queue", complex_response.to_json])

    request = AsyncRequest.create("cache:key", redis: @mock_redis)
    result = request.wait!

    assert_equal complex_response, result
  end

  test "uses correct timeout for BRPOP" do
    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)
    @mock_redis.stubs(:del)
    @mock_redis.expects(:brpop).with(anything, timeout: 30).returns(["queue", '{}'])

    request = AsyncRequest.create("cache:key", redis: @mock_redis, timeout: 30)
    request.wait!
  end

  test "stores key reference" do
    @mock_redis.stubs(:lpush)
    @mock_redis.stubs(:expire)

    request = AsyncRequest.new("my:special:key", redis: @mock_redis)

    assert_equal "my:special:key", request.key
  end
end
