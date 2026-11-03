package yggkit

import (
	"encoding/binary"
	"net"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
)

var (
	testResolvers = parseResolvers([]string{"308:84:68:55::", "308:62:45:62::"})
	alfisAddr     = ip16("326:c728:5cfb:c3ec:ffff::2")
)

// upstreamAnswer is what a resolver would send back for query q.
func upstreamAnswer(t *testing.T, q []byte, addr [16]byte) []byte {
	t.Helper()
	var p dnsmessage.Parser
	hdr, err := p.Start(q)
	if err != nil {
		t.Fatal(err)
	}
	question, err := p.Question()
	if err != nil {
		t.Fatal(err)
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: hdr.ID, Response: true, RecursionAvailable: true})
	_ = b.StartQuestions()
	_ = b.Question(question)
	_ = b.StartAnswers()
	_ = b.AAAAResource(dnsmessage.ResourceHeader{Name: question.Name, Class: dnsmessage.ClassINET, TTL: 60},
		dnsmessage.AAAAResource{AAAA: addr})
	out, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestForwardUnknownNameAndRelayAnswer(t *testing.T) {
	var hosts hostTable
	m, _ := parseHostsJSON(`{"forum.ygg": "` + forumAddr + `"}`)
	hosts.set(m)
	inner := &fakeRWC{reads: make(chan []byte), addr: address.Address(testSrc)}
	d := newDNSInterceptor(inner, testDNSAddr, &hosts, testResolvers)
	t.Cleanup(d.shutdown)

	// Known name: answered locally, nothing sent upstream.
	if msg, _ := roundTrip(t, d, query(t, 1, "forum.ygg.", dnsmessage.TypeAAAA)); len(msg.Answers) != 1 {
		t.Fatal("local name not answered")
	}
	if n := len(inner.written()); n != 0 {
		t.Fatalf("local name went upstream (%d packets)", n)
	}

	// Unknown name: forwarded from the node address to the first resolver.
	if _, err := d.Write(udpPacket(testSrc, testDNSAddr, 5555, 53, query(t, 0x4242, "alfis.ygg.", dnsmessage.TypeAAAA))); err != nil {
		t.Fatal(err)
	}
	sent := inner.written()
	if len(sent) != 1 {
		t.Fatalf("want 1 upstream packet, got %d", len(sent))
	}
	up := sent[0]
	if [16]byte(up[8:24]) != testSrc || [16]byte(up[24:40]) != testResolvers[0] {
		t.Fatal("forwarded packet has wrong addresses")
	}
	if binary.BigEndian.Uint16(up[40:42]) != fwdPort || binary.BigEndian.Uint16(up[42:44]) != 53 {
		t.Fatal("forwarded packet has wrong ports")
	}
	if got, want := binary.BigEndian.Uint16(up[46:48]), udp6Checksum(up); got != want {
		t.Fatal("forwarded packet has a bad checksum")
	}

	// The resolver answers; the client gets it from dnsAddr:53 with its own ID.
	reply := udp6Packet(testResolvers[0], testSrc, 53, fwdPort, upstreamAnswer(t, up[48:], alfisAddr))
	go func() { inner.reads <- reply }()
	buf := make([]byte, 2048)
	done := make(chan int, 1)
	go func() { n, _ := d.Read(buf); done <- n }()
	var n int
	select {
	case n = <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("relayed answer not delivered")
	}
	pkt := buf[:n]
	if [16]byte(pkt[8:24]) != testDNSAddr || [16]byte(pkt[24:40]) != testSrc ||
		binary.BigEndian.Uint16(pkt[40:42]) != 53 || binary.BigEndian.Uint16(pkt[42:44]) != 5555 {
		t.Fatal("relayed answer has wrong addresses or ports")
	}
	if got, want := binary.BigEndian.Uint16(pkt[46:48]), udp6Checksum(pkt); got != want {
		t.Fatal("relayed answer has a bad checksum")
	}
	var msg dnsmessage.Message
	if err := msg.Unpack(pkt[48:]); err != nil {
		t.Fatal(err)
	}
	if msg.ID != 0x4242 || len(msg.Answers) != 1 {
		t.Fatalf("bad relayed answer: id %#x, %d answers", msg.ID, len(msg.Answers))
	}
	if got := net.IP(msg.Answers[0].Body.(*dnsmessage.AAAAResource).AAAA[:]).String(); got != "326:c728:5cfb:c3ec:ffff::2" {
		t.Fatalf("relayed address %s", got)
	}
}

func TestForwarderFailoverAndServfail(t *testing.T) {
	var writes, delivered [][]byte
	now := time.Unix(1_800_000_000, 0)
	f := newForwarder(testSrc, testDNSAddr, testResolvers,
		func(b []byte) { writes = append(writes, b) },
		func(b []byte) { delivered = append(delivered, b) })
	f.now = func() time.Time { return now }

	f.forward(testSrc, 6000, query(t, 7, "alfis.ygg.", dnsmessage.TypeAAAA))
	if len(writes) != 1 || [16]byte(writes[0][24:40]) != testResolvers[0] {
		t.Fatal("first try should go to resolver 0")
	}

	now = now.Add(time.Second) // within the timeout: nothing happens
	f.tick()
	if len(writes) != 1 || len(delivered) != 0 {
		t.Fatal("retried too early")
	}

	now = now.Add(time.Second) // past the timeout: next resolver
	f.tick()
	if len(writes) != 2 || [16]byte(writes[1][24:40]) != testResolvers[1] {
		t.Fatal("should retry on resolver 1")
	}

	now = now.Add(2 * time.Second) // every resolver tried: SERVFAIL to the client
	f.tick()
	if len(delivered) != 1 {
		t.Fatalf("want SERVFAIL, got %d deliveries", len(delivered))
	}
	var msg dnsmessage.Message
	if err := msg.Unpack(delivered[0][48:]); err != nil {
		t.Fatal(err)
	}
	if msg.ID != 7 || msg.RCode != dnsmessage.RCodeServerFailure {
		t.Fatalf("want SERVFAIL id 7, got id %d rcode %v", msg.ID, msg.RCode)
	}
	if len(f.pending) != 0 {
		t.Fatal("pending query not cleared")
	}

	// A late answer is swallowed, not passed to the TUN.
	late := udp6Packet(testResolvers[1], testSrc, 53, fwdPort, upstreamAnswer(t, writes[1][48:], alfisAddr))
	if out, ok := f.handleReply(late); !ok || out != nil {
		t.Fatal("late answer should be consumed silently")
	}

	// Whoever answers becomes the preferred resolver for the next query.
	f.forward(testSrc, 6001, query(t, 8, "wiki.ygg.", dnsmessage.TypeAAAA))
	last := writes[len(writes)-1]
	answer := udp6Packet([16]byte(last[24:40]), testSrc, 53, fwdPort, upstreamAnswer(t, last[48:], alfisAddr))
	if out, ok := f.handleReply(answer); !ok || out == nil {
		t.Fatal("answer not relayed")
	}
	f.forward(testSrc, 6002, query(t, 9, "map.ygg.", dnsmessage.TypeAAAA))
	if [16]byte(writes[len(writes)-1][24:40]) != [16]byte(last[24:40]) {
		t.Fatal("did not stick with the resolver that answered")
	}

	// Ordinary Yggdrasil traffic is never mistaken for a resolver answer.
	other := udp6Packet(ip16("21e:a51c:885b:7db0:166e:927:98cd:d186"), testSrc, 53, fwdPort, []byte("xxxxxxxxxxxxxx"))
	if _, ok := f.handleReply(other); ok {
		t.Fatal("non-resolver packet treated as an answer")
	}
}
