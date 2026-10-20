// Command mqtt_testbroker is a throwaway MQTT 5 broker for Phase 0 signaling
// tests. It is test infrastructure, not an operated Vault service: it listens on
// loopback or the LAN you choose, requires TLS and a username/password, rejects
// retained messages and only allows the vault/v1/ topic tree.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"log"
	"math/big"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	mqtt "github.com/mochi-mqtt/server/v2"
	"github.com/mochi-mqtt/server/v2/listeners"
	"github.com/mochi-mqtt/server/v2/packets"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:18883", "TLS listen address")
	dir := flag.String("certdir", "certs", "directory for the generated test CA and server certificate")
	user := flag.String("user", "vault", "required username")
	pass := flag.String("pass", "vault-test-password", "required password")
	hosts := flag.String("hosts", "127.0.0.1,localhost", "comma separated SAN hosts is not parsed; localhost and 127.0.0.1 are always included")
	flag.Parse()
	_ = hosts

	tlsConfig, err := ensureCerts(*dir, *addr)
	if err != nil {
		log.Fatalf("certificates: %v", err)
	}

	caps := mqtt.NewDefaultServerCapabilities()
	caps.RetainAvailable = 0
	caps.MaximumPacketSize = 64 * 1024
	server := mqtt.New(&mqtt.Options{Capabilities: caps})
	if err := server.AddHook(&vaultHook{user: *user, pass: *pass}, nil); err != nil {
		log.Fatal(err)
	}
	if err := server.AddListener(listeners.NewTCP(listeners.Config{ID: "tls", Address: *addr, TLSConfig: tlsConfig})); err != nil {
		log.Fatal(err)
	}
	go func() {
		if err := server.Serve(); err != nil {
			log.Fatal(err)
		}
	}()
	log.Printf("mqtt_testbroker listening on %s (TLS, auth required, retain disabled); CA: %s", *addr, filepath.Join(*dir, "ca.pem"))
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	<-stop
	_ = server.Close()
}

func ensureCerts(dir, addr string) (*tls.Config, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	caPath, certPath, keyPath := filepath.Join(dir, "ca.pem"), filepath.Join(dir, "server.pem"), filepath.Join(dir, "server.key")
	if _, err := os.Stat(certPath); err == nil {
		cert, err := tls.LoadX509KeyPair(certPath, keyPath)
		if err != nil {
			return nil, err
		}
		return &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}, nil
	}
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	caTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Vault Phase0 Test CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(30 * 24 * time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	caCert, _ := x509.ParseCertificate(caDER)
	srvKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	srvTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "localhost"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(30 * 24 * time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
	}
	if host, _, err := net.SplitHostPort(addr); err == nil {
		if ip := net.ParseIP(host); ip != nil {
			srvTmpl.IPAddresses = append(srvTmpl.IPAddresses, ip)
		}
	}
	srvDER, err := x509.CreateCertificate(rand.Reader, srvTmpl, caCert, &srvKey.PublicKey, caKey)
	if err != nil {
		return nil, err
	}
	keyDER, err := x509.MarshalECPrivateKey(srvKey)
	if err != nil {
		return nil, err
	}
	write := func(path, kind string, der []byte, mode os.FileMode) error {
		return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: kind, Bytes: der}), mode)
	}
	if err := write(caPath, "CERTIFICATE", caDER, 0o644); err != nil {
		return nil, err
	}
	if err := write(certPath, "CERTIFICATE", srvDER, 0o644); err != nil {
		return nil, err
	}
	if err := write(keyPath, "EC PRIVATE KEY", keyDER, 0o600); err != nil {
		return nil, err
	}
	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		return nil, err
	}
	return &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}, nil
}

// vaultHook enforces the single test credential and the vault/v1/ topic tree.
type vaultHook struct {
	mqtt.HookBase
	user, pass string
}

func (h *vaultHook) ID() string { return "vault-auth" }

func (h *vaultHook) Provides(b byte) bool {
	return bytes.Contains([]byte{mqtt.OnConnectAuthenticate, mqtt.OnACLCheck}, []byte{b})
}

func (h *vaultHook) OnConnectAuthenticate(cl *mqtt.Client, pk packets.Packet) bool {
	userOK := subtle.ConstantTimeCompare(pk.Connect.Username, []byte(h.user)) == 1
	passOK := subtle.ConstantTimeCompare(pk.Connect.Password, []byte(h.pass)) == 1
	return userOK && passOK
}

// OnACLCheck allows only topics and filters strictly inside vault/v1/.
func (h *vaultHook) OnACLCheck(cl *mqtt.Client, topic string, write bool) bool {
	return strings.HasPrefix(topic, "vault/v1/")
}
