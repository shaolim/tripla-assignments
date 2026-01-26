require "test_helper"

class DistributedLockTest < ActiveSupport::TestCase
  setup do
    @mock_redis = mock('redis')
  end

  test "acquires lock successfully" do
    @mock_redis.expects(:set).with("test:lock", anything, nx: true, ex: 60).returns(true)
    @mock_redis.expects(:eval).at_least_once.returns(1) # For extend and release

    lock = DistributedLock.new(@mock_redis, "test:lock")

    result = lock.with_lock { "executed" }

    assert_equal "executed", result
  end

  test "raises LockError when lock cannot be acquired" do
    @mock_redis.expects(:set).with("test:lock", anything, nx: true, ex: 60).returns(nil)

    lock = DistributedLock.new(@mock_redis, "test:lock")

    assert_raises(DistributedLock::LockError) do
      lock.with_lock { "should not execute" }
    end
  end

  test "releases lock after block execution" do
    @mock_redis.expects(:set).returns(true)
    @mock_redis.expects(:eval).at_least_once.returns(1)

    lock = DistributedLock.new(@mock_redis, "test:lock")

    lock.with_lock { "work" }

    # Verify release was called (via eval)
  end

  test "releases lock even when block raises exception" do
    @mock_redis.expects(:set).returns(true)
    @mock_redis.expects(:eval).at_least_once.returns(1)

    lock = DistributedLock.new(@mock_redis, "test:lock")

    assert_raises(RuntimeError) do
      lock.with_lock { raise "block error" }
    end

    # Lock should still be released
  end

  test "generates unique owner ID for each lock acquisition" do
    owners = []
    @mock_redis.stubs(:set).with { |key, owner, **opts| owners << owner; true }.returns(true)
    @mock_redis.stubs(:eval).returns(1)

    lock1 = DistributedLock.new(@mock_redis, "test:lock")
    lock2 = DistributedLock.new(@mock_redis, "test:lock")

    lock1.with_lock { }
    lock2.with_lock { }

    assert_equal 2, owners.uniq.size
  end

  test "lock key is stored correctly" do
    lock = DistributedLock.new(@mock_redis, "my:custom:key")

    assert_equal "my:custom:key", lock.key
  end

  test "uses Lua script for safe release" do
    @mock_redis.expects(:set).returns(true)

    # Capture the Lua script used for release
    release_script = nil
    @mock_redis.stubs(:eval).with { |script, **opts|
      release_script = script if script.include?("DEL")
      true
    }.returns(1)

    lock = DistributedLock.new(@mock_redis, "test:lock")
    lock.with_lock { }

    # Verify Lua script checks ownership before delete
    assert_includes release_script, "GET"
    assert_includes release_script, "DEL"
  end

  test "handles release failure gracefully" do
    @mock_redis.expects(:set).returns(true)
    @mock_redis.stubs(:eval).raises(Redis::ConnectionError.new("connection lost")).then.returns(1)

    lock = DistributedLock.new(@mock_redis, "test:lock")

    # Should not raise even if release fails
    result = lock.with_lock { "completed" }
    assert_equal "completed", result
  end
end
