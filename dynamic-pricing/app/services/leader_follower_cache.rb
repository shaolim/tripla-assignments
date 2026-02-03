require 'json'

# Leader-Follower cache coordination pattern
# Prevents stampeding herd problem when cache expires
# - Only one request (leader) fetches from external API
# - Other requests (followers) wait for leader's result
class LeaderFollowerCache
  DEFAULT_TTL = 300 # 5 minutes (per requirements)
  FOLLOWER_TIMEOUT = 15 # seconds (user-friendly timeout)

  def initialize(redis:, logger: nil, ttl: DEFAULT_TTL)
    @redis = redis
    @logger = logger || Rails.logger
    @ttl = ttl
  end

  def fetch(key, &block)
    cached = get(key)
    return cached if cached

    lock = DistributedLock.new(@redis, lock_key(key))

    begin
      lock.with_lock do
        cached = get(key)
        return cached if cached

        result = block.call

        # Cache the result
        set(key, result)

        # Publish to all waiting followers
        publish_to_followers(key, result)

        result
      end
    rescue DistributedLock::LockError
      # Failed to acquire lock, become follower
      execute_as_follower(key)
    end
  end

  def get(key)
    data = @redis.get(key)
    return nil unless data

    JSON.parse(data)
  rescue JSON::ParserError => e
    @logger.error { "Invalid JSON in cache for key #{key}: #{e.message}" }
    nil
  end

  def set(key, value, ttl: @ttl)
    @redis.set(key, value.to_json, ex: ttl)
  end

  def delete(key)
    @redis.del(key)
  end

  private

  def lock_key(key)
    "lock:#{key}"
  end

  def execute_as_follower(key)
    request = AsyncRequest.create(key, timeout: FOLLOWER_TIMEOUT, redis: @redis)
    request.wait!
  rescue AsyncRequest::Timeout
    @logger.error { "Follower timeout for key #{key}" }
    raise PricingService::Error, 'Pricing service is temporarily unavailable. Please try again later.'
  end

  def publish_to_followers(key, result)
    result_payload = result.to_json

    # Drain the waiters list and publish to each
    while (waiter_queue = @redis.rpop("waiters:#{key}"))
      @redis.lpush(waiter_queue, result_payload)
      @redis.expire(waiter_queue, FOLLOWER_TIMEOUT + 5)
    end
  end
end
