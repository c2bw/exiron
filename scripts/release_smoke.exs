defmodule Exiron.ReleaseSmoke do
  @moduledoc false

  def run do
    unless Mix.env() == :test, do: raise("Run with MIX_ENV=test; no deployed instance is used")

    root =
      Path.join(
        System.tmp_dir!(),
        "exiron-release-smoke-#{System.pid()}-#{System.system_time(:microsecond)}"
      )

    File.mkdir_p!(root)
    release_root = Path.join(root, "release")
    config_path = Path.join(root, "config.yml")
    # Never inherit credentials, release targets or server settings from a host.
    cleared =
      for {key, _} <- System.get_env(),
          String.starts_with?(key, ["EXIRON_", "RELEASE_"]),
          do: {key, nil}

    env =
      cleared ++
        [
          {"MIX_ENV", "test"},
          {"PHX_SERVER", nil},
          {"SECRET_KEY_BASE", nil},
          {"DNS_CLUSTER_QUERY", nil},
          {"PHX_HOST", nil},
          {"PORT", "0"},
          {"RELEASE_NODE",
           "exiron_smoke_#{System.pid()}_#{System.system_time(:microsecond)}@127.0.0.1"},
          {"RELEASE_DISTRIBUTION", "name"},
          {"ERL_EPMD_ADDRESS", "127.0.0.1"},
          {"ERL_FLAGS", "+S 2:2 -kernel inet_dist_use_interface {127,0,0,1}"}
        ]

    env = env |> Map.new() |> Map.to_list()

    try do
      File.write!(config_path, "version: \"1\"\n")
      command("mix", ["release", "--path", release_root, "--overwrite"], env, 0, 180)
      Exiron.ReleaseMetadata.check!(Path.expand("..", __DIR__), release: release_root)
      release = Path.join(release_root, "bin/exiron")
      helper = Path.join(release_root, "bin/exiron-safe-restart")

      sys_config =
        Path.join([release_root, "releases", Mix.Project.config()[:version], "sys.config"])

      expression =
        "path = #{inspect(sys_config)}; {:ok, [config]} = :file.consult(String.to_charlist(path)); updated = Keyword.update!(config, :exiron, fn opts -> Keyword.put(opts, :hub, [enabled: true, config_path: #{inspect(config_path)}, telegram_pollers_enabled: false]) end); File.write!(path, [\"%% RUNTIME_CONFIG=true\\n\", :io_lib.format(~c\"~tp.~n\", [updated])])"

      command(release, ["eval", expression], env, 0)
      command(helper, ["--help"], env, 0)
      smoke_running_release(release, helper, config_path, env)
      IO.puts("Release smoke checks passed (isolated configuration; no Telegram traffic)")
    after
      File.rm_rf!(root)
    end
  end

  defp smoke_running_release(release, helper, config_path, env) do
    port =
      Port.open({:spawn_executable, String.to_charlist(release)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [~c"start"],
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
          end)
      ])

    try do
      # Cold boots and OTP restarts can take tens of seconds on CI runners.
      # Match the release helper's normal startup allowance.
      wait_ready(port, release, env, System.monotonic_time(:millisecond) + 90_000)

      assert!(
        rpc(release, "IO.puts(Exiron.BuildInfo.current().metadata_status)", env) == "available",
        "packaged build metadata was not available through release RPC"
      )

      old_boot = rpc(release, "IO.puts(Exiron.ReleaseMaintenance.boot_id())", env)
      command(helper, ["--timeout", "3", "--drain-only"], env, 0)

      assert!(
        rpc(release, "IO.puts(Exiron.Hub.drain_status().active)", env) == "true",
        "drain-only did not retain pause"
      )

      assert!(
        rpc(release, "IO.puts(Exiron.ReleaseMaintenance.boot_id())", env) == old_boot,
        "drain-only restarted the instance"
      )

      rpc(release, "Exiron.Hub.resume_intake()", env)
      output = command(helper, ["--timeout", "3", "--startup-timeout", "90"], env, 0, 110)

      assert!(
        String.contains?(output, "new application boot is ready"),
        "restart readiness was not confirmed"
      )

      assert!(
        rpc(release, "IO.puts(Exiron.ReleaseMaintenance.boot_id())", env) != old_boot,
        "boot identity did not change"
      )

      File.write!(config_path, "version: \"unsupported\"\n")
      output = command(helper, ["--timeout", "3", "--startup-timeout", "90"], env, 3, 110)
      assert!(String.contains?(output, "boot_failed"), "startup failure was not classified")
      failed_boot = rpc(release, "IO.puts(Exiron.ReleaseMaintenance.boot_id())", env)
      {_, status} = raw_command(helper, ["--timeout", "1", "--drain-only"], env, 10)
      assert!(status != 0, "disabled drain unexpectedly succeeded")

      assert!(
        rpc(release, "IO.puts(Exiron.ReleaseMaintenance.boot_id())", env) == failed_boot,
        "failed drain restarted the instance"
      )
    rescue
      error ->
        {output, status} =
          raw_command(release, ["rpc", "IO.inspect(Exiron.Hub.readiness())"], env, 5)

        IO.puts(:stderr, "Readiness RPC exited #{status}: #{output}")
        IO.puts(:stderr, "Release output:\n#{startup_logs(port, "")}")
        reraise error, __STACKTRACE__
    after
      stop(port, release, env)
    end
  end

  defp wait_ready(port, release, env, deadline, logs \\ "") do
    {output, status} =
      raw_command(release, ["rpc", "IO.puts(Exiron.Hub.readiness().ready)"], env, 5)

    logs = startup_logs(port, logs)

    cond do
      status == 0 and String.trim(output) == "true" ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "isolated release did not become ready; last RPC exited #{status}: #{output}\nRelease output:\n#{logs}"

      true ->
        receive do
        after
          100 -> wait_ready(port, release, env, deadline, logs)
        end
    end
  end

  defp startup_logs(port, logs) do
    receive do
      {^port, {:data, data}} ->
        logs = logs <> data
        size = byte_size(logs)
        logs = binary_part(logs, max(0, size - 16_384), min(size, 16_384))
        startup_logs(port, logs)

      {^port, {:exit_status, status}} ->
        logs <> "\nRelease process exited #{status}\n"
    after
      0 -> logs
    end
  end

  defp rpc(release, expression, env),
    do: release |> command(["rpc", expression], env, 0) |> String.trim()

  defp raw_command(executable, args, env, timeout) do
    System.cmd("timeout", ["-k", "1", Integer.to_string(timeout), executable | args],
      env: env,
      stderr_to_stdout: true
    )
  end

  defp command(executable, args, env, expected, timeout \\ 30) do
    {output, status} = raw_command(executable, args, env, timeout)

    assert!(
      status == expected,
      "#{Path.basename(executable)} #{List.first(args)} exited #{status}, expected #{expected}: #{output}"
    )

    output
  end

  defp stop(port, release, env) do
    raw_command(release, ["stop"], env, 10)

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      10_000 ->
        if info = Port.info(port, :os_pid) do
          {:os_pid, pid} = info
          System.cmd("kill", ["-KILL", Integer.to_string(pid)])
        end

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          5000 -> :ok
        end
    end
  end

  defp assert!(true, _), do: :ok
  defp assert!(false, message), do: raise(message)
end

Exiron.ReleaseSmoke.run()
