defmodule ExironWeb.HookLiveFailureTest do
  use ExUnit.Case, async: true
  alias ExironWeb.HookLiveFailure

  test "uncertain and partial sends warn against duplicating delivery without copying raw errors" do
    for status <- ["unknown", "partial"] do
      summary =
        HookLiveFailure.summary(%{
          reason: "PRIVATE",
          delivery: %{
            delivery_status: status,
            last_error: %{category: "delivery_timeout", message: "PRIVATE"}
          }
        })

      assert summary.title == "Delivery deadline reached"

      assert String.contains?(
               summary.certainty,
               if(status == "unknown", do: "uncertain", else: "duplicates")
             )

      refute inspect(summary) =~ "PRIVATE"
    end

    assert HookLiveFailure.summary(%{}).title == "Send did not complete"
  end
end
