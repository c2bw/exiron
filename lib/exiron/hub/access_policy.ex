defmodule Exiron.Hub.AccessPolicy do
  @moduledoc false
  @keys ["allowed_user_ids", "admin_user_ids"]

  def allowed?(route, from),
    do: permitted?(Map.get(route, :interaction, %{}), "allowed_user_ids", from, true)

  def admin?(route, from),
    do: permitted?(Map.get(route, :interaction, %{}), "admin_user_ids", from, false)

  def callback_allowed?(router, hook, service, chat, from) do
    routes =
      Enum.filter(
        router.routes,
        &(&1.to == hook and &1.service_id == service and &1.chat_id == chat)
      )

    routes != [] and Enum.all?(routes, &allowed?(&1, from))
  end

  def validate_schema!(definitions) do
    middlewares = Map.get(definitions, "middlewares", %{}) || %{}

    restricted? =
      if is_map(middlewares),
        do:
          Enum.any?(middlewares, fn {_, middleware} ->
            routes = if is_map(middleware), do: Map.get(middleware, "routes", %{}), else: %{}

            is_map(routes) and
              Enum.any?(routes, fn {_, requirements} ->
                policy =
                  if is_map(requirements),
                    do: Map.get(requirements, "interaction", %{}),
                    else: %{}

                is_map(policy) and Enum.any?(@keys, &Map.has_key?(policy, &1))
              end)
          end),
        else: false

    if restricted? and Map.get(definitions, "version") != "2",
      do: raise(ArgumentError, "access restrictions require configuration version 2")
  end

  def validate_consistent!(routes) do
    routes
    |> Enum.group_by(&{&1.service_id, &1.chat_id, &1.to})
    |> Enum.each(fn {_, grouped} ->
      policies =
        grouped |> Enum.map(&(Map.get(&1, :interaction, %{}) |> Map.take(@keys))) |> Enum.uniq()

      if length(policies) > 1,
        do:
          raise(
            ArgumentError,
            "access settings must agree for every route to a hook in the same chat"
          )
    end)
  end

  defp permitted?(policy, key, from, default) do
    case Map.fetch(policy, key) do
      :error ->
        default

      {:ok, ids} ->
        case from do
          %{id: id} when is_integer(id) -> id in ids
          _ -> false
        end
    end
  end
end
