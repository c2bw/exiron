package exiron

import (
	"errors"
	"math"
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func isRateLimited(err error) bool {
	var e *Error
	return errors.As(err, &e) && e.StatusCode == http.StatusTooManyRequests
}

func nextRetryDelay(delay, maximum time.Duration) time.Duration {
	if delay >= maximum || delay > maximum-delay {
		return maximum
	}
	return delay * 2
}

func retryDelay(policy RetryPolicy, base time.Duration, err error) time.Duration {
	// A server hint is a minimum and must never be shortened by jitter or MaxDelay.
	var e *Error
	if errors.As(err, &e) && (IsHookAlreadyConnected(err) || isRateLimited(err)) && e.RetryAfterMS > 0 {
		if uint64(e.RetryAfterMS) > uint64(math.MaxInt64/int64(time.Millisecond)) {
			return time.Duration(math.MaxInt64)
		}
		return time.Duration(e.RetryAfterMS) * time.Millisecond
	}
	if base > policy.MaxDelay {
		base = policy.MaxDelay
	}
	if policy.DisableJitter || base <= 1 {
		return base
	}
	half := base / 2
	return half + time.Duration(rand.Int64N(int64(base-half)+1))
}

func responseError(status int, body []byte, headers http.Header, now time.Time) *Error {
	e := apiError(status, body)
	if status != http.StatusTooManyRequests {
		return e
	}
	raw := strings.TrimSpace(headers.Get("Retry-After"))
	var delay time.Duration
	if raw != "" && strings.IndexFunc(raw, func(r rune) bool { return r < '0' || r > '9' }) == -1 {
		seconds, err := strconv.ParseUint(raw, 10, 64)
		if err != nil || seconds > uint64(math.MaxInt64/int64(time.Second)) {
			delay = time.Duration(math.MaxInt64)
		} else {
			delay = time.Duration(seconds) * time.Second
		}
	} else if date, err := http.ParseTime(raw); err == nil {
		delay = date.Sub(now)
	}
	if delay > 0 {
		// Round up so conversion to milliseconds cannot retry before the hint.
		ms := int64(delay / time.Millisecond)
		if delay%time.Millisecond != 0 {
			ms++
		}
		if ms > int64(int(^uint(0)>>1)) {
			ms = int64(int(^uint(0) >> 1))
		}
		if ms > int64(e.RetryAfterMS) {
			e.RetryAfterMS = int(ms)
		}
	}
	return e
}
