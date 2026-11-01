package exiron

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/url"
	"time"
)

func (c *Client) request(ctx context.Context, method, path, bearer string, payload any, response any) (result error) {
	attempts, status := 0, 0
	if c.onRequest != nil {
		started := time.Now()
		defer func() {
			c.observeRequest(RequestEvent{Method: requestMethod(method), Route: requestRoute(path), DurationMS: time.Since(started).Milliseconds(), Attempts: attempts, HTTPStatus: status, ErrorKind: ClassifyError(result)})
		}()
	}
	var err error
	if data, ok := payload.(sizedPayload); ok {
		if err := c.checkDataSize(int64(len(data.data)), data.build(nil)); err != nil {
			return err
		}
		payload = data.build(data.data)
	}
	body, err := encodeBody(payload)
	if err != nil {
		return err
	}

	if int64(len(body)) > c.maxRequestBytes {
		return c.requestTooLarge(int64(len(body)))
	}
	started := time.Now()
	delay := c.retry.InitialDelay
	retryable := retryableRequest(method, path)

	for {
		if ctx.Err() != nil {
			return transportError(ctx.Err())
		}
		attempts++
		status = 0
		err = c.do(ctx, method, path, bearer, body, payload != nil, response, &status)
		if err == nil {
			return nil
		}
		if !retryable {
			return err
		}
		conflictHint := hookAlreadyConnectedHint(err)
		if !isTransportError(err) && !conflictHint && !isRateLimited(err) {
			return err
		}
		wait := retryDelay(c.retry, delay, err)
		if !canRetry(c.retry, started, wait) {
			return err
		}
		if sleepErr := c.retry.Sleep(ctx, wait); sleepErr != nil {
			return transportError(sleepErr)
		}
		if ctx.Err() != nil {
			return transportError(ctx.Err())
		}
		if !canRetry(c.retry, started, 0) {
			return err
		}
		if !IsHookAlreadyConnected(err) {
			delay = nextRetryDelay(delay, c.retry.MaxDelay)
		}
	}
}

func retryableRequest(method, path string) bool {
	if method == http.MethodGet {
		requestURL, err := url.Parse(path)
		if err == nil && requestURL.Path == "/api/requests" {
			return requestURL.Query().Get("delivery_mode") == "explicit"
		}
	}

	switch method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return true
	case http.MethodPost:
		return path == "/api/auth"
	default:
		return false
	}
}

func (c *Client) do(ctx context.Context, method, path, bearer string, body []byte, hasBody bool, response any, status *int) error {
	var requestBody io.Reader
	if hasBody {
		requestBody = bytes.NewReader(body)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.baseURL+path, requestBody)
	if err != nil {
		return invalidResponse("could not build request", err)
	}
	req.Header.Set("accept", "application/json")
	req.Header.Set("x-exiron-sdk", "go")
	req.Header.Set("x-exiron-sdk-version", Version())
	if hasBody {
		req.Header.Set("content-type", "application/json")
	}
	if bearer != "" {
		req.Header.Set("authorization", "Bearer "+bearer)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return transportError(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 100 && resp.StatusCode <= 599 {
		*status = resp.StatusCode
	}

	responseBody, err := readResponseBody(resp.Body, c.maxResponseBytes)
	if err != nil {
		return err
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return responseError(resp.StatusCode, responseBody, resp.Header, time.Now())
	}
	if response == nil || len(responseBody) == 0 {
		return nil
	}
	if err := json.Unmarshal(responseBody, response); err != nil {
		return invalidResponse("response body is not valid JSON", err)
	}
	return nil
}

func readResponseBody(body io.Reader, maxBytes int64) ([]byte, error) {
	readLimit := maxBytes
	if readLimit < math.MaxInt64 {
		readLimit++
	}

	responseBody, err := io.ReadAll(io.LimitReader(body, readLimit))
	if err != nil {
		return nil, invalidResponse("could not read response body", err)
	}
	if int64(len(responseBody)) > maxBytes {
		return nil, invalidResponse("response body exceeds configured size limit", nil)
	}
	return responseBody, nil
}

func encodeBody(payload any) ([]byte, error) {
	if payload == nil {
		return nil, nil
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return nil, &Error{Reason: "request_error", Message: "could not encode request body", Err: err}
	}
	return body, nil
}

func isTransportError(err error) bool {
	var apiErr *Error
	if !errors.As(err, &apiErr) {
		return false
	}
	return apiErr.Reason == "transport_error"
}

func hookAlreadyConnectedHint(err error) bool {
	var apiErr *Error
	return errors.As(err, &apiErr) && IsHookAlreadyConnected(apiErr) && apiErr.RetryAfterMS > 0
}

func canRetry(policy RetryPolicy, started time.Time, delay time.Duration) bool {
	if policy.InitialDelay <= 0 || policy.MaxElapsed <= 0 {
		return false
	}
	elapsed := time.Since(started)
	return elapsed <= policy.MaxElapsed && delay <= policy.MaxElapsed-elapsed
}
