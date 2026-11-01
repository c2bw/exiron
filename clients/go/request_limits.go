package exiron

import (
	"encoding/json"
	"fmt"
	"math"
)

// sizedPayload defers base64 allocation until the complete wire size is checked.
type sizedPayload struct {
	data  []byte
	build func([]byte) any
}

func base64Size(n int64) int64 {
	// Divide first to avoid overflow for large logical lengths.
	size := (uint64(n)/3)*4 + ((uint64(n)%3+2)/3)*4
	if size > math.MaxInt64 {
		return math.MaxInt64
	}
	return int64(size)
}

func (c *Client) requestTooLarge(size int64) *Error {
	return &Error{Reason: "payload_too_large", Message: fmt.Sprintf("encoded request body is %d bytes; limit is %d bytes", size, c.maxRequestBytes)}
}

func (c *Client) checkDataSize(rawSize int64, metadata any) error {
	// This inexpensive bound rejects large raw files before metadata or base64 encoding.
	if rawSize > c.maxRequestBytes {
		return c.requestTooLarge(rawSize)
	}
	encodedSize := base64Size(rawSize)
	if encodedSize > c.maxRequestBytes {
		return c.requestTooLarge(encodedSize)
	}
	body, err := encodeBody(metadata)
	if err != nil {
		return err
	}
	if int64(len(body)) > c.maxRequestBytes-encodedSize {
		total := uint64(len(body)) + uint64(encodedSize)
		if total > math.MaxInt64 {
			return c.requestTooLarge(math.MaxInt64)
		}
		return c.requestTooLarge(int64(total))
	}
	return nil
}

func (c *Client) albumData(items []MediaItem, metadata any) ([]byte, error) {
	if len(items) < 2 || len(items) > 10 {
		return nil, invalidResponse("albums require 2..10 items", nil)
	}
	size := int64(2 + len(items) - 1) // Array brackets and commas.
	if size > c.maxRequestBytes {
		return nil, c.requestTooLarge(size)
	}
	for _, item := range items {
		if !albumDatatype(item.Datatype) {
			return nil, invalidResponse("invalid album member datatype", nil)
		}
		raw := int64(len(item.Data))
		if raw > c.maxRequestBytes {
			return nil, c.requestTooLarge(raw)
		}
		// Preserve nil as null, while non-nil empty bytes serialize as an empty string.
		if item.Data != nil {
			item.Data = []byte{}
		}
		body, err := json.Marshal(item)
		if err != nil {
			return nil, invalidResponse("invalid media album", err)
		}
		addition := uint64(len(body)) + uint64(base64Size(raw))
		if addition > uint64(c.maxRequestBytes-size) {
			total := uint64(size) + addition
			if total > math.MaxInt64 {
				total = math.MaxInt64
			}
			return nil, c.requestTooLarge(int64(total))
		}
		size += int64(addition)
	}
	// The album JSON is itself base64 encoded in the outer request's data field.
	if err := c.checkDataSize(size, metadata); err != nil {
		return nil, err
	}
	return encodeAlbum(items)
}
