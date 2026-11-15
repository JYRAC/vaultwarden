// nbtcp: NetBird（netstack）の SOCKS5 を通して、NetBird 上の TCP の宛先へ、バイトをそのまま流す小さな中継。
//
//	Vikunja（市販の実行ファイル）は、OIDC の発見文書に書かれた公開の URL（https://auth.jyrac.stki.org/...）へ、
//	サーバー側から通信する。この URL は変えられないので、/etc/hosts で、この名前を 127.0.0.1 に向け、
//	ここで受けて、Casdoor の内部口 A（NetBird の IP:8443）に流す。
//
//	TLS は、ここでは終わらせない（バイトをそのまま流す）。Vikunja が、Casdoor と直接 TLS 1.3 で話し、
//	名前 auth.jyrac.stki.org と、信頼する CA（SSL_CERT_FILE）で、証明書を検証する。検証は、切らない。
//
//	環境変数:
//	  CASDOOR_NB_ADDR   宛先。NetBird の IP:ポート（IPv4 のみ。名前は引けない）。例 100.125.23.8:8443
//	  NBTCP_LISTEN      待ち受け。既定 127.0.0.1:443
//	  NB_SOCKS5_ADDR    NetBird の SOCKS5。既定 127.0.0.1:1080
//	  NBTCP_TLS_CA      --check で使う CA。既定 /etc/openbao/ca.crt
//	  NBTCP_TLS_NAME    --check で照合する名前。既定 auth.jyrac.stki.org
//	  NB_CHECK_SEC      --check の待ち時間（秒）。既定 40
//
//	--check  宛先に、TLS 1.3 でつながり、証明書を CA と名前で検証できるまで待つ。できれば 0、できなければ 1。
//	--wait-listen  NBTCP_LISTEN が待ち受け中になるまで待つ（最大 5 秒）。待ち受け中なら 0、そうでなければ 1。
//	（引数なし）  待ち受けを始める。
package main

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

const tag = "NB-TCP(casdoor)"

func getenv(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

var (
	target    = os.Getenv("CASDOOR_NB_ADDR")
	listen    = getenv("NBTCP_LISTEN", "127.0.0.1:443")
	socksAddr = getenv("NB_SOCKS5_ADDR", "127.0.0.1:1080")
	tlsCA     = getenv("NBTCP_TLS_CA", "/etc/openbao/ca.crt")
	tlsName   = getenv("NBTCP_TLS_NAME", "auth.jyrac.stki.org")
)

// target を IPv4 とポートに分ける（名前は引けないので、IPv4 のみ）。
func parseTarget() (ip net.IP, port int, err error) {
	h, p, err := net.SplitHostPort(target)
	if err != nil {
		return nil, 0, fmt.Errorf("CASDOOR_NB_ADDR は IPv4:ポート の形で指定してください（例 100.125.23.8:8443）")
	}
	ip = net.ParseIP(h).To4()
	port, perr := strconv.Atoi(p)
	if ip == nil || perr != nil || port < 1 || port > 65535 {
		return nil, 0, fmt.Errorf("CASDOOR_NB_ADDR の値が不正です: %q", target)
	}
	return ip, port, nil
}

// SOCKS5（認証なし）で CONNECT して、つながった接続を返す。
func dialVia(ip net.IP, port int) (net.Conn, error) {
	c, err := net.DialTimeout("tcp", socksAddr, 15*time.Second)
	if err != nil {
		return nil, err
	}
	fail := func(e error) (net.Conn, error) { c.Close(); return nil, e }
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err := c.Write([]byte{5, 1, 0}); err != nil {
		return fail(err)
	}
	rep := make([]byte, 2)
	if _, err := io.ReadFull(c, rep); err != nil {
		return fail(err)
	}
	if rep[0] != 5 || rep[1] != 0 {
		return fail(errors.New("socks5 handshake"))
	}
	req := []byte{5, 1, 0, 1, ip[0], ip[1], ip[2], ip[3], byte(port >> 8), byte(port)}
	if _, err := c.Write(req); err != nil {
		return fail(err)
	}
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(c, hdr); err != nil {
		return fail(err)
	}
	if hdr[1] != 0 {
		return fail(fmt.Errorf("socks5 connect rep=%d", hdr[1]))
	}
	var rest int
	switch hdr[3] {
	case 1:
		rest = 4 + 2
	case 4:
		rest = 16 + 2
	case 3:
		l := make([]byte, 1)
		if _, err := io.ReadFull(c, l); err != nil {
			return fail(err)
		}
		rest = int(l[0]) + 2
	default:
		return fail(fmt.Errorf("socks5 atyp=%d", hdr[3]))
	}
	if _, err := io.ReadFull(c, make([]byte, rest)); err != nil {
		return fail(err)
	}
	_ = c.SetDeadline(time.Time{})
	return c, nil
}

func check(ip net.IP, port int) int {
	pem, err := os.ReadFile(tlsCA)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: 証明書を読めません (%s): %v\n", tag, tlsCA, err)
		return 2
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		fmt.Fprintf(os.Stderr, "%s: 証明書を解釈できません (%s)\n", tag, tlsCA)
		return 2
	}
	secs, _ := strconv.Atoi(getenv("NB_CHECK_SEC", "40"))
	end := time.Now().Add(time.Duration(secs) * time.Second)
	last := ""
	for time.Now().Before(end) {
		c, err := dialVia(ip, port)
		if err == nil {
			t := tls.Client(c, &tls.Config{ServerName: tlsName, RootCAs: pool, MinVersion: tls.VersionTLS13})
			_ = t.SetDeadline(time.Now().Add(15 * time.Second))
			err = t.Handshake()
			c.Close()
			if err == nil {
				fmt.Printf("%s: %s に届きました（TLS 1.3、証明書の検証 OK、名前 %s）\n", tag, target, tlsName)
				return 0
			}
		}
		last = err.Error()
		time.Sleep(2 * time.Second)
	}
	fmt.Fprintf(os.Stderr, "%s: %s に届きません (%s)\n", tag, target, last)
	return 1
}

func pipe(a, b net.Conn) {
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		if tc, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = tc.CloseWrite()
		}
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	<-done
	a.Close()
	b.Close()
}

func serve(ip net.IP, port int) int {
	if !strings.HasPrefix(listen, "127.") {
		fmt.Fprintf(os.Stderr, "%s: NBTCP_LISTEN は 127.0.0.1 のみ許可します (%s)\n", tag, listen)
		return 2
	}
	ln, err := net.Listen("tcp", listen)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: 待ち受けに失敗しました: %v\n", tag, err)
		return 1
	}
	fmt.Printf("%s: %s -> %s (SOCKS5 %s、TLS は終わらせず、そのまま流す)\n", tag, listen, target, socksAddr)
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func() {
			up, err := dialVia(ip, port)
			if err != nil {
				c.Close()
				return
			}
			pipe(c, up)
		}()
	}
}

func waitListen() int {
	for i := 0; i < 20; i++ {
		c, err := net.DialTimeout("tcp", listen, 500*time.Millisecond)
		if err == nil {
			c.Close()
			return 0
		}
		time.Sleep(250 * time.Millisecond)
	}
	return 1
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--wait-listen" {
		os.Exit(waitListen())
	}
	ip, port, err := parseTarget()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", tag, err)
		os.Exit(2)
	}
	if len(os.Args) > 1 && os.Args[1] == "--check" {
		os.Exit(check(ip, port))
	}
	os.Exit(serve(ip, port))
}
