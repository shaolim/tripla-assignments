require "test_helper"

class PricingFlowTest < ActionDispatch::IntegrationTest
  setup do
    @mock_service = mock('pricing_service')
    PricingService.stubs(:instance).returns(@mock_service)
  end

  test "complete happy path flow" do
    @mock_service.expects(:fetch_pricing)
      .with(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
      .returns({ "rate" => "25000" })

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    assert_equal "application/json", @response.media_type

    json = JSON.parse(@response.body)
    assert_equal "25000", json["rate"]
  end

  test "returns same rate for cached request" do
    # First request
    @mock_service.expects(:fetch_pricing).twice.returns({ "rate" => "15000" })

    2.times do
      get pricing_url, params: {
        period: "Winter",
        hotel: "GitawayHotel",
        room: "BooleanTwin"
      }

      assert_response :success
      json = JSON.parse(@response.body)
      assert_equal "15000", json["rate"]
    end
  end

  test "handles all valid period values" do
    %w[Summer Autumn Winter Spring].each do |period|
      @mock_service.stubs(:fetch_pricing).returns({ "rate" => "10000" })

      get pricing_url, params: {
        period: period,
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :success, "Failed for period: #{period}"
    end
  end

  test "handles all valid hotel values" do
    %w[FloatingPointResort GitawayHotel RecursionRetreat].each do |hotel|
      @mock_service.stubs(:fetch_pricing).returns({ "rate" => "10000" })

      get pricing_url, params: {
        period: "Summer",
        hotel: hotel,
        room: "SingletonRoom"
      }

      assert_response :success, "Failed for hotel: #{hotel}"
    end
  end

  test "handles all valid room values" do
    %w[SingletonRoom BooleanTwin RestfulKing].each do |room|
      @mock_service.stubs(:fetch_pricing).returns({ "rate" => "10000" })

      get pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: room
      }

      assert_response :success, "Failed for room: #{room}"
    end
  end

  test "rejects request with missing period" do
    get pricing_url, params: {
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert_includes json["error"], "Missing required parameters"
  end

  test "rejects request with missing hotel" do
    get pricing_url, params: {
      period: "Summer",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert_includes json["error"], "Missing required parameters"
  end

  test "rejects request with missing room" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort"
    }

    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert_includes json["error"], "Missing required parameters"
  end

  test "rejects request with all parameters missing" do
    get pricing_url

    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert_includes json["error"], "Missing required parameters"
  end

  test "rejects request with invalid period" do
    invalid_periods = ["summer", "SUMMER", "Summer2024", "Fall", ""]

    invalid_periods.each do |period|
      get pricing_url, params: {
        period: period,
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :bad_request, "Should reject period: '#{period}'"
    end
  end

  test "rejects request with invalid hotel" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert_includes json["error"], "Invalid hotel"
  end

  test "rejects request with invalid room" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :bad_request
    json = JSON.parse(@response.body)
    assert_includes json["error"], "Invalid room"
  end

  test "handles service unavailable error gracefully" do
    @mock_service.expects(:fetch_pricing)
      .raises(PricingService::Error.new("Service unavailable"))

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :service_unavailable
    json = JSON.parse(@response.body)
    assert_equal "Service unavailable", json["error"]
  end

  test "handles API error with correct status code" do
    @mock_service.expects(:fetch_pricing)
      .raises(PricingService::ApiError.new(502, "Bad Gateway"))

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response 502
    json = JSON.parse(@response.body)
    assert_includes json["error"], "API error"
  end

  test "handles unexpected errors gracefully" do
    @mock_service.expects(:fetch_pricing)
      .raises(StandardError.new("Something unexpected"))

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :internal_server_error
    json = JSON.parse(@response.body)
    assert_includes json["error"], "unexpected error"
  end

  test "response content type is always JSON" do
    # Success case
    @mock_service.stubs(:fetch_pricing).returns({ "rate" => "10000" })

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_equal "application/json", @response.media_type

    # Error case
    get pricing_url, params: { period: "Invalid" }

    assert_equal "application/json", @response.media_type
  end

  test "rate is returned as string" do
    @mock_service.expects(:fetch_pricing).returns({ "rate" => "99999" })

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    json = JSON.parse(@response.body)
    assert_kind_of String, json["rate"]
  end

  test "handles concurrent requests" do
    @mock_service.stubs(:fetch_pricing).returns({ "rate" => "12345" })

    threads = 5.times.map do
      Thread.new do
        get pricing_url, params: {
          period: "Summer",
          hotel: "FloatingPointResort",
          room: "SingletonRoom"
        }
      end
    end

    threads.each(&:join)
    # Should not raise any errors
  end
end
