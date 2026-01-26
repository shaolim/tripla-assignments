require "test_helper"

class PricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @mock_service = mock('pricing_service')
    PricingService.stubs(:instance).returns(@mock_service)
  end

  # ============================================
  # Happy Path Tests
  # ============================================

  test "should get pricing with all parameters" do
    @mock_service.expects(:fetch_pricing)
      .with(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
      .returns({ "rate" => "12000" })

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :success
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_equal "12000", json_response["rate"]
  end

  test "should return different rates for different combinations" do
    @mock_service.expects(:fetch_pricing)
      .with(period: "Winter", hotel: "GitawayHotel", room: "RestfulKing")
      .returns({ "rate" => "45000" })

    get pricing_url, params: {
      period: "Winter",
      hotel: "GitawayHotel",
      room: "RestfulKing"
    }

    assert_response :success
    json_response = JSON.parse(@response.body)
    assert_equal "45000", json_response["rate"]
  end

  # ============================================
  # Parameter Validation Tests
  # ============================================

  test "should return error without any parameters" do
    get pricing_url

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should handle empty parameters" do
    get pricing_url, params: {
      period: "",
      hotel: "",
      room: ""
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Missing required parameters"
  end

  test "should handle whitespace-only parameters" do
    get pricing_url, params: {
      period: "   ",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
  end

  test "should reject invalid period" do
    get pricing_url, params: {
      period: "summer-2024",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid period"
  end

  test "should reject lowercase period" do
    get pricing_url, params: {
      period: "summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid period"
  end

  test "should reject invalid hotel" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "InvalidHotel",
      room: "SingletonRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid hotel"
  end

  test "should reject invalid room" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "InvalidRoom"
    }

    assert_response :bad_request
    assert_equal "application/json", @response.media_type

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Invalid room"
  end

  test "should list valid periods in error message" do
    get pricing_url, params: {
      period: "Invalid",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "Summer"
    assert_includes json_response["error"], "Autumn"
    assert_includes json_response["error"], "Winter"
    assert_includes json_response["error"], "Spring"
  end

  test "should list valid hotels in error message" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "Invalid",
      room: "SingletonRoom"
    }

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "FloatingPointResort"
    assert_includes json_response["error"], "GitawayHotel"
    assert_includes json_response["error"], "RecursionRetreat"
  end

  test "should list valid rooms in error message" do
    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "Invalid"
    }

    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "SingletonRoom"
    assert_includes json_response["error"], "BooleanTwin"
    assert_includes json_response["error"], "RestfulKing"
  end

  # ============================================
  # Error Handling Tests
  # ============================================

  test "should handle pricing service API error" do
    @mock_service.expects(:fetch_pricing)
      .with(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
      .raises(PricingService::ApiError.new(500, "Internal server error"))

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :internal_server_error
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "API error"
  end

  test "should handle pricing service API error with 502" do
    @mock_service.expects(:fetch_pricing)
      .raises(PricingService::ApiError.new(502, "Bad Gateway"))

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response 502
  end

  test "should handle pricing service unavailable error" do
    @mock_service.expects(:fetch_pricing)
      .with(period: "Summer", hotel: "FloatingPointResort", room: "SingletonRoom")
      .raises(PricingService::Error.new("Service unavailable"))

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :service_unavailable
    json_response = JSON.parse(@response.body)
    assert_equal "Service unavailable", json_response["error"]
  end

  test "should handle timeout error" do
    @mock_service.expects(:fetch_pricing)
      .raises(PricingService::Error.new("Price calculation timed out"))

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :service_unavailable
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "timed out"
  end

  test "should handle unexpected standard error" do
    @mock_service.expects(:fetch_pricing)
      .raises(StandardError.new("Unexpected failure"))

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_response :internal_server_error
    json_response = JSON.parse(@response.body)
    assert_includes json_response["error"], "unexpected error"
  end

  # ============================================
  # Response Format Tests
  # ============================================

  test "should always return JSON content type" do
    @mock_service.stubs(:fetch_pricing).returns({ "rate" => "10000" })

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    assert_equal "application/json", @response.media_type
  end

  test "should return rate as string" do
    @mock_service.expects(:fetch_pricing).returns({ "rate" => "99999" })

    get pricing_url, params: {
      period: "Summer",
      hotel: "FloatingPointResort",
      room: "SingletonRoom"
    }

    json_response = JSON.parse(@response.body)
    assert_kind_of String, json_response["rate"]
  end

  test "error response should always include error key" do
    get pricing_url

    json_response = JSON.parse(@response.body)
    assert json_response.key?("error")
  end

  # ============================================
  # All Valid Combinations Tests
  # ============================================

  test "should accept all valid periods" do
    %w[Summer Autumn Winter Spring].each do |period|
      @mock_service.stubs(:fetch_pricing).returns({ "rate" => "10000" })

      get pricing_url, params: {
        period: period,
        hotel: "FloatingPointResort",
        room: "SingletonRoom"
      }

      assert_response :success, "Should accept period: #{period}"
    end
  end

  test "should accept all valid hotels" do
    %w[FloatingPointResort GitawayHotel RecursionRetreat].each do |hotel|
      @mock_service.stubs(:fetch_pricing).returns({ "rate" => "10000" })

      get pricing_url, params: {
        period: "Summer",
        hotel: hotel,
        room: "SingletonRoom"
      }

      assert_response :success, "Should accept hotel: #{hotel}"
    end
  end

  test "should accept all valid rooms" do
    %w[SingletonRoom BooleanTwin RestfulKing].each do |room|
      @mock_service.stubs(:fetch_pricing).returns({ "rate" => "10000" })

      get pricing_url, params: {
        period: "Summer",
        hotel: "FloatingPointResort",
        room: room
      }

      assert_response :success, "Should accept room: #{room}"
    end
  end
end
