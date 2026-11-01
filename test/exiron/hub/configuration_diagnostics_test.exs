defmodule Exiron.Hub.ConfigurationDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Exiron.Hub.{ConfigurationDiagnostics, HookToken, RouteConfiguration, Router}

  test "reports unreachable hooks, unused middleware and empty push expansion with entry links" do
    config =
      config(%{
        "routes" => %{"home" => %{"push" => true}},
        "middlewares" => %{"unused" => %{"routes" => %{"first" => %{"messages" => ["/ai"]}}}}
      })

    warnings = ConfigurationDiagnostics.analyze(config)
    assert Enum.count(warnings, &(&1.kind == :unreachable_hook)) == 2
    assert Enum.any?(warnings, &(&1.kind == :unused_middleware))
    assert Enum.any?(warnings, &(&1.kind == :empty_push))

    assert Enum.any?(
             warnings,
             &Enum.any?(&1.targets, fn target -> target.href == "#exiron-chat-route-home" end)
           )

    refute inspect(warnings) =~ HookToken.hash("first-token")
    assert warnings == ConfigurationDiagnostics.analyze(config)
  end

  test "overlaps follow command boundaries and actual longest-prefix routing" do
    config =
      config(%{
        "routes" => %{"home" => %{"middleware" => ["shared"]}},
        "middlewares" => %{
          "shared" => %{
            "routes" => %{
              "first" => %{"messages" => ["/ai"]},
              "second" => %{"messages" => ["/ai summary", "/aiv"]}
            }
          }
        }
      })

    assert [warning] = ConfigurationDiagnostics.analyze(config)
    assert warning.kind == :overlapping_prefix
    assert length(warning.targets) == 2
    assert {:ok, %{to: "second"}} = Router.match_text(config.router, 123, "/ai summary now")
    assert {:ok, %{to: "first"}} = Router.match_text(config.router, 123, "/ai other")
    assert warning.message =~ "/ai summary"
    refute warning.message =~ "/aiv"
  end

  test "separate chats and equivalent routes do not produce overlap warnings" do
    config =
      config(%{
        "routes" => %{
          "home" => %{"middleware" => ["first"]},
          "work" => %{"middleware" => ["second"]}
        },
        "middlewares" => %{
          "first" => %{"routes" => %{"first" => %{"messages" => ["/ai", "/ai own"]}}},
          "second" => %{"routes" => %{"second" => %{"messages" => ["/ai summary"]}}}
        }
      })

    assert [] = ConfigurationDiagnostics.analyze(config)

    shared_address = String.replace(config.source, ~s("work":456), ~s("work":123))
    assert shared_address != config.source
    assert {:ok, shared} = RouteConfiguration.load_source("shared-address.yml", shared_address)
    assert [%{kind: :overlapping_prefix}] = ConfigurationDiagnostics.analyze(shared)
  end

  test "push-disabled reachable hooks are intentional and produce no push warnings" do
    config =
      config(%{
        "routes" => %{"home" => %{"middleware" => ["shared"]}},
        "middlewares" => %{
          "shared" => %{
            "routes" => %{
              "first" => %{"messages" => ["/one"]},
              "second" => %{"messages" => ["/two"]}
            }
          }
        }
      })

    assert [] = ConfigurationDiagnostics.analyze(config)
  end

  test "overlaps with different passthrough policies for one hook are visible" do
    config =
      config(%{
        "hooks" => %{"first" => HookToken.hash("first-token")},
        "routes" => %{"home" => %{"middleware" => ["broad", "specific"]}},
        "middlewares" => %{
          "broad" => %{"routes" => %{"first" => %{"messages" => ["/ai"]}}},
          "specific" => %{
            "routes" => %{"first" => %{"messages" => ["/ai detail"], "passthrough" => true}}
          }
        }
      })

    assert [%{kind: :overlapping_prefix}] = ConfigurationDiagnostics.analyze(config)
  end

  defp config(overrides) do
    definitions =
      Map.merge(
        %{
          "version" => "1",
          "telegram" => %{
            "bots" => [
              %{
                "name" => "helper",
                "token" => "123456:private",
                "chats" => %{"home" => 123, "work" => 456}
              }
            ]
          },
          "hooks" => %{
            "first" => HookToken.hash("first-token"),
            "second" => HookToken.hash("second-token")
          }
        },
        overrides
      )

    assert {:ok, config} =
             RouteConfiguration.load_source("diagnostics.yml", Jason.encode!(definitions))

    config
  end
end
