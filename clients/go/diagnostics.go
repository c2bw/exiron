package exiron

// ErrorSummary is safe for routine logging. It excludes messages, URLs, IDs,
// credentials, response bodies and wrapped application errors.
type ErrorSummary struct {
	Kind       string
	HTTPStatus int
}

// SummarizeError keeps the original error available for explicit inspection.
func SummarizeError(err error) ErrorSummary {
	if err == nil {
		return ErrorSummary{Kind: "none"}
	}
	summary := runtimeError(err)
	return ErrorSummary{Kind: ClassifyError(err), HTTPStatus: summary.HTTPStatus}
}

// Formatting a client/config must never traverse credentials or HTTP adapters.
func (c Client) String() string   { return "exiron.Client{configuration:redacted}" }
func (c Client) GoString() string { return c.String() }
func (c Config) String() string   { return "exiron.Config{configuration:redacted}" }
func (c Config) GoString() string { return c.String() }
