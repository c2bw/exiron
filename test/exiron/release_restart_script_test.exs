defmodule Exiron.ReleaseRestartScriptTest do
  use ExUnit.Case, async: true

  @helper Path.expand("../../rel/overlays/bin/exiron-safe-restart", __DIR__)

  setup %{tmp_dir: dir} do
    # A space in the release path also exercises shell quoting.
    bin = Path.join(dir, "test release/bin")
    File.mkdir_p!(bin)
    helper = Path.join(bin, "exiron-safe-restart")
    File.cp!(@helper, helper)
    fake = Path.join(bin, "exiron")

    File.write!(fake, """
    #!/bin/sh
    printf '%s\\n' "$@" >> "$CALL_LOG"
    case "$1" in
      rpc)
        case "$2" in
          *boot_id*)
            if [ "${BOOT_EMPTY:-0}" = 1 ]; then
              printf '\\n'
            else
              printf '%s\\n' "${BOOT_ID-0123456789abcdef0123456789abcdef}"
            fi
            exit "${BOOT_STATUS:-0}"
            ;;
          *) exit "${RPC_STATUS:-0}" ;;
        esac
        ;;
      restart) exit "${RESTART_STATUS:-0}" ;;
      eval) exit "${VERIFY_STATUS:-0}" ;;
      *) exit 99 ;;
    esac
    """)

    File.chmod!(fake, 0o755)
    %{helper: helper, log: Path.join(dir, "calls")}
  end

  @moduletag :tmp_dir

  test "captures the original boot, drains, restarts and verifies with a separate timeout", ctx do
    assert {output, 0} = run(ctx, ["--timeout", "12", "--startup-timeout", "24"])

    assert [
             "rpc",
             "IO.puts(Exiron.ReleaseMaintenance.boot_id())",
             "rpc",
             drain,
             "restart",
             "eval",
             verify
           ] =
             String.split(File.read!(ctx.log), "\n", trim: true)

    assert drain == ":ok = Exiron.ReleaseMaintenance.drain(timeout_ms: 12000)"
    assert verify =~ ~s|await_restart("0123456789abcdef0123456789abcdef", timeout_ms: 24000)|
    assert output =~ "Waiting for a new boot and readiness"
  end

  test "drain failure skips restart", ctx do
    assert {output, 1} = run(ctx, [], [{"RPC_STATUS", "7"}])
    assert output =~ "restart skipped"
    refute File.read!(ctx.log) =~ "\nrestart\n"
  end

  test "drain-only leaves restart to the service manager", ctx do
    assert {output, 0} = run(ctx, ["--drain-only"])
    assert output =~ "no restart requested"
    refute File.read!(ctx.log) =~ "\nrestart\n"
    refute File.read!(ctx.log) =~ "boot_id"
    refute File.read!(ctx.log) =~ "\neval\n"
  end

  test "restart command failures remain nonzero", ctx do
    assert {_output, 9} = run(ctx, [], [{"RESTART_STATUS", "9"}])
    refute File.read!(ctx.log) =~ "\neval\n"
  end

  test "startup verification failures remain nonzero", ctx do
    assert {_output, 3} = run(ctx, [], [{"VERIFY_STATUS", "3"}])
    assert File.read!(ctx.log) =~ "\neval\n"
  end

  test "missing or invalid boot identity cannot drain or restart", ctx do
    for boot <- ["", "nil", "0123", "ready", "1); System.restart()"] do
      File.rm(ctx.log)
      env = if boot == "", do: [{"BOOT_EMPTY", "1"}], else: [{"BOOT_ID", boot}]
      assert {_output, 1} = run(ctx, [], env)
      refute File.read!(ctx.log) =~ "drain(timeout_ms:"
      refute File.read!(ctx.log) =~ "\nrestart\n"
    end
  end

  test "failed identity RPC cannot drain or restart", ctx do
    assert {_output, 1} = run(ctx, [], [{"BOOT_STATUS", "7"}])
    refute File.read!(ctx.log) =~ "drain(timeout_ms:"
  end

  test "invalid arguments cannot call RPC or inject expressions", ctx do
    for args <- [
          ["--timeout"],
          ["--unknown"],
          ["--timeout", "0"],
          ["--timeout", "01"],
          ["--timeout", "-1"],
          ["--timeout", "3601"],
          ["--timeout", "99999999999999999999"],
          ["--timeout", "1); System.restart()"],
          ["--startup-timeout"],
          ["--startup-timeout", "0"],
          ["--startup-timeout", "01"],
          ["--startup-timeout", "3601"],
          ["--startup-timeout", "1); System.restart()"]
        ] do
      assert {_output, 2} = run(ctx, args)
      refute File.exists?(ctx.log)
    end
  end

  test "help needs no running release", ctx do
    File.rm!(Path.join(Path.dirname(ctx.helper), "exiron"))
    assert {output, 0} = run(ctx, ["--help"])
    assert output =~ "Usage:"
    refute File.exists?(ctx.log)
  end

  defp run(ctx, args, env \\ []) do
    System.cmd("sh", [ctx.helper | args],
      env: [{"CALL_LOG", ctx.log} | env],
      stderr_to_stdout: true
    )
  end
end
