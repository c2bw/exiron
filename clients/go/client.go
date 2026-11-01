package exiron

import (
	"net/http"
)

// Client talks to an Exiron server.
type Client struct {
	onRequest        func(RequestEvent)
	baseURL          string
	token            string
	httpClient       *http.Client
	retry            RetryPolicy
	clientID         string
	listen           string
	transport        Transport
	maxResponseBytes int64
	maxRequestBytes  int64
}
