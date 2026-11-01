package exiron

import "testing"

func TestListenModeNormalization(t *testing.T) {
	tests := []struct {
		name   string
		config Config
		want   string
	}{
		{name: "explicit off", config: Config{ListenMode: ListenOff}, want: string(ListenOff)},
		{name: "explicit on", config: Config{ListenMode: ListenOn}, want: string(ListenOn)},
		{name: "explicit all", config: Config{ListenMode: ListenAll}, want: string(ListenAll)},
		{name: "empty is off", config: Config{}, want: string(ListenOff)},
		{name: "unknown is off", config: Config{ListenMode: ListenMode("future")}, want: string(ListenOff)},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := normalizeListenMode(test.config); got != test.want {
				t.Fatalf("normalizeListenMode(%#v) = %q, want %q", test.config, got, test.want)
			}
		})
	}
}

func TestListenOptionsSetExplicitMode(t *testing.T) {
	withListen := Config{}
	WithListen()(&withListen)
	if withListen.ListenMode != ListenOn {
		t.Fatalf("WithListen config = %#v, want ListenOn", withListen)
	}

	withListenAll := Config{}
	WithListenAll()(&withListenAll)
	if withListenAll.ListenMode != ListenAll {
		t.Fatalf("WithListenAll config = %#v, want ListenAll", withListenAll)
	}
}
