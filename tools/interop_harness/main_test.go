package main

import (
	"github.com/pion/webrtc/v4"
	"testing"
)

func connectedPeers(t *testing.T) (*peer, *peer) {
	t.Helper()
	a, b := &peer{}, &peer{}
	t.Cleanup(func() { a.close(); b.close() })
	offer, err := a.offer()
	if err != nil {
		t.Fatal(err)
	}
	answer, err := b.answer(offer)
	if err != nil {
		t.Fatal(err)
	}
	if err = a.pc.SetRemoteDescription(answer); err != nil {
		t.Fatal(err)
	}
	return a, b
}

func TestRealDataChannelRoundTrip(t *testing.T) {
	a, b := connectedPeers(t)
	forward, err := a.transfer(1024 * 1024)
	if err != nil {
		t.Fatal(err)
	}
	reverse, err := b.transfer(1024 * 1024)
	if err != nil {
		t.Fatal(err)
	}
	if forward["sha256"] != reverse["sha256"] {
		t.Fatal("opposite directions hashed differently")
	}
	if forward["path"].(map[string]any)["verified"] != true {
		t.Fatal("selected pair was not verified")
	}
	pc := a.pc
	a.close()
	if pc.ConnectionState() != webrtc.PeerConnectionStateClosed {
		t.Fatal("native peer did not close")
	}
}

func TestTransferAllocationBound(t *testing.T) {
	p := &peer{}
	for _, size := range []int64{0, -1, 256*1024*1024 + 1} {
		if _, err := p.transfer(size); err == nil {
			t.Fatalf("accepted invalid size %d", size)
		}
	}
}

func TestCorruptDigestIsRejected(t *testing.T) {
	a, _ := connectedPeers(t)
	// Establish ready channels using the normal transfer path before injecting a
	// malformed end digest through the actual native DataChannel association.
	if _, err := a.transfer(1024); err != nil {
		t.Fatal(err)
	}
	id := "corrupt-digest-fixture"
	ready := a.ack("ready", id)
	if err := a.sendControl(control{Type: "begin", ID: id, Bytes: 3}); err != nil {
		t.Fatal(err)
	}
	if _, err := await(ready); err != nil {
		t.Fatal(err)
	}
	done := a.ack("complete", id)
	if err := a.bulk.Send([]byte{1, 2, 3}); err != nil {
		t.Fatal(err)
	}
	if err := a.sendControl(control{Type: "end", ID: id, SHA256: "wrong"}); err != nil {
		t.Fatal(err)
	}
	result, err := await(done)
	if err != nil {
		t.Fatal(err)
	}
	if result.Verified {
		t.Fatal("corrupt digest was accepted")
	}
}
