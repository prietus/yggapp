package yggkit

import (
	"encoding/binary"
	"net"
	"sync"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// defaultResolvers are Revertron's ALFIS resolvers inside Yggdrasil
// (https://dns.r3v.dev, checked 2026-11-03). Frankfurt first: fastest from
// Europe in testing. They also serve OpenNIC and block ads (AdGuard Home).
var defaultResolvers = []string{
	"308:84:68:55::", // Frankfurt
	"308:62:45:62::", // Amsterdam
	"308:25:40:bd::", // Bratislava
	"308:c8:48:45::", // Buffalo, US
}

const (
	fwdPort       = 5300 // source port for forwarded queries from the node address
	fwdTimeout    = 1500 * time.Millisecond
	fwdDeadline   = 5 * time.Second
	fwdMaxPending = 256
	fwdTick       = 250 * time.Millisecond
)

func parseResolvers(list []string) [][16]byte {
	var out [][16]byte
	for _, s := range list {
		ip := net.ParseIP(s)
		if ip == nil || ip.To4() != nil || ip[0]&0xFE != 0x02 {
			continue
		}
		var a [16]byte
		copy(a[:], ip.To16())
		out = append(out, a)
	}
	return out
}

type pendingQuery struct {
	client     [16]byte
	clientPort uint16
	clientID   uint16
	query      []byte // as sent upstream (our ID)
	server     int
	tried      int
	sent       time.Time
	started    time.Time
}

// forwarder relays queries the local table can't answer to upstream ALFIS
// resolvers over Yggdrasil, retrying the next resolver on timeout and
// remembering which one answered last.
type forwarder struct {
	self    [16]byte // node address: source of forwarded queries
	dnsAddr [16]byte // address the client asked; source of relayed answers
	servers [][16]byte
	write   func([]byte)     // into Yggdrasil
	deliver func([]byte)     // back to the TUN
	now     func() time.Time // for tests
	timeout time.Duration
	limit   time.Duration

	mu        sync.Mutex
	pending   map[uint16]*pendingQuery
	nextID    uint16
	preferred int
}

func newForwarder(self, dnsAddr [16]byte, servers [][16]byte, write, deliver func([]byte)) *forwarder {
	return &forwarder{
		self: self, dnsAddr: dnsAddr, servers: servers,
		write: write, deliver: deliver, now: time.Now,
		timeout: fwdTimeout, limit: fwdDeadline,
		pending: make(map[uint16]*pendingQuery),
	}
}

// forward sends the client's query upstream under a fresh ID.
func (f *forwarder) forward(client [16]byte, clientPort uint16, query []byte) {
	if len(query) < 12 || len(f.servers) == 0 {
		return
	}
	f.mu.Lock()
	if len(f.pending) >= fwdMaxPending {
		f.mu.Unlock()
		if fail := servfail(query); fail != nil {
			f.deliver(udp6Packet(f.dnsAddr, client, 53, clientPort, fail))
		}
		return
	}
	id := f.nextID
	for f.pending[id] != nil {
		id++
	}
	f.nextID = id + 1
	q := append([]byte(nil), query...)
	clientID := binary.BigEndian.Uint16(q[0:2])
	binary.BigEndian.PutUint16(q[0:2], id)
	now := f.now()
	p := &pendingQuery{
		client: client, clientPort: clientPort, clientID: clientID,
		query: q, server: f.preferred, sent: now, started: now,
	}
	f.pending[id] = p
	pkt := udp6Packet(f.self, f.servers[p.server], fwdPort, 53, q)
	f.mu.Unlock()
	f.write(pkt)
}

// handleReply recognises an upstream answer coming out of Yggdrasil. It
// returns the packet to hand to the TUN (nil if nothing to deliver) and
// whether the packet was a forwarder reply at all.
func (f *forwarder) handleReply(b []byte) ([]byte, bool) {
	if len(b) < 48+12 || b[0]>>4 != 6 || b[6] != 17 {
		return nil, false
	}
	if [16]byte(b[24:40]) != f.self ||
		binary.BigEndian.Uint16(b[40:42]) != 53 ||
		binary.BigEndian.Uint16(b[42:44]) != fwdPort {
		return nil, false
	}
	server := -1
	for i, s := range f.servers {
		if [16]byte(b[8:24]) == s {
			server = i
			break
		}
	}
	if server < 0 {
		return nil, false
	}
	udpLen := int(binary.BigEndian.Uint16(b[44:46]))
	if udpLen < 8+12 || 40+udpLen > len(b) {
		return nil, true
	}
	payload := b[48 : 40+udpLen]
	id := binary.BigEndian.Uint16(payload[0:2])

	f.mu.Lock()
	p := f.pending[id]
	if p != nil {
		delete(f.pending, id)
		f.preferred = server
	}
	f.mu.Unlock()
	if p == nil {
		return nil, true // late or duplicate answer
	}
	resp := append([]byte(nil), payload...)
	binary.BigEndian.PutUint16(resp[0:2], p.clientID)
	return udp6Packet(f.dnsAddr, p.client, 53, p.clientPort, resp), true
}

// tick retries timed-out queries on the next resolver and gives up with
// SERVFAIL once every resolver was tried or the deadline passed.
func (f *forwarder) tick() {
	now := f.now()
	var resend, fail [][]byte
	f.mu.Lock()
	for id, p := range f.pending {
		if now.Sub(p.sent) < f.timeout {
			continue
		}
		if p.tried+1 >= len(f.servers) || now.Sub(p.started) >= f.limit {
			delete(f.pending, id)
			if sf := servfail(p.query); sf != nil {
				binary.BigEndian.PutUint16(sf[0:2], p.clientID)
				fail = append(fail, udp6Packet(f.dnsAddr, p.client, 53, p.clientPort, sf))
			}
			continue
		}
		p.tried++
		p.server = (p.server + 1) % len(f.servers)
		p.sent = now
		resend = append(resend, udp6Packet(f.self, f.servers[p.server], fwdPort, 53, p.query))
	}
	f.mu.Unlock()
	for _, pkt := range resend {
		f.write(pkt)
	}
	for _, pkt := range fail {
		f.deliver(pkt)
	}
}

func (f *forwarder) run(stop <-chan struct{}) {
	t := time.NewTicker(fwdTick)
	defer t.Stop()
	for {
		select {
		case <-t.C:
			f.tick()
		case <-stop:
			return
		}
	}
}

// servfail builds a SERVFAIL reply echoing the query's ID and question.
func servfail(query []byte) []byte {
	var p dnsmessage.Parser
	hdr, err := p.Start(query)
	if err != nil {
		return nil
	}
	q, err := p.Question()
	if err != nil {
		return nil
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{
		ID: hdr.ID, Response: true, RecursionDesired: hdr.RecursionDesired,
		RecursionAvailable: true, RCode: dnsmessage.RCodeServerFailure,
	})
	if b.StartQuestions() != nil || b.Question(q) != nil {
		return nil
	}
	out, err := b.Finish()
	if err != nil {
		return nil
	}
	return out
}

// udp6Packet builds an IPv6/UDP packet with a valid checksum.
func udp6Packet(src, dst [16]byte, sport, dport uint16, payload []byte) []byte {
	pkt := make([]byte, 48+len(payload))
	pkt[0] = 0x60
	binary.BigEndian.PutUint16(pkt[4:6], uint16(8+len(payload)))
	pkt[6], pkt[7] = 17, 64 // UDP, hop limit
	copy(pkt[8:24], src[:])
	copy(pkt[24:40], dst[:])
	binary.BigEndian.PutUint16(pkt[40:42], sport)
	binary.BigEndian.PutUint16(pkt[42:44], dport)
	binary.BigEndian.PutUint16(pkt[44:46], uint16(8+len(payload)))
	copy(pkt[48:], payload)
	binary.BigEndian.PutUint16(pkt[46:48], udp6Checksum(pkt))
	return pkt
}
