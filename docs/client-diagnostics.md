# Safe client diagnostics

For routine logs use `exiron.SummarizeError(err)` in Go or
`ExironClient.Error.summary(error)` in Elixir. Each returns only a closed error
category and a validated HTTP status. Neither includes server/application error
text, URLs, credentials, request IDs or response bodies. Unknown errors use a
generic category. A nil error has category `none`.

Go client/config values also redact their configuration under `%v`, `%+v` and
`%#v`, including pointers and nested formatting. This does not protect explicit
access to exported configuration fields or serialization of those fields.

Existing error messages, bodies, causes and delivery diagnostics remain available
for deliberate inspection. Those raw values can contain application data and
must not be treated as sanitized logs. The summaries do not replace delivery
diagnostics or decide whether retrying a mutation is safe.
