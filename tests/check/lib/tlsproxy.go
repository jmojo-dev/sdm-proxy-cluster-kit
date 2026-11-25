// Test-only HTTPS frontend for the loopback vault fixture.
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"log"
	"math/big"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"time"
)

func testCertificate() (tls.Certificate, []byte, error) {
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	ca := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Local test CA"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(24 * time.Hour),
		BasicConstraintsValid: true, IsCA: true, KeyUsage: x509.KeyUsageCertSign,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	server := &x509.Certificate{
		SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "localhost"},
		NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, BasicConstraintsValid: true,
		IPAddresses: []net.IP{net.IPv4(127, 0, 0, 1)}, KeyUsage: x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, server, ca, &key.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER}), nil
}

func main() {
	cert, ca, err := testCertificate()
	if err != nil {
		log.Fatal(err)
	}
	backend := &url.URL{Scheme: "http", Host: "127.0.0.1:8080"}
	routes := http.NewServeMux()
	routes.Handle("/", httputil.NewSingleHostReverseProxy(backend))
	routes.HandleFunc("/platform/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"healthy":true}`))
	})
	routes.HandleFunc("/platform/identity/api/oauth2/token/xpmplatform", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.FormValue("grant_type") != "client_credentials" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Write([]byte(`{"access_token":"tok123"}`))
	})
	routes.HandleFunc("/platform/vaultbroker/api/vaults", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok123" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.Write([]byte(`[{"isDefault":true,"isActive":true,"connection":{"url":"https://127.0.0.1:9443/SecretServer"}}]`))
	})
	routes.HandleFunc("/redirect-test/api/v1/healthcheck", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"healthy":true}`))
	})
	routes.HandleFunc("/redirect-test/oauth2/token", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/SecretServer/oauth2/token", http.StatusTemporaryRedirect)
	})
	listener, err := tls.Listen("tcp", "127.0.0.1:9443", &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12})
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	if err := os.WriteFile("/etc/ck-test-ca.pem", ca, 0600); err != nil {
		log.Fatal(err)
	}
	server := &http.Server{Handler: routes, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(server.Serve(listener))
}
