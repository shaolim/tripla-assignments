require "test_helper"

class PricingControllerTest < ActionDispatch::IntegrationTest
  setup do
    # Mock the pricing service to return a consistent response
    @mock_service = mock('pricing_service')
    PricingService.stubs(:instance).returns(@mock_service)
  end

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
end
