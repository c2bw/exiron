[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "scripts/release_smoke.exs",
    "scripts/check_versions.exs"
  ]
]
