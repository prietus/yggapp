package yggkit

import (
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
)

// fakeRWC stands in for Yggdrasil: records writes, serves reads from a channel.
type fakeRWC struct {
	reads  chan []byte
	writes [][]byte
}

func (f *fakeRWC) Read(p []byte) (int, error) {
	b, ok := <-f.reads
	if !ok {
		return 0, io.EOF
	}
	return copy(p, b), nil
}
func (f *fakeRWC) Write(p []byte) (int, error) {
	f.writes = append(f.writes, append([]byte(nil), p...))
	return len(p), nil
}
func (f *fakeRWC) Close() error             { return nil }
func (f *fakeRWC) Address() address.Address { return address.Address{} }
func (f *fakeRWC) Subnet() address.Subnet   { return address.Subnet{} }
func (f *fakeRWC) MaxMTU() uint64           { return 65535 }
func (f *fakeRWC) SetMTU(uint64)            {}

var (
	testSrc     = ip16("201:a98b:d343:386f:6ee9:1524:1ad3:599c")
	testDNSAddr = ip16("301:a98b:d343:386f::53")
	forumAddr   = "21a:34aa:c782:3ad2:1bf8:73f8:141:66e8"
)

func ip16(s string) (a [16]byte) {
	copy(a[:], net.ParseIP(s).To16())
	return
}

func udpPacket(src, dst [16]byte, sport, dport uint16, payload []byte) []byte {
	pkt := make([]byte, 48+len(payload))
	pkt[0] = 0x60
	binary.BigEndian.PutUint16(pkt[4:6], uint16(8+len(payload)))
	pkt[6], pkt[7] = 17, 64
	copy(pkt[8:24], src[:])
	copy(pkt[24:40], dst[:])
	binary.BigEndian.PutUint16(pkt[40:42], sport)
	binary.BigEndian.PutUint16(pkt[42:44], dport)
	binary.BigEndian.PutUint16(pkt[44:46], uint16(8+len(payload)))
	copy(pkt[48:], payload)
	binary.BigEndian.PutUint16(pkt[46:48], udp6Checksum(pkt))
	return pkt
}

func query(t *testing.T, id uint16, name string, qtype dnsmessage.Type) []byte {
	t.Helper()
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, RecursionDesired: true})
	_ = b.StartQuestions()
	if err := b.Question(dnsmessage.Question{
		Name: dnsmessage.MustNewName(name), Type: qtype, Class: dnsmessage.ClassINET,
	}); err != nil {
		t.Fatal(err)
	}
	m, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func newTestInterceptor(t *testing.T) (*dnsInterceptor, *fakeRWC) {
	t.Helper()
	var hosts hostTable
	m, err := parseHostsJSON(`{"Forum.YGG.": "` + forumAddr + `", "bad.ygg": "1.2.3.4", "clear.ygg": "2001:db8::1"}`)
	if err != nil {
		t.Fatal(err)
	}
	if len(m) != 1 {
		t.Fatalf("want only the 200::/7 entry, got %v", m)
	}
	hosts.set(m)
	inner := &fakeRWC{reads: make(chan []byte)}
	d := newDNSInterceptor(inner, testDNSAddr, &hosts)
	t.Cleanup(d.shutdown)
	return d, inner
}

// roundTrip writes a DNS query packet and reads the injected response.
func roundTrip(t *testing.T, d *dnsInterceptor, q []byte) (dnsmessage.Message, []byte) {
	t.Helper()
	if _, err := d.Write(udpPacket(testSrc, testDNSAddr, 5555, 53, q)); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 2048)
	done := make(chan int, 1)
	go func() { n, _ := d.Read(buf); done <- n }()
	var n int
	select {
	case n = <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("no response injected")
	}
	pkt := buf[:n]

	if [16]byte(pkt[8:24]) != testDNSAddr || [16]byte(pkt[24:40]) != testSrc {
		t.Fatal("response addresses not swapped")
	}
	if binary.BigEndian.Uint16(pkt[40:42]) != 53 || binary.BigEndian.Uint16(pkt[42:44]) != 5555 {
		t.Fatal("response ports not swapped")
	}
	if got, want := binary.BigEndian.Uint16(pkt[46:48]), udp6Checksum(pkt); got != want {
		t.Fatalf("bad UDP checksum %04x want %04x", got, want)
	}
	var msg dnsmessage.Message
	if err := msg.Unpack(pkt[48:]); err != nil {
		t.Fatal(err)
	}
	return msg, pkt
}

func TestDNSAnswersKnownName(t *testing.T) {
	d, inner := newTestInterceptor(t)
	msg, _ := roundTrip(t, d, query(t, 0x1234, "forum.ygg.", dnsmessage.TypeAAAA))
	if msg.ID != 0x1234 || !msg.Response || msg.RCode != dnsmessage.RCodeSuccess {
		t.Fatalf("bad header %+v", msg.Header)
	}
	if len(msg.Answers) != 1 {
		t.Fatalf("want 1 answer, got %d", len(msg.Answers))
	}
	aaaa := msg.Answers[0].Body.(*dnsmessage.AAAAResource)
	if net.IP(aaaa.AAAA[:]).String() != forumAddr {
		t.Fatalf("got %s", net.IP(aaaa.AAAA[:]))
	}
	if len(inner.writes) != 0 {
		t.Fatal("DNS query leaked to Yggdrasil")
	}
}

func TestDNSUnknownAndNoData(t *testing.T) {
	d, _ := newTestInterceptor(t)
	msg, _ := roundTrip(t, d, query(t, 1, "nope.ygg.", dnsmessage.TypeAAAA))
	if msg.RCode != dnsmessage.RCodeNameError {
		t.Fatalf("want NXDOMAIN, got %v", msg.RCode)
	}
	msg, _ = roundTrip(t, d, query(t, 2, "forum.ygg.", dnsmessage.TypeA))
	if msg.RCode != dnsmessage.RCodeSuccess || len(msg.Answers) != 0 {
		t.Fatalf("want NODATA for A, got %v / %d answers", msg.RCode, len(msg.Answers))
	}
}

func TestDNSPassthrough(t *testing.T) {
	d, inner := newTestInterceptor(t)
	other := ip16("21e:a51c:885b:7db0:166e:927:98cd:d186")
	pkt := udpPacket(testSrc, other, 5555, 53, []byte("not for us"))
	if _, err := d.Write(pkt); err != nil {
		t.Fatal(err)
	}
	if len(inner.writes) != 1 {
		t.Fatal("non-local packet was not forwarded")
	}

	// Reads from Yggdrasil still reach the TUN.
	go func() { inner.reads <- []byte{0x60, 1, 2, 3} }()
	buf := make([]byte, 64)
	if n, err := d.Read(buf); err != nil || n != 4 || buf[0] != 0x60 {
		t.Fatalf("passthrough read: n=%d err=%v", n, err)
	}
}
