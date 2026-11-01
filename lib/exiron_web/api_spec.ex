defmodule ExironWeb.ApiSpec do
  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(ExironWeb.Endpoint)],
      info: %Info{
        title: "Exiron API",
        version: Application.spec(:exiron, :vsn) |> to_string()
      },
      paths: Paths.from_router(ExironWeb.Router),
      components: %Components{
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer"},
          "dashboardSession" => %SecurityScheme{
            type: "apiKey",
            in: "cookie",
            name: "_exiron_key"
          }
        }
      }
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
