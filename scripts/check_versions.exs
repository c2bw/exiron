argv =
  case System.argv() do
    ["--" | rest] -> rest
    args -> args
  end

{opts, args, invalid} =
  OptionParser.parse(argv,
    strict: [tag: :string, release: :string, require_clean: :boolean]
  )

if args != [] or invalid != [],
  do: raise("usage: check_versions.exs [--tag TAG] [--release PATH] [--require-clean]")

opts =
  if not Keyword.has_key?(opts, :tag) and System.get_env("GITHUB_REF_TYPE") == "tag",
    do: Keyword.put(opts, :tag, System.fetch_env!("GITHUB_REF_NAME")),
    else: opts

root = Path.expand("..", __DIR__)
versions = Exiron.ReleaseMetadata.check!(root, opts)

unless Exiron.Hub.server_version() == versions.server and
         Mix.Project.config()[:version] == versions.server and
         Exiron.BuildInfo.current().server_version == versions.server,
       do: raise("compiled server/package version does not match VERSION")

example = ExironWeb.Schemas.AuthResponse.schema().example

unless example.server_version == versions.server and example.protocol_version == versions.protocol,
  do: raise("OpenAPI auth example version metadata is stale")

config = YamlElixir.read_from_file!(Path.join(root, "config/config.example.yml"))

unless config["version"] == Exiron.Hub.Configuration.schema_version(),
  do: raise("configuration example schema version is stale")

IO.puts(
  "Server/SDK versions, protocol fixtures, schema examples and requested release metadata are consistent"
)
