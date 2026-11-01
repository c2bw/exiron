defmodule Exiron.Hub.RouteConfiguration.ConflictError do
  @moduledoc false

  defexception [:path]

  @impl true
  def message(%__MODULE__{path: path}) do
    "Configuration changed on disk at #{path}. Reload the page before saving again."
  end
end
