go_dir = Path.expand("../clients/go", __DIR__)

case System.cmd("gofmt", ["-l", "."], cd: go_dir, stderr_to_stdout: true) do
  {output, 0} ->
    case String.trim(output) do
      "" ->
        :ok

      files ->
        IO.puts("Go files are not formatted:")
        IO.puts(files)
        System.halt(1)
    end

  {output, status} ->
    IO.puts("gofmt failed with status #{status}:")
    IO.puts(output)
    System.halt(status)
end
