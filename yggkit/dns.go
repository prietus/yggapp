package yggkit

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"strings"
	"sync"

	"golang.org/x/net/dns/dnsmessage"

	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/tun"
)

// dnsTTL is short so names refreshed from the directory take effect quickly.
const dnsTTL = 300

// hostTable maps lower-case names without trailing dot ("forum.ygg") to IPv6 addresses.
type hostTable struct {
	mu    sync.RWMutex
	hosts map[string][16]byte
}

func (h *hostTable) set(m map[string][16]byte) {
	h.mu.Lock()
	h.hosts = m
	h.mu.Unlock()
}

func (h *hostTable) lookup(name string) ([16]byte, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	a, ok := h.hosts[name]
	return a, ok
}

func (h *hostTable) len() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.hosts)
}

// parseHostsJSON accepts {"name.ygg": "200:…", …}; it skips invalid entries
// and only keeps addresses inside 200::/7.
func parseHostsJSON(s string) (map[string][16]byte, error) {
	var raw map[string]string
	if err := json.Unmarshal([]byte(s), &raw); err != nil {
		return nil, err
	}
	out := make(map[string][16]byte, len(raw))
	for name, addr := range raw {
		ip := net.ParseIP(strings.Trim(addr, "[]"))
		if ip == nil || ip.To4() != nil || ip[0]&0xFE != 0x02 {
			continue
		}
		var a [16]byte
		copy(a[:], ip.To16())
		out[normalizeName(name)] = a
	}
	return out, nil
}

func normalizeName(n string) string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(n), "."))
}

// dnsInterceptor sits between the TUN and Yggdrasil. UDP packets to
// dnsAddr:53 are answered locally from the host table; names it doesn't know
// are forwarded to upstream ALFIS resolvers (when configured). Everything else
// passes through untouched. Responses are injected into the TUN's read path.
type dnsInterceptor struct {
	tun.ReadWriteCloser
	dnsAddr [16]byte
	hosts   *hostTable
	fwd     *forwarder // nil: unknown names get NXDOMAIN
	writeMu sync.Mutex // the TUN goroutine and the forwarder both write to Yggdrasil

	once   sync.Once
	in     chan readResult
	ack    chan struct{}
	inject chan []byte
	closed chan struct{}
}

type readResult struct {
	b   []byte
	err error
}

func newDNSInterceptor(inner tun.ReadWriteCloser, dnsAddr [16]byte, hosts *hostTable, resolvers [][16]byte) *dnsInterceptor {
	d := &dnsInterceptor{
		ReadWriteCloser: inner,
		dnsAddr:         dnsAddr,
		hosts:           hosts,
		in:              make(chan readResult),
		ack:             make(chan struct{}),
		inject:          make(chan []byte, 16),
		closed:          make(chan struct{}),
	}
	if len(resolvers) > 0 {
		self := inner.Address()
		d.fwd = newForwarder([16]byte(self), dnsAddr, resolvers, d.writeInner, d.deliver)
	}
	return d
}

func (d *dnsInterceptor) writeInner(b []byte) {
	d.writeMu.Lock()
	defer d.writeMu.Unlock()
	_, _ = d.ReadWriteCloser.Write(b)
}

// deliver queues a packet for the TUN; drops it if the reader is backed up
// (the client will retry).
func (d *dnsInterceptor) deliver(b []byte) {
	select {
	case d.inject <- b:
	default:
	}
}

func (d *dnsInterceptor) start() {
	go d.pump()
	if d.fwd != nil {
		go d.fwd.run(d.closed)
	}
}

// pump reads from Yggdrasil into a single reusable buffer and hands each
// packet to Read, waiting until it has been copied out.
func (d *dnsInterceptor) pump() {
	buf := make([]byte, 65535)
	for {
		n, err := d.ReadWriteCloser.Read(buf)
		select {
		case d.in <- readResult{buf[:n], err}:
			<-d.ack
		case <-d.closed:
			return
		}
		if err != nil {
			return
		}
	}
}

func (d *dnsInterceptor) Read(p []byte) (int, error) {
	d.once.Do(d.start)
	for {
		select {
		case b := <-d.inject:
			return copy(p, b), nil
		case r := <-d.in:
			if d.fwd != nil && r.err == nil {
				if out, ok := d.fwd.handleReply(r.b); ok {
					d.ack <- struct{}{}
					if out == nil {
						continue // stray upstream answer: nothing for the TUN
					}
					return copy(p, out), nil
				}
			}
			n := copy(p, r.b)
			d.ack <- struct{}{}
			return n, r.err
		case <-d.closed:
			return 0, io.EOF
		}
	}
}

func (d *dnsInterceptor) Write(p []byte) (int, error) {
	if q, ok := d.matchDNS(p); ok {
		payload, found, err := d.resolve(q)
		switch {
		case err != nil:
		case !found && d.fwd != nil:
			d.fwd.forward([16]byte(p[8:24]), binary.BigEndian.Uint16(p[40:42]), q)
		default:
			d.deliver(udp6Packet(d.dnsAddr, [16]byte(p[8:24]), 53, binary.BigEndian.Uint16(p[40:42]), payload))
		}
		return len(p), nil
	}
	d.writeMu.Lock()
	defer d.writeMu.Unlock()
	return d.ReadWriteCloser.Write(p)
}

// shutdown stops Read without closing Yggdrasil (Node.Stop does that).
func (d *dnsInterceptor) shutdown() {
	select {
	case <-d.closed:
	default:
		close(d.closed)
	}
}

func (d *dnsInterceptor) Close() error {
	select {
	case <-d.closed:
	default:
		close(d.closed)
	}
	return d.ReadWriteCloser.Close()
}

// matchDNS returns the UDP payload if p is IPv6/UDP to dnsAddr:53 with no
// extension headers.
func (d *dnsInterceptor) matchDNS(p []byte) ([]byte, bool) {
	if len(p) < 48 || p[0]>>4 != 6 || p[6] != 17 {
		return nil, false
	}
	if [16]byte(p[24:40]) != d.dnsAddr || binary.BigEndian.Uint16(p[42:44]) != 53 {
		return nil, false
	}
	udpLen := int(binary.BigEndian.Uint16(p[44:46]))
	if udpLen < 8 || 40+udpLen > len(p) {
		return nil, false
	}
	return p[48 : 40+udpLen], true
}

// resolve answers from the host table. found=false means the name is not in
// the table (the payload is then an NXDOMAIN, used when there's no forwarder);
// known names asked for anything but AAAA get NOERROR with no answers (NODATA).
func (d *dnsInterceptor) resolve(query []byte) (payload []byte, found bool, err error) {
	var p dnsmessage.Parser
	hdr, err := p.Start(query)
	if err != nil {
		return nil, false, err
	}
	q, err := p.Question()
	if err != nil {
		return nil, false, err
	}

	rhdr := dnsmessage.Header{
		ID:                 hdr.ID,
		Response:           true,
		Authoritative:      true,
		RecursionDesired:   hdr.RecursionDesired,
		RecursionAvailable: true,
	}
	addr, found := d.hosts.lookup(normalizeName(q.Name.String()))
	if !found {
		rhdr.RCode = dnsmessage.RCodeNameError
	}

	b := dnsmessage.NewBuilder(make([]byte, 0, 512), rhdr)
	b.EnableCompression()
	if err := b.StartQuestions(); err != nil {
		return nil, false, err
	}
	if err := b.Question(q); err != nil {
		return nil, false, err
	}
	if found && q.Type == dnsmessage.TypeAAAA && q.Class == dnsmessage.ClassINET {
		if err := b.StartAnswers(); err != nil {
			return nil, false, err
		}
		rh := dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: dnsTTL}
		if err := b.AAAAResource(rh, dnsmessage.AAAAResource{AAAA: addr}); err != nil {
			return nil, false, err
		}
	}
	out, err := b.Finish()
	return out, found, err
}

// udp6Checksum computes the mandatory UDP checksum over the IPv6 pseudo-header.
func udp6Checksum(pkt []byte) uint16 {
	udp := pkt[40:]
	var sum uint32
	add := func(b []byte) {
		for i := 0; i+1 < len(b); i += 2 {
			sum += uint32(b[i])<<8 | uint32(b[i+1])
		}
		if len(b)%2 == 1 {
			sum += uint32(b[len(b)-1]) << 8
		}
	}
	add(pkt[8:40]) // src + dst
	sum += uint32(len(udp))
	sum += 17
	saved := [2]byte{udp[6], udp[7]}
	udp[6], udp[7] = 0, 0
	add(udp)
	udp[6], udp[7] = saved[0], saved[1]
	for sum>>16 != 0 {
		sum = sum&0xFFFF + sum>>16
	}
	cs := ^uint16(sum)
	if cs == 0 {
		cs = 0xFFFF
	}
	return cs
}

// dnsAddrFor returns <node /64 subnet>::53.
func dnsAddrFor(c *core.Core) [16]byte {
	var a [16]byte
	sn := c.Subnet()
	copy(a[:8], sn.IP.To16()[:8])
	a[15] = 0x53
	return a
}
