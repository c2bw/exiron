package exiron

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
)

func validIdempotencyKey(key string) bool {
	if len(key) < 1 || len(key) > 128 {
		return false
	}
	for _, c := range []byte(key) {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == ':' || c == '-') {
			return false
		}
	}
	return true
}
func keyedMutationPath(operation, key string) (string, error) {
	if key == "" {
		return "/api/" + operation, nil
	}
	if !validIdempotencyKey(key) {
		return "", invalidResponse("invalid idempotency key", nil)
	}
	return "/api/idempotent/" + operation, nil
}
func streamIdempotencyKey(base, reqID, text string, final bool) string {
	phase := "0"
	if final {
		phase = "1"
	}
	digest := sha256.Sum256([]byte(base + "\x00" + reqID + "\x00" + phase + "\x00" + text))
	return "s-" + hex.EncodeToString(digest[:])
}
func IsIdempotencyConflict(err error) bool {
	var e *Error
	return errors.As(err, &e) && e.Reason == "idempotency_conflict"
}
func IsIdempotencyInProgress(err error) bool {
	var e *Error
	return errors.As(err, &e) && e.Reason == "idempotency_in_progress"
}
func IsIdempotencyUnavailable(err error) bool {
	var e *Error
	return errors.As(err, &e) && (e.Reason == "idempotency_result_unavailable" || e.Reason == "idempotency_capacity_exceeded")
}
