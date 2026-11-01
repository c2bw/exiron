defmodule Exiron.Hub.RouteConfiguration.DocumentTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.RouteConfiguration.Document

  test "ensures supported sections with canonical defaults" do
    definitions = Document.ensure_supported_sections(%{"telegram" => %{"bots" => "bad"}})

    assert definitions["version"] == Exiron.Hub.Configuration.schema_version()
    assert definitions["telegram"]["bots"] == []
    assert definitions["routes"] == %{}
    assert definitions["middlewares"] == %{}
    assert definitions["hooks"] == %{}
  end

  test "derives router definitions from supported sections and aliases" do
    definitions = %{
      "custom" => %{"ignored" => true},
      "routes" => %{"home" => %{}},
      "middlewares" => %{"shared" => %{}},
      "hooks" => %{"assistant" => "token"}
    }

    assert Document.with_router_aliases(definitions, %{"home" => 123}) == %{
             "aliases" => %{"telegram" => %{"home" => 123}},
             "routes" => %{"home" => %{}},
             "middlewares" => %{"shared" => %{}},
             "hooks" => %{"assistant" => "token"}
           }
  end
end
