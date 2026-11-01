defmodule Exiron.ReleaseMaintenance do
  @moduledoc """
  Administrative release helpers. Drain failure never resumes intake or stops the VM.
  """

  alias Exiron.Hub

  @boot_key {__MODULE__, :boot_id}
  @probe_states ~w(awaiting_restart ready starting disabled boot_failed not_initialized draining hub_unavailable boot_identity_unavailable)a

  @doc false
  def mark_boot do
    :persistent_term.put(@boot_key, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))
  end

  @doc "Opaque application boot identity. Changes even when a VM reboot retains its OS PID."
  def boot_id, do: :persistent_term.get(@boot_key, nil)

  @doc "Bounded restart/readiness observation for the release verifier."
  def restart_status(previous_boot) do
    cond do
      is_nil(boot_id()) -> :boot_identity_unavailable
      boot_id() == previous_boot -> :awaiting_restart
      not List.keymember?(Application.started_applications(), :exiron, 0) -> :starting
      true -> readiness_status()
    end
  end

  defp readiness_status do
    case Hub.readiness() do
      %{ready: true, reason: :initialized} ->
        :ready

      %{ready: false, reason: reason}
      when reason in [:disabled, :boot_failed, :not_initialized, :draining] ->
        reason

      _ ->
        :hub_unavailable
    end
  catch
    :exit, _ -> :hub_unavailable
  end

  @doc """
  Waits in a separate release `eval` VM for a new boot and Hub readiness.

  Uses a monotonic startup deadline (default 60 seconds). Each RPC subprocess is
  bounded by the local `timeout` utility, including a one-second kill grace.
  Does not restart, resume intake, or roll back on failure. `:probe` and
  `:on_progress` callbacks support application-owned verification and tests.
  """
  def await_restart(previous_boot, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    interval = Keyword.get(opts, :interval_ms, 1000)
    probe = Keyword.get(opts, :probe, &probe_release/2)
    progress = Keyword.get(opts, :on_progress, &IO.puts("Restart verification: #{&1}"))

    if is_binary(previous_boot) and Regex.match?(~r/\A[0-9a-f]{32}\z/, previous_boot) and
         is_integer(timeout) and timeout in 1..3_600_000 and
         is_integer(interval) and interval in 1..5000 and
         is_function(probe, 2) and is_function(progress, 1) do
      await_boot(previous_boot, now() + timeout, interval, probe, progress)
    else
      {:error, :invalid_options}
    end
  end

  defp await_boot(previous, deadline, interval, probe, progress) do
    remaining = max(deadline - now(), 1)
    status = probe.(previous, remaining)
    progress.(status)
    remaining = deadline - now()

    cond do
      remaining <= 0 ->
        {:error, {:startup_timeout, status}}

      status == :ready ->
        :ok

      status in [:boot_failed, :disabled] ->
        {:error, {:startup_failed, status}}

      true ->
        receive do
        after
          min(interval, remaining) ->
            if now() >= deadline,
              do: {:error, {:startup_timeout, status}},
              else: await_boot(previous, deadline, interval, probe, progress)
        end
    end
  end

  defp probe_release(previous, remaining) do
    release = Path.join([System.fetch_env!("RELEASE_ROOT"), "bin", "exiron"])
    seconds = min(5, max(1, div(remaining + 999, 1000)))
    expression = "IO.puts(Exiron.ReleaseMaintenance.restart_status(#{inspect(previous)}))"

    case System.cmd("timeout", ["-k", "1", "#{seconds}", release, "rpc", expression],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        Enum.find(@probe_states, :hub_unavailable, &(Atom.to_string(&1) == String.trim(output)))

      _ ->
        :hub_unavailable
    end
  rescue
    _ -> :hub_unavailable
  end

  @doc """
  Starts (or joins) a drain and waits for all four outstanding-work counts to reach zero.

  Returns `:ok` only while the same drain remains active and has completed within
  the local timeout. Existing drain deadlines are preserved. Options are
  `:timeout_ms` (1–3,600,000, default 60,000), `:interval_ms` (1–5,000, default
  1,000), and `:on_progress`, a function receiving each drain snapshot. The default
  callback prints counts to the RPC caller. This function never restarts the VM.
  """
  def drain(opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, 60_000)
    interval = Keyword.get(opts, :interval_ms, 1000)
    progress = Keyword.get(opts, :on_progress, &print_progress/1)

    if is_integer(timeout) and timeout in 1..3_600_000 and
         is_integer(interval) and interval in 1..5000 and is_function(progress, 1) do
      deadline = now() + timeout

      with {:ok, snapshot} <- Hub.start_drain(timeout_ms: timeout) do
        await(snapshot, snapshot.started_at, deadline, interval, progress)
      end
    else
      {:error, :invalid_options}
    end
  catch
    :exit, _reason -> {:error, :hub_unavailable}
  end

  defp await(snapshot, started_at, deadline, interval, progress) do
    progress.(snapshot)
    remaining = deadline - now()

    cond do
      not snapshot.active ->
        {:error, :drain_cancelled}

      snapshot.started_at != started_at ->
        {:error, :drain_replaced}

      snapshot.phase == "timed_out" or remaining <= 0 ->
        {:error, :drain_timed_out}

      snapshot.drained and snapshot.phase == "drained" ->
        :ok

      true ->
        receive do
        after
          min(interval, remaining) ->
            await(Hub.drain_status(), started_at, deadline, interval, progress)
        end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp print_progress(snapshot) do
    IO.puts(
      "Drain #{snapshot.phase}: pending_requests=#{snapshot.pending_requests} " <>
        "queued_messages=#{snapshot.queued_messages} active_sends=#{snapshot.active_sends} " <>
        "unacknowledged_batches=#{snapshot.unacknowledged_batches}"
    )
  end
end
