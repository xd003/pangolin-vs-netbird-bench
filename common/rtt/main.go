// rtt: minimal latency/jitter probe for tunnel benchmarking.
//
//	rtt server  [-udp :7000] [-tcp :7001]
//	rtt udp     -target host:7000 [-rate 100] [-duration 30s] [-size 64]
//	rtt tcp     -target host:7001 [-rate 100] [-duration 30s] [-size 64]
//	rtt connect -target host:port [-count 200] [-rate 20]
//
// Client modes print one JSON object with RTT stats in milliseconds.
// Jitter is the mean absolute difference between consecutive RTTs (RFC 3550 style).
package main

import (
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"sort"
	"sync"
	"time"
)

type result struct {
	Mode     string  `json:"mode"`
	Target   string  `json:"target"`
	Sent     int     `json:"sent"`
	Received int     `json:"received"`
	LossPct  float64 `json:"loss_pct"`
	Min      float64 `json:"min_ms"`
	Avg      float64 `json:"avg_ms"`
	P50      float64 `json:"p50_ms"`
	P90      float64 `json:"p90_ms"`
	P99      float64 `json:"p99_ms"`
	Max      float64 `json:"max_ms"`
	Stddev   float64 `json:"stddev_ms"`
	Jitter   float64 `json:"jitter_ms"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: rtt server|udp|tcp|connect [flags]")
		os.Exit(2)
	}
	mode := os.Args[1]
	fs := flag.NewFlagSet(mode, flag.ExitOnError)
	udpAddr := fs.String("udp", ":7000", "server udp listen")
	tcpAddr := fs.String("tcp", ":7001", "server tcp listen")
	target := fs.String("target", "", "host:port")
	rate := fs.Int("rate", 100, "probes per second")
	dur := fs.Duration("duration", 30*time.Second, "test duration")
	size := fs.Int("size", 64, "payload bytes (>=16)")
	count := fs.Int("count", 200, "connect attempts")
	_ = fs.Parse(os.Args[2:])
	if *size < 16 {
		*size = 16
	}

	var rtts []float64
	var sent int
	switch mode {
	case "server":
		serve(*udpAddr, *tcpAddr)
		return
	case "udp":
		sent, rtts = runUDP(*target, *rate, *dur, *size)
	case "tcp":
		sent, rtts = runTCP(*target, *rate, *dur, *size)
	case "connect":
		sent, rtts = runConnect(*target, *rate, *count)
	default:
		fmt.Fprintln(os.Stderr, "unknown mode", mode)
		os.Exit(2)
	}
	out := summarize(mode, *target, sent, rtts)
	_ = json.NewEncoder(os.Stdout).Encode(out)
}

func serve(udpAddr, tcpAddr string) {
	go func() {
		pc, err := net.ListenPacket("udp", udpAddr)
		if err != nil {
			panic(err)
		}
		buf := make([]byte, 65535)
		for {
			n, addr, err := pc.ReadFrom(buf)
			if err != nil {
				continue
			}
			_, _ = pc.WriteTo(buf[:n], addr)
		}
	}()
	ln, err := net.Listen("tcp", tcpAddr)
	if err != nil {
		panic(err)
	}
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			if tc, ok := c.(*net.TCPConn); ok {
				_ = tc.SetNoDelay(true)
			}
			_, _ = io.Copy(c, c)
		}(c)
	}
}

// runUDP sends sequence-numbered probes at a fixed rate; replies are matched by
// sequence so reordering or loss does not skew RTTs.
func runUDP(target string, rate int, dur time.Duration, size int) (int, []float64) {
	conn, err := net.Dial("udp", target)
	if err != nil {
		panic(err)
	}
	defer conn.Close()
	total := int(dur.Seconds() * float64(rate))
	sendTimes := make([]int64, total)
	rtt := make([]float64, total)
	for i := range rtt {
		rtt[i] = -1
	}
	var mu sync.Mutex
	done := make(chan struct{})
	go func() {
		buf := make([]byte, 65535)
		for {
			n, err := conn.Read(buf)
			if err != nil {
				select {
				case <-done:
					return
				default:
					continue
				}
			}
			now := time.Now().UnixNano()
			if n < 16 {
				continue
			}
			seq := int(binary.BigEndian.Uint64(buf[0:8]))
			mu.Lock()
			if seq < total && rtt[seq] < 0 {
				rtt[seq] = float64(now-sendTimes[seq]) / 1e6
			}
			mu.Unlock()
		}
	}()
	payload := make([]byte, size)
	tick := time.NewTicker(time.Second / time.Duration(rate))
	defer tick.Stop()
	for i := range total {
		<-tick.C
		binary.BigEndian.PutUint64(payload[0:8], uint64(i))
		mu.Lock()
		sendTimes[i] = time.Now().UnixNano()
		mu.Unlock()
		_, _ = conn.Write(payload)
	}
	time.Sleep(2 * time.Second) // grace period for late replies
	close(done)
	_ = conn.SetReadDeadline(time.Now())
	mu.Lock()
	defer mu.Unlock()
	var got []float64
	for _, v := range rtt {
		if v >= 0 {
			got = append(got, v)
		}
	}
	return total, got
}

// runTCP does request/response ping-pong on one persistent TCP_NODELAY connection.
func runTCP(target string, rate int, dur time.Duration, size int) (int, []float64) {
	c, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		panic(err)
	}
	defer c.Close()
	_ = c.(*net.TCPConn).SetNoDelay(true)
	total := int(dur.Seconds() * float64(rate))
	payload := make([]byte, size)
	buf := make([]byte, size)
	var rtts []float64
	tick := time.NewTicker(time.Second / time.Duration(rate))
	defer tick.Stop()
	for range total {
		<-tick.C
		start := time.Now()
		if _, err := c.Write(payload); err != nil {
			break
		}
		_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
		if _, err := io.ReadFull(c, buf); err != nil {
			break
		}
		rtts = append(rtts, float64(time.Since(start).Nanoseconds())/1e6)
	}
	return total, rtts
}

// runConnect measures TCP three-way handshake time to target.
func runConnect(target string, rate, count int) (int, []float64) {
	var rtts []float64
	tick := time.NewTicker(time.Second / time.Duration(rate))
	defer tick.Stop()
	for range count {
		<-tick.C
		start := time.Now()
		c, err := net.DialTimeout("tcp", target, 5*time.Second)
		if err != nil {
			continue
		}
		rtts = append(rtts, float64(time.Since(start).Nanoseconds())/1e6)
		_ = c.Close()
	}
	return count, rtts
}

func summarize(mode, target string, sent int, rtts []float64) result {
	r := result{Mode: mode, Target: target, Sent: sent, Received: len(rtts)}
	if sent > 0 {
		r.LossPct = 100 * float64(sent-len(rtts)) / float64(sent)
	}
	if len(rtts) == 0 {
		return r
	}
	var sum, jit float64
	for i, v := range rtts {
		sum += v
		if i > 0 {
			jit += math.Abs(v - rtts[i-1])
		}
	}
	r.Avg = sum / float64(len(rtts))
	if len(rtts) > 1 {
		r.Jitter = jit / float64(len(rtts)-1)
	}
	var sq float64
	for _, v := range rtts {
		sq += (v - r.Avg) * (v - r.Avg)
	}
	r.Stddev = math.Sqrt(sq / float64(len(rtts)))
	s := append([]float64(nil), rtts...)
	sort.Float64s(s)
	pct := func(p float64) float64 { return s[int(math.Min(float64(len(s)-1), p*float64(len(s))))] }
	r.Min, r.Max = s[0], s[len(s)-1]
	r.P50, r.P90, r.P99 = pct(0.50), pct(0.90), pct(0.99)
	return r
}
