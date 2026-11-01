defmodule ExironWeb.Router do
  use ExironWeb, :router

  @browser_body_length 64 * 1024
  @auth_body_length 16 * 1024

  scope "/", ExironWeb do
    get "/metrics", MetricsController, :show
    get "/health/live", HealthController, :live
    get "/health/ready", HealthController, :ready
  end

  pipeline :browser do
    plug :accepts, ["html"]

    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      length: @browser_body_length,
      json_decoder: Phoenix.json_library()

    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExironWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ExironWeb.Auth, :fetch_current_scope
  end

  pipeline :redirect_if_authenticated do
    plug ExironWeb.Auth, :redirect_if_authenticated
  end

  pipeline :require_authenticated_user do
    plug ExironWeb.Auth, :require_authenticated_user
  end

  pipeline :event_media do
    plug :fetch_session
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: ExironWeb.ApiSpec
  end

  pipeline :auth_body do
    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      length: @auth_body_length,
      json_decoder: Phoenix.json_library()
  end

  pipeline :api_body do
    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      body_reader: {ExironWeb.BodyReader, :read_body, []},
      json_decoder: Phoenix.json_library()
  end

  pipeline :require_api_authentication do
    plug ExironWeb.Plugs.ApiAuthentication
  end

  pipeline :rate_limit_auth do
    plug ExironWeb.Plugs.RateLimit,
      limit: 10,
      window_seconds: 60,
      namespace: :api_authentication
  end

  pipeline :rate_limit_api do
    plug ExironWeb.Plugs.RateLimit,
      limit: 60_000,
      window_seconds: 60,
      namespace: :api_ip,
      identity: :ip

    plug ExironWeb.Plugs.RateLimit,
      limit: 1200,
      window_seconds: 60,
      namespace: :api_token,
      identity: :bearer
  end

  pipeline :openapi do
    plug OpenApiSpex.Plug.PutApiSpec, module: ExironWeb.ApiSpec
  end

  scope "/", ExironWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
  end

  scope "/", ExironWeb do
    pipe_through [:browser, :require_authenticated_user]

    delete "/logout", SessionController, :delete
    get "/diagnostics/requests/:id", RequestDiagnosticController, :show

    live_session :authenticated, on_mount: [{ExironWeb.Auth, :ensure_authenticated}] do
      live "/", PageLive
      live "/compose", ComposerLive
      live "/hooks/:name", HookLive
      live "/monitor", MonitorLive
      live "/config", ConfigLive
    end
  end

  scope "/api", ExironWeb do
    pipe_through [:api, :rate_limit_auth, :auth_body]

    post "/auth", ExironController, :auth
  end

  scope "/api", ExironWeb do
    pipe_through [:api, :rate_limit_api, :require_api_authentication, :api_body]

    get "/capabilities", ExironController, :capabilities
    get "/status", ExironController, :status
    get "/socket", ClientSocketController, :connect
    get "/deliveries/:id", ExironController, :delivery
    get "/requests", ExironController, :requests
    post "/client-lease", ExironController, :renew_lease
    post "/client-retire", ExironController, :retire_client
    post "/client-runtime", ExironController, :client_runtime_report
    post "/handler-reports", ExironController, :handler_report
    get "/request-state", ExironController, :request_state
    post "/cancellations", ExironController, :cancellations
    post "/idempotent/responses", ExironController, :idempotent_responses
    post "/idempotent/push", ExironController, :idempotent_push
    post "/responses", ExironController, :responses
    post "/actions", ExironController, :actions
    post "/edits", ExironController, :edits
    post "/push", ExironController, :push
  end

  scope "/api", ExironWeb do
    pipe_through [:event_media, :rate_limit_api]

    get "/event-media/:id", EventMediaController, :show
  end

  scope "/api" do
    pipe_through [:browser, :require_authenticated_user, :openapi]

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:exiron, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :require_authenticated_user]

      live_dashboard "/dashboard", metrics: ExironWeb.Telemetry

      forward "/swaggerui",
              OpenApiSpex.Plug.SwaggerUI,
              path: "/api/openapi"
    end
  end
end
