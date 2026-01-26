require 'async'
require 'securerandom'

# Distributed lock with automatic extension for long-running operations
class DistributedLock
  class LockError < StandardError; end

  attr_reader :key, :owner, :redis

  LOCK_TTL = 60 # seconds
  EXTEND_EVERY = 2 # seconds

  def initialize(redis, key)
    @redis = redis
    @key = key
    @owner = nil
  end

  # Acquires lock and executes block with automatic lock extension
  # Raises LockError if lock cannot be acquired or is lost during execution
  def with_lock(&block)
    acquire_lock!

    Async do |task|
      keep_alive_task = task.async { keep_lock_alive! }

      begin
        block.call
      ensure
        keep_alive_task.stop
        release_lock
      end
    end.wait
  end

  private

  def acquire_lock!
    @owner = SecureRandom.uuid
    reply = @redis.set(@key, @owner, nx: true, ex: LOCK_TTL)
    raise LockError, "Lock `#{@key}` could not be acquired" if reply != true

    @owner
  end

  def keep_lock_alive!
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    loop do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = now - start_time

      # If we've been running for too long, lock might have expired
      raise LockError, "Lock `#{@key}` no longer in possession (time expired)" if elapsed >= LOCK_TTL

      # Atomically extend lock only if we still own it
      extended = extend_lock_if_owner?
      raise LockError, "Lock `#{@key}` no longer in possession (ownership lost)" unless extended

      start_time = now
      sleep(EXTEND_EVERY)
    end
  end

  def extend_lock_if_owner?
    # Use Lua script for atomic check-and-extend
    script = <<~LUA
      if redis.call('GET', KEYS[1]) == ARGV[1] then
        return redis.call('EXPIRE', KEYS[1], ARGV[2])
      else
        return 0
      end
    LUA

    result = @redis.eval(script, keys: [@key], argv: [@owner, LOCK_TTL])
    result == 1
  end

  def release_lock
    # Use Lua script for atomic check-and-delete
    script = <<~LUA
      if redis.call('GET', KEYS[1]) == ARGV[1] then
        return redis.call('DEL', KEYS[1])
      else
        return 0
      end
    LUA

    @redis.eval(script, keys: [@key], argv: [@owner])
  rescue StandardError => e
    # Best effort - ignore connection issues and let TTL expire
    Rails.logger.warn "Failed to release lock: #{e.message}"
  end
end
