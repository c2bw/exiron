defmodule Exiron.Support.TempPath do
  @moduledoc false

  def tmp_path(name, extension \\ "yml") do
    unique =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    Path.join(System.tmp_dir!(), "exiron-#{name}-#{unique}.#{extension}")
  end
end
