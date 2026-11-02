// Package yggkit is a thin, gomobile-friendly wrapper around the Yggdrasil core
// for the YggApp iOS packet tunnel. Only gomobile-compatible types (string,
// []byte, int, bool, error, interfaces) are exposed.
package yggkit

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"runtime/debug"
	"sync"

	"github.com/gologme/log"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/ipv6rwc"
	"github.com/yggdrasil-network/yggdrasil-go/src/tun"
	"github.com/yggdrasil-network/yggdrasil-go/src/version"
)

// iOS kills network extensions above ~50 MB; keep the Go heap well below.
const memoryLimit = 30 << 20

// Logger is implemented on the Swift side (e.g. forwarding to os_log).
type Logger interface {
	Log(line string)
}

type logWriter struct{ l Logger }

func (w logWriter) Write(p []byte) (int, error) {
	if w.l != nil {
		w.l.Log(string(p))
	}
	return len(p), nil
}

// Node is a running Yggdrasil node bound to an iOS utun file descriptor.
type Node struct {
	mu     sync.Mutex
	core   *core.Core
	rwc    *ipv6rwc.ReadWriteCloser
	tun    *tun.TunAdapter
	dns    *dnsInterceptor
	logger *log.Logger
	hosts  hostTable // survives restarts; filled by SetHostsJSON
}

func NewNode() *Node { return &Node{} }

// Start brings up the node from a JSON config without a TUN. Call MTU() and
// Address() to configure the tunnel, then AttachTUN with the utun descriptor.
func (n *Node) Start(configJSON string, logger Logger) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.core != nil {
		return errors.New("node already running")
	}
	debug.SetMemoryLimit(memoryLimit)

	lg := log.New(logWriter{logger}, "", 0)
	for _, lvl := range []string{"error", "warn", "info"} {
		lg.EnableLevel(lvl)
	}

	cfg := config.GenerateConfig()
	if err := cfg.UnmarshalHJSON([]byte(configJSON)); err != nil {
		return fmt.Errorf("config: %w", err)
	}

	yggRange := net.IPNet{IP: net.ParseIP("200::"), Mask: net.CIDRMask(7, 128)}
	opts := []core.SetupOption{
		core.NodeInfo(cfg.NodeInfo),
		core.NodeInfoPrivacy(cfg.NodeInfoPrivacy),
		// Never peer over Yggdrasil itself.
		core.PeerFilter(func(ip net.IP) bool { return !yggRange.Contains(ip) }),
	}
	for _, p := range cfg.Peers {
		opts = append(opts, core.Peer{URI: p})
	}
	for _, k := range cfg.AllowedPublicKeys {
		b, err := hex.DecodeString(k)
		if err != nil {
			return fmt.Errorf("AllowedPublicKeys: %w", err)
		}
		opts = append(opts, core.AllowedPublicKey(b))
	}
	// Multicast is intentionally not started: it needs Apple's multicast entitlement.

	c, err := core.New(cfg.Certificate, lg, opts...)
	if err != nil {
		return fmt.Errorf("core: %w", err)
	}

	rwc := ipv6rwc.NewReadWriteCloser(c)
	mtu := cfg.IfMTU
	if rwc.MaxMTU() < mtu {
		mtu = rwc.MaxMTU()
	}
	rwc.SetMTU(mtu)

	n.core, n.rwc, n.logger = c, rwc, lg
	lg.Infof("yggkit started: %s", c.Address())
	return nil
}

// AttachTUN hands the utun file descriptor to Go, which then moves packets
// between the tunnel and Yggdrasil without crossing into Swift.
func (n *Node) AttachTUN(fd int32) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.core == nil {
		return errors.New("node not running")
	}
	if n.tun != nil {
		return errors.New("tun already attached")
	}
	d := newDNSInterceptor(n.rwc, dnsAddrFor(n.core), &n.hosts)
	t, err := tun.New(d, n.logger, tun.FileDescriptor(fd), tun.InterfaceMTU(n.rwc.MTU()))
	if err != nil {
		return fmt.Errorf("tun: %w", err)
	}
	n.tun, n.dns = t, d
	return nil
}

func (n *Node) Stop() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.core == nil {
		return nil
	}
	if n.tun != nil {
		_ = n.tun.Stop()
	}
	if n.dns != nil {
		n.dns.shutdown()
	}
	n.core.Stop()
	n.core, n.rwc, n.tun, n.dns = nil, nil, nil, nil
	return nil
}

func (n *Node) IsRunning() bool {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.core != nil
}

func (n *Node) running() (*core.Core, error) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.core == nil {
		return nil, errors.New("node not running")
	}
	return n.core, nil
}

func (n *Node) Address() string {
	if c, err := n.running(); err == nil {
		return c.Address().String()
	}
	return ""
}

func (n *Node) Subnet() string {
	if c, err := n.running(); err == nil {
		s := c.Subnet()
		return s.String()
	}
	return ""
}

func (n *Node) PublicKey() string {
	if c, err := n.running(); err == nil {
		return hex.EncodeToString(c.PublicKey())
	}
	return ""
}

// MTU must be called after Start; it is the MTU to set on the tunnel.
func (n *Node) MTU() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.rwc == nil {
		return 0
	}
	return int(n.rwc.MTU())
}

func (n *Node) AddPeer(uri string) error {
	c, err := n.running()
	if err != nil {
		return err
	}
	u, err := url.Parse(uri)
	if err != nil {
		return err
	}
	return c.AddPeer(u, "")
}

func (n *Node) RemovePeer(uri string) error {
	c, err := n.running()
	if err != nil {
		return err
	}
	u, err := url.Parse(uri)
	if err != nil {
		return err
	}
	return c.RemovePeer(u, "")
}

func (n *Node) RetryPeers() {
	if c, err := n.running(); err == nil {
		c.RetryPeersNow()
	}
}

// DNSAddress is the in-tunnel resolver address (<subnet>::53) answered locally
// for ALFIS names. Point the tunnel's DNS settings at it.
func (n *Node) DNSAddress() string {
	c, err := n.running()
	if err != nil {
		return ""
	}
	a := dnsAddrFor(c)
	return net.IP(a[:]).String()
}

// SetHostsJSON replaces the local name table ({"forum.ygg": "21a:…"});
// invalid entries are skipped (see HostCount). Works before or after Start.
func (n *Node) SetHostsJSON(hostsJSON string) error {
	m, err := parseHostsJSON(hostsJSON)
	if err != nil {
		return err
	}
	n.hosts.set(m)
	return nil
}

func (n *Node) HostCount() int { return n.hosts.len() }

// RoutingEntries is the size of the node's routing table: 0 means isolated,
// growing numbers mean it is learning the network.
func (n *Node) RoutingEntries() int {
	if c, err := n.running(); err == nil {
		return int(c.GetSelf().RoutingEntries)
	}
	return 0
}

// peerJSON is the stable shape the Swift side decodes.
type peerJSON struct {
	URI       string  `json:"uri"`
	Up        bool    `json:"up"`
	Inbound   bool    `json:"inbound"`
	Address   string  `json:"address"`
	PublicKey string  `json:"publicKey"`
	LatencyMs float64 `json:"latencyMs"`
	UptimeS   float64 `json:"uptimeS"`
	RXBytes   uint64  `json:"rxBytes"`
	TXBytes   uint64  `json:"txBytes"`
	LastError string  `json:"lastError,omitempty"`
}

// PeersJSON returns a JSON array of peers ("[]" when stopped).
func (n *Node) PeersJSON() string {
	c, err := n.running()
	if err != nil {
		return "[]"
	}
	out := []peerJSON{}
	for _, p := range c.GetPeers() {
		pj := peerJSON{
			URI:       p.URI,
			Up:        p.Up,
			Inbound:   p.Inbound,
			PublicKey: hex.EncodeToString(p.Key),
			LatencyMs: float64(p.Latency.Microseconds()) / 1000,
			UptimeS:   p.Uptime.Seconds(),
			RXBytes:   p.RXBytes,
			TXBytes:   p.TXBytes,
		}
		if a := address.AddrForKey(p.Key); a != nil && len(p.Key) > 0 {
			pj.Address = net.IP(a[:]).String()
		}
		if p.LastError != nil {
			pj.LastError = p.LastError.Error()
		}
		out = append(out, pj)
	}
	b, _ := json.Marshal(out)
	return string(b)
}

// GenerateConfig returns a fresh JSON config (new keypair, no TUN name,
// no multicast) suitable for storing in the app.
func GenerateConfig() (string, error) {
	cfg := config.GenerateConfig()
	cfg.IfName = "none"
	cfg.MulticastInterfaces = nil
	cfg.Listen = nil
	cfg.AdminListen = "none"
	b, err := json.Marshal(cfg)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// AddressForConfig derives the IPv6 address from a config without starting a node.
func AddressForConfig(configJSON string) string {
	cfg := config.GenerateConfig()
	if err := cfg.UnmarshalHJSON([]byte(configJSON)); err != nil {
		return ""
	}
	if len(cfg.PrivateKey) != ed25519.PrivateKeySize {
		return ""
	}
	pub := ed25519.PrivateKey(cfg.PrivateKey).Public().(ed25519.PublicKey)
	if a := address.AddrForKey(pub); a != nil {
		return net.IP(a[:]).String()
	}
	return ""
}

func Version() string { return version.BuildVersion() }
