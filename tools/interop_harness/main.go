// Local-only synthetic WebRTC interop probe. No real media or public signaling.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"hash"
	"log"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

type control struct {
	Type     string `json:"type"`
	ID       string `json:"id"`
	Bytes    int64  `json:"bytes,omitempty"`
	SHA256   string `json:"sha256,omitempty"`
	Verified bool   `json:"verified,omitempty"`
}

type peer struct {
	mu                      sync.Mutex
	pc                      *webrtc.PeerConnection
	critical, bulk          *webrtc.DataChannel
	acks                    map[string]chan control
	received, expected      int64
	receiveID, expectedHash string
	digest                  hash.Hash
	sending                 bool
}

func (p *peer) close() {
	p.mu.Lock()
	pc := p.pc
	p.pc, p.critical, p.bulk = nil, nil, nil
	p.mu.Unlock()
	if pc != nil {
		_ = pc.Close()
	}
}

func (p *peer) create() error {
	p.close()
	pc, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		return err
	}
	p.mu.Lock()
	p.pc, p.acks = pc, make(map[string]chan control)
	p.mu.Unlock()
	pc.OnDataChannel(p.attach)
	return nil
}

func (p *peer) attach(dc *webrtc.DataChannel) {
	p.mu.Lock()
	if dc.Label() == "critical" {
		p.critical = dc
	}
	if dc.Label() == "bulk" {
		p.bulk = dc
	}
	p.mu.Unlock()
	dc.OnMessage(func(message webrtc.DataChannelMessage) {
		if dc.Label() == "critical" {
			var m control
			if json.Unmarshal(message.Data, &m) == nil {
				p.onControl(m)
			}
		} else if dc.Label() == "bulk" {
			p.mu.Lock()
			if p.digest != nil && p.received+int64(len(message.Data)) <= p.expected {
				_, _ = p.digest.Write(message.Data)
				p.received += int64(len(message.Data))
				p.finishReceiveLocked()
			}
			p.mu.Unlock()
		}
	})
}

func (p *peer) sendControl(m control) error {
	body, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if p.critical == nil {
		return errors.New("no critical channel")
	}
	return p.critical.SendText(string(body))
}

func (p *peer) onControl(m control) {
	p.mu.Lock()
	defer p.mu.Unlock()
	switch m.Type {
	case "begin":
		if m.Bytes < 1 || m.Bytes > 256*1024*1024 {
			return
		}
		p.receiveID, p.expected, p.received = m.ID, m.Bytes, 0
		p.expectedHash, p.digest = "", sha256.New()
		_ = p.sendControl(control{Type: "ready", ID: m.ID})
	case "end":
		if m.ID != p.receiveID {
			return
		}
		p.expectedHash = m.SHA256
		p.finishReceiveLocked()
	default:
		key := m.Type + ":" + m.ID
		if pending := p.acks[key]; pending != nil {
			select {
			case pending <- m:
			default:
			}
			delete(p.acks, key)
		}
	}
}

func (p *peer) finishReceiveLocked() {
	if p.digest == nil || p.received != p.expected || p.expectedHash == "" {
		return
	}
	actual := hex.EncodeToString(p.digest.Sum(nil))
	_ = p.sendControl(control{Type: "complete", ID: p.receiveID, Bytes: p.received,
		SHA256: actual, Verified: actual == p.expectedHash})
	p.digest = nil
}

func (p *peer) ack(kind, id string) <-chan control {
	p.mu.Lock()
	defer p.mu.Unlock()
	c := make(chan control, 1)
	p.acks[kind+":"+id] = c
	return c
}

func await(c <-chan control) (control, error) {
	select {
	case message := <-c:
		return message, nil
	case <-time.After(120 * time.Second):
		return control{}, errors.New("acknowledgment timed out")
	}
}

func (p *peer) gather() (webrtc.SessionDescription, error) {
	select {
	case <-webrtc.GatheringCompletePromise(p.pc):
		return *p.pc.LocalDescription(), nil
	case <-time.After(20 * time.Second):
		return webrtc.SessionDescription{}, errors.New("gathering timeout")
	}
}

func (p *peer) offer() (webrtc.SessionDescription, error) {
	if err := p.create(); err != nil {
		return webrtc.SessionDescription{}, err
	}
	for _, label := range []string{"critical", "bulk", "ephemeral"} {
		init := &webrtc.DataChannelInit{}
		if label == "ephemeral" {
			ordered := false
			retries := uint16(0)
			init.Ordered = &ordered
			init.MaxRetransmits = &retries
		}
		dc, err := p.pc.CreateDataChannel(label, init)
		if err != nil {
			return webrtc.SessionDescription{}, err
		}
		p.attach(dc)
	}
	description, err := p.pc.CreateOffer(nil)
	if err == nil {
		err = p.pc.SetLocalDescription(description)
	}
	if err != nil {
		return webrtc.SessionDescription{}, err
	}
	return p.gather()
}

func (p *peer) answer(offer webrtc.SessionDescription) (webrtc.SessionDescription, error) {
	if err := p.create(); err != nil {
		return webrtc.SessionDescription{}, err
	}
	if err := p.pc.SetRemoteDescription(offer); err != nil {
		return webrtc.SessionDescription{}, err
	}
	answer, err := p.pc.CreateAnswer(nil)
	if err == nil {
		err = p.pc.SetLocalDescription(answer)
	}
	if err != nil {
		return webrtc.SessionDescription{}, err
	}
	return p.gather()
}

func (p *peer) transfer(size int64) (map[string]any, error) {
	if size < 1 || size > 256*1024*1024 {
		return nil, errors.New("test size must be 1..256MiB")
	}
	p.mu.Lock()
	if p.sending {
		p.mu.Unlock()
		return nil, errors.New("one send at a time")
	}
	p.sending = true
	p.mu.Unlock()
	defer func() { p.mu.Lock(); p.sending = false; p.mu.Unlock() }()
	deadline := time.Now().Add(30 * time.Second)
	for {
		p.mu.Lock()
		ready := p.critical != nil && p.bulk != nil && p.critical.ReadyState() == webrtc.DataChannelStateOpen && p.bulk.ReadyState() == webrtc.DataChannelStateOpen
		p.mu.Unlock()
		if ready {
			break
		}
		if time.Now().After(deadline) {
			return nil, errors.New("channels did not open")
		}
		time.Sleep(20 * time.Millisecond)
	}
	id := strconv.FormatInt(time.Now().UnixNano(), 10)
	ready := p.ack("ready", id)
	if err := p.sendControl(control{Type: "begin", ID: id, Bytes: size}); err != nil {
		return nil, err
	}
	if _, err := await(ready); err != nil {
		return nil, err
	}
	done := p.ack("complete", id)
	digest := sha256.New()
	pattern := make([]byte, 16*1024)
	for i := range pattern {
		pattern[i] = byte(i % 251)
	}
	start := time.Now()
	var sent int64
	var high uint64
	for sent < size {
		for p.bulk.BufferedAmount()+uint64(len(pattern)) > 512*1024 {
			if time.Since(start) > 120*time.Second {
				return nil, errors.New("bulk stalled")
			}
			time.Sleep(50 * time.Millisecond)
		}
		if amount := p.bulk.BufferedAmount(); amount > high {
			high = amount
		}
		count := int64(len(pattern))
		if size-sent < count {
			count = size - sent
		}
		chunk := pattern[:count]
		_, _ = digest.Write(chunk)
		if err := p.bulk.Send(chunk); err != nil {
			return nil, err
		}
		sent += count
	}
	if err := p.sendControl(control{Type: "end", ID: id, SHA256: hex.EncodeToString(digest.Sum(nil))}); err != nil {
		return nil, err
	}
	result, err := await(done)
	if err != nil {
		return nil, err
	}
	if !result.Verified || result.Bytes != size {
		return nil, errors.New("integrity check failed")
	}
	elapsed := time.Since(start)
	pair, err := p.pc.SCTP().Transport().ICETransport().GetSelectedCandidatePair()
	if err != nil {
		return nil, err
	}
	path := map[string]any{"verified": false}
	if pair != nil {
		if pair.Local.Typ == webrtc.ICECandidateTypeRelay || pair.Remote.Typ == webrtc.ICECandidateTypeRelay {
			return nil, errors.New("relay rejected")
		}
		path = map[string]any{"verified": true, "localType": pair.Local.Typ.String(), "remoteType": pair.Remote.Typ.String()}
	}
	return map[string]any{"passed": true, "bytes": size, "sha256": result.SHA256,
		"milliseconds": elapsed.Milliseconds(), "mibPerSecond": float64(size) / 1048576 / elapsed.Seconds(),
		"highestNativeBufferedBytes": high, "maxMessageBytes": 16384, "path": path}, nil
}

func main() {
	listen := flag.String("listen", "127.0.0.1:48933", "loopback-only control listener")
	flag.Parse()
	host, _, err := net.SplitHostPort(*listen)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		log.Fatal("control listener must be loopback")
	}
	p := &peer{}
	defer p.close()
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("x-vault-probe") != "phase0-local" {
			http.Error(w, "local test header required", 403)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 128*1024)
		var result any
		var err error
		switch r.URL.Path {
		case "/status":
			p.mu.Lock()
			state := "absent"
			if p.pc != nil {
				state = p.pc.ConnectionState().String()
			}
			p.mu.Unlock()
			result = map[string]any{"platform": "pion-go", "connection": state}
		case "/rtc/offer":
			result, err = p.offer()
		case "/rtc/answer":
			var description webrtc.SessionDescription
			err = json.NewDecoder(r.Body).Decode(&description)
			if err == nil {
				result, err = p.answer(description)
			}
		case "/rtc/accept":
			var description webrtc.SessionDescription
			err = json.NewDecoder(r.Body).Decode(&description)
			if err == nil {
				err = p.pc.SetRemoteDescription(description)
			}
			result = map[string]bool{"accepted": err == nil}
		case "/rtc/transfer":
			var body struct {
				Bytes int64 `json:"bytes"`
			}
			err = json.NewDecoder(r.Body).Decode(&body)
			if err == nil {
				result, err = p.transfer(body.Bytes)
			}
		case "/rtc/reset":
			p.close()
			result = map[string]bool{"closed": true}
		default:
			http.Error(w, "unknown endpoint", 404)
			return
		}
		if err != nil {
			w.WriteHeader(500)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(result)
	})
	server := &http.Server{Addr: *listen, Handler: handler, ReadHeaderTimeout: 5 * time.Second}
	fmt.Println("Vault synthetic Pion interop probe ready on loopback")
	log.Fatal(server.ListenAndServe())
}
