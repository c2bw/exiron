package exiron

import (
	_ "embed"
	"strings"
)

//go:embed VERSION
var sdkVersion string

// Version identifies this SDK source/package, independently of ProtocolVersion.
func Version() string { return strings.TrimSpace(sdkVersion) }
