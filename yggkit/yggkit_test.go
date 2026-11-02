package yggkit

import (
	"encoding/json"
	"strings"
	"testing"
)

type testLogger struct{ t *testing.T }

func (l testLogger) Log(s string) { l.t.Log(strings.TrimSpace(s)) }

func TestNodeLifecycle(t *testing.T) {
	cfg, err := GenerateConfig()
	if err != nil {
		t.Fatal(err)
	}
	want := AddressForConfig(cfg)
	if !strings.HasPrefix(want, "2") {
		t.Fatalf("unexpected address %q", want)
	}

	n := NewNode()
	if err := n.Start(cfg, testLogger{t}); err != nil {
		t.Fatal(err)
	}
	if err := n.Start(cfg, nil); err == nil {
		t.Fatal("second Start should fail")
	}
	if got := n.Address(); got != want {
		t.Fatalf("Address()=%q want %q", got, want)
	}
	if n.AttachTUN(-1) == nil {
		t.Fatal("AttachTUN with bad fd should fail")
	}
	if da := n.DNSAddress(); !strings.HasPrefix(da, "3") || !strings.HasSuffix(da, "::53") {
		t.Fatalf("DNSAddress()=%q", da)
	}
	if err := n.SetHostsJSON(`{"forum.ygg":"21a:34aa:c782:3ad2:1bf8:73f8:141:66e8"}`); err != nil || n.HostCount() != 1 {
		t.Fatalf("SetHostsJSON: %d %v", n.HostCount(), err)
	}
	if n.RoutingEntries() < 0 {
		t.Fatal("RoutingEntries negative")
	}
	if n.MTU() <= 0 {
		t.Fatal("MTU not set")
	}

	const peer = "tls://192.0.2.1:443" // TEST-NET, never reachable
	if err := n.AddPeer(peer); err != nil {
		t.Fatal(err)
	}
	var peers []peerJSON
	if err := json.Unmarshal([]byte(n.PeersJSON()), &peers); err != nil {
		t.Fatal(err)
	}
	if err := n.RemovePeer(peer); err != nil {
		t.Fatal(err)
	}

	if err := n.Stop(); err != nil {
		t.Fatal(err)
	}
	if n.IsRunning() || n.PeersJSON() != "[]" || n.AddPeer(peer) == nil {
		t.Fatal("node should be stopped")
	}
}
