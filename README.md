# pangolin-vs-netbird-bench

Reproducible benchmark of two self-hosted WireGuard remote-access stacks:

- **Pangolin** 1.25.3 (gerbil 1.5.2, traefik v3.7, newt 1.19.1 site connector, olm 1.10.1 client)
- **NetBird** 0.82.0 (combined server, reverse-proxy, netbird client as routing peer and as client)

Both stacks are brought up fully automatically through each product's API (no UI). Each run measures two paths:

1. **Private access:** VPN client → tunnel → site connector → target on an isolated site LAN.
2. **Public reverse proxy:** HTTPS `app.bench.test` → product proxy → tunnel → site → target.

Results from the reference machine are [below](#results-on-the-reference-machine) and in [`results/REPORT.md`](results/REPORT.md). Raw data: `results/*.json`. Stack details (data path evidence, kernel vs userspace WireGuard, non-default settings): `pangolin/NOTES.md`, `netbird/NOTES.md`.

## Topology

```
              wan 10.88.0.0/24                         sitelan 10.89.0.0/24 (internal)
client-tools ─┬─ client ── tunnel ── site ─────────────── target 10.89.0.10
              │                       │                   (iperf3, nginx, UDP/TCP echo)
loadgen ──────┴── server-side (pangolin+gerbil+traefik | nb-server+nb-proxy)
```

The target only accepts traffic from the site. `internal: true` alone does not isolate networks on OrbStack, so each stack's up.sh adds `DOCKER-USER` DROP rules and the runner adds a firewall on the target.

## Configurations

| config | private path | WireGuard |
|---|---|---|
| pangolin-default | olm ↔ newt direct P2P | userspace (olm, newt), kernel on gerbil |
| pangolin-relay | olm → gerbil relay → newt (emulated: Pangolin has no force-relay switch; the direct route is blackholed) | as above |
| netbird-default | direct P2P | kernel |
| netbird-relay | via relay (`NB_FORCE_RELAY`, WebSocket transport) | kernel |
| netbird-userspace | direct P2P | userspace (`NB_WG_KERNEL_DISABLED`) |

Profiles: `lan` (no added delay) and `wan` (netem 15 ms egress on client and site, ~34 ms RTT).

## Metrics

- TCP throughput up/down with 1 and 4 streams (iperf3, median of 3), single-stream HTTP download of 100 MB
- UDP at 100M/500M/1G: achieved rate, loss, jitter
- Latency: ICMP, UDP and TCP request/response (p50/p99, RFC 3550-style jitter), TCP connect time, UDP RTT under a concurrent 4-stream download
- HTTP 1 KiB req/s and latency at 1 and 64 concurrent connections (oha)
- Public HTTPS: req/s, latency, 100 MB download (1 and 4 parallel)
- Resources: per-container cgroup CPU and memory (idle and under load), plus VM-wide CPU per GB transferred (includes kernel WireGuard work that no container is charged for)
- Ops: bring-up time, client restart → reachable time, image sizes

## Results on the reference machine

| | |
|---|---|
| Host | Apple M4 (10 cores), 24 GB RAM, macOS 27.2 |
| Docker | OrbStack 2.2.5, Docker Engine 29.8.2 |
| Linux VM | kernel 7.2.12-orbstack (WireGuard module built in), 10 vCPU, 12 GB |
| Runs | 2026-10-30 / 2026-10-31, `REPS=3`, `TP_SECS=10` |

### Summary

- **Private-path throughput:** NetBird direct (kernel WireGuard) is about 3–4× faster than Pangolin direct on `lan` (3.4–3.9 vs 0.8–1.3 Gbit/s TCP) and about 5–10× faster on `wan` (~250 vs 26–58 Mbit/s).
- **UDP:** Pangolin tops out around 300 Mbit/s and loses 39–73 % of packets at 500 Mbit/s and 1 Gbit/s. NetBird direct carries 1 Gbit/s on `lan` with no loss.
- **Latency on an idle tunnel:** NetBird adds about half as much delay as Pangolin (ping 0.52 vs 1.09 ms on `lan`). On `wan` every config lands within about 1–5 ms of the no-tunnel round trip.
- **Latency while the tunnel is busy (Pangolin's one win):** with a 4-stream download running, NetBird direct's latency rises to about 26 ms (11.5 ms in userspace mode); Pangolin stays at about 0.9 ms. This only shows on `lan`, and part of it is likely because Pangolin moves far less data, so its queues fill less.
- **NetBird userspace WireGuard** was faster than kernel mode here (up to 8.7 Gbit/s on `lan`, 2.9 Gbit/s on `wan`), but its client and site each peaked at about 1.2–1.8 GB of memory under load (about 30 MB in kernel mode).
- **Public HTTPS reverse proxy:** NetBird handled about 11× more requests per second on `lan` (33k vs 3k at 64 connections). Pangolin's p99 latency was 174 ms; NetBird's was 6.5 ms. On `wan` both are limited by the network delay.
- **Resources:** at idle, NetBird uses about 150–180 MB and 2–6 millicores; Pangolin about 600 MB (its server alone is ~300 MB) and ~20 millicores. VM-wide CPU per GB moved on `lan`: about 8 CPU-seconds for NetBird kernel mode, about 18 for Pangolin.
- **Ops:** bring-up takes 24–42 s for both; client restart → reachable is ~5.5 s for both (6.5 s for Pangolin relayed), which likely reflects container start-up more than the products. Total image size: Pangolin 916 MB, NetBird 607 MB.
- **Failed measurement:** in `netbird-relay` / `wan`, the TCP round-trip test timed out once, so those cells show `–`.

### Profile `lan` (no added delay)

#### Private path throughput (Mbit/s, median of reps)

| config | TCP up 1 | TCP down 1 | TCP up 4 | TCP down 4 | HTTP 100MB | retrans (down 1) |
|---|---|---|---|---|---|---|
| baseline-default | 111906 | 110808 | 367985 | 311735 | 100079 | 1282 |
| pangolin-default | 1292 | 904 | 1074 | 796 | 881 | 385 |
| pangolin-relay | 89 | 524 | 174 | 500 | 519 | 428 |
| netbird-default | 3368 | 3792 | 3375 | 3912 | 3770 | 1 |
| netbird-relay | 955 | 885 | 831 | 802 | 804 | 1328 |
| netbird-userspace | 6088 | 5755 | 8664 | 8417 | 4777 | 45 |

#### Private path UDP (achieved Mbit/s / loss % / jitter ms)

| config | up 100M | up 500M | up 1G | down 1G |
|---|---|---|---|---|
| baseline-default | 100 / 0.00 / 0.004 | 500 / 0.00 / 0.005 | 1000 / 0.00 / 0.001 | 1000 / 0.00 / 0.001 |
| pangolin-default | 100 / 0.00 / 0.088 | 298 / 39.25 / 0.003 | 272 / 72.86 / 0.060 | 645 / 35.50 / 0.019 |
| pangolin-relay | 100 / 0.00 / 0.106 | 340 / 32.16 / 0.262 | 349 / 64.54 / 0.107 | 669 / 33.06 / 0.022 |
| netbird-default | 100 / 0.00 / 0.020 | 500 / 0.00 / 0.012 | 1000 / 0.00 / 0.011 | 1000 / 0.00 / 0.010 |
| netbird-relay | 100 / 0.00 / 0.040 | 450 / 9.98 / 0.014 | 849 / 15.06 / 0.013 | 859 / 14.10 / 0.019 |
| netbird-userspace | 100 / 0.00 / 0.035 | 500 / 0.00 / 0.022 | 1000 / 0.00 / 0.002 | 1000 / 0.00 / 0.005 |

#### Private path latency (ms)

| config | ICMP avg | ICMP mdev | UDP p50 | UDP p99 | UDP jitter | TCP p50 | TCP p99 | connect p50 | loaded p50 | loaded p99 | loaded jitter | loaded loss % |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline-default | 0.090 | 0.036 | 0.097 | 0.290 | 0.062 | 0.095 | 0.287 | 0.432 | 0.086 | 2.588 | 0.266 | 0.0 |
| pangolin-default | 1.094 | 0.312 | 0.736 | 1.438 | 0.226 | 0.729 | 1.488 | 1.242 | 0.886 | 4.920 | 1.043 | 1.3 |
| pangolin-relay | 1.992 | 0.336 | 1.514 | 2.248 | 0.283 | 1.617 | 2.952 | 1.954 | 2.405 | 6.617 | 1.000 | 1.0 |
| netbird-default | 0.521 | 0.120 | 0.456 | 0.872 | 0.153 | 0.580 | 0.859 | 0.816 | 25.894 | 29.373 | 1.141 | 0.0 |
| netbird-relay | 1.197 | 0.456 | 1.064 | 1.849 | 0.316 | 1.053 | 1.932 | 1.648 | 1.226 | 5.405 | 0.663 | 2.3 |
| netbird-userspace | 0.667 | 0.188 | 0.474 | 0.907 | 0.136 | 0.495 | 1.095 | 0.936 | 11.547 | 19.060 | 3.793 | 0.0 |

#### Private path HTTP (target nginx, 1 KiB)

| config | c1 req/s | c1 p99 | c64 req/s | c64 p50 | c64 p99 | c64 success |
|---|---|---|---|---|---|---|
| baseline-default | 117836 | 0.014 | 550948 | 0.086 | 0.573 | 1.0000 |
| pangolin-default | 6874 | 1.854 | 15586 | 3.529 | 9.898 | 1.0000 |
| pangolin-relay | 3442 | 2.433 | 14758 | 3.671 | 9.521 | 1.0000 |
| netbird-default | 10356 | 0.117 | 124375 | 0.458 | 1.501 | 1.0000 |
| netbird-relay | 4329 | 0.454 | 27156 | 1.796 | 9.310 | 1.0000 |
| netbird-userspace | 13971 | 0.117 | 66938 | 0.907 | 1.885 | 1.0000 |

#### Public HTTPS reverse-proxy path

| config | c1 req/s | c1 p50 | c1 p99 | c64 req/s | c64 p50 | c64 p99 | c64 success | 100MB Mbit/s | 4x100MB Mbit/s | CPU-s (c64, 15s) |
|---|---|---|---|---|---|---|---|---|---|---|
| pangolin-default | 1733 | 0.438 | 6.082 | 2973 | 2.841 | 173.812 | 1.0000 | 1260 | 1515 | 26.2 |
| pangolin-relay | 1641 | 0.460 | 5.862 | 2849 | 2.751 | 162.996 | 1.0000 | 1160 | 1508 | 27.1 |
| netbird-default | 6690 | 0.138 | 0.280 | 33228 | 1.662 | 6.529 | 1.0000 | 2693 | 3859 | 59.0 |
| netbird-relay | 3582 | 0.258 | 0.492 | 18029 | 2.125 | 11.088 | 1.0000 | 632 | 720 | 46.1 |
| netbird-userspace | 6851 | 0.133 | 0.301 | 29289 | 1.901 | 7.128 | 1.0000 | 2646 | 4380 | 65.8 |

#### Resources

| config | idle CPU (millicores, product) | idle mem MB (product) | TCP down x4: product CPU-s/GB | TCP down x4: system CPU-s/GB | UDP 500M: product CPU-s/GB | UDP 500M: system CPU-s/GB | under TCP down x4: cores / peak mem |
|---|---|---|---|---|---|---|---|
| baseline-default | 0.0 | 0 | 0.00 | -0.00 | 0.00 | 0.32 |  |
| pangolin-default | 22.5 | 640 | 17.25 | 17.94 | 37.99 | 39.88 | pg-pangolin: 0.01c/315MB, pg-gerbil: 0.00c/9MB, pg-traefik: 0.00c/28MB, site: 0.69c/130MB, client: 0.85c/146MB |
| pangolin-relay | 23.1 | 560 | 55.89 | 65.49 | 71.18 | 80.33 | pg-pangolin: 0.01c/290MB, pg-gerbil: 0.69c/15MB, pg-traefik: 0.00c/24MB, site: 1.52c/401MB, client: 0.95c/85MB |
| netbird-default | 5.1 | 179 | 0.00 | 7.99 | 0.06 | 20.57 | nb-server: 0.00c/52MB, nb-proxy: 0.00c/43MB, site: 0.00c/28MB, client: 0.00c/31MB |
| netbird-relay | 1.7 | 156 | 19.22 | 28.39 | 18.40 | 28.69 | nb-server: 0.63c/39MB, nb-proxy: 0.00c/43MB, site: 0.51c/39MB, client: 0.62c/40MB |
| netbird-userspace | 4.5 | 379 | 5.73 | 5.67 | 16.29 | 18.05 | nb-server: 0.00c/30MB, nb-proxy: 0.00c/33MB, site: 2.58c/1756MB, client: 2.85c/1768MB |

#### Ops

| config | up.sh s | client restart → reachable s | image MB (sum) | images |
|---|---|---|---|---|
| baseline-default | 1 | – | 302 | target=227, client-tools=75 |
| pangolin-default | 30 | 5.5 / 5.5 / 5.5 | 916 | pg-pangolin=547, pg-gerbil=62, pg-traefik=221, site=51, client=35 |
| pangolin-relay | 32 | 6.5 / 6.5 / 6.5 | 916 | pg-pangolin=547, pg-gerbil=62, pg-traefik=221, site=51, client=35 |
| netbird-default | 25 | 5.5 / 5.5 / 5.5 | 607 | nb-server=323, nb-proxy=111, site=87, client=87 |
| netbird-relay | 27 | 5.5 / 5.5 / 5.4 | 607 | nb-server=323, nb-proxy=111, site=87, client=87 |
| netbird-userspace | 24 | 5.4 / 5.5 / 5.4 | 607 | nb-server=323, nb-proxy=111, site=87, client=87 |

### Profile `wan` (15 ms netem per side, ~34 ms RTT)

#### Private path throughput (Mbit/s, median of reps)

| config | TCP up 1 | TCP down 1 | TCP up 4 | TCP down 4 | HTTP 100MB | retrans (down 1) |
|---|---|---|---|---|---|---|
| baseline-default | 897 | 905 | 3458 | 3488 | 190 | 0 |
| pangolin-default | 36 | 26 | 58 | 49 | 27 | 32 |
| pangolin-relay | 53 | 31 | 75 | 56 | 27 | 24 |
| netbird-default | 256 | 251 | 265 | 265 | 208 | 48 |
| netbird-relay | 37 | 35 | 56 | 50 | 35 | 14 |
| netbird-userspace | 318 | 640 | 2749 | 2917 | 552 | 212 |

#### Private path UDP (achieved Mbit/s / loss % / jitter ms)

| config | up 100M | up 500M | up 1G | down 1G |
|---|---|---|---|---|
| baseline-default | 100 / 0.00 / 0.054 | 498 / 0.36 / 0.007 | 564 / 43.70 / 0.001 | 558 / 43.97 / 0.002 |
| pangolin-default | 100 / 0.02 / 0.407 | 313 / 37.52 / 0.018 | 313 / 68.18 / 0.073 | 508 / 49.10 / 0.009 |
| pangolin-relay | 100 / 0.02 / 0.974 | 294 / 40.17 / 0.508 | 291 / 70.52 / 0.694 | 118 / 32.85 / 0.010 |
| netbird-default | 100 / 0.00 / 0.038 | 493 / 1.39 / 0.011 | 536 / 45.11 / 0.014 | 571 / 42.78 / 0.052 |
| netbird-relay | 100 / 0.00 / 0.213 | 386 / 20.83 / 0.023 | 607 / 38.28 / 0.058 | 606 / 39.18 / 0.027 |
| netbird-userspace | 100 / 0.00 / 0.042 | 498 / 0.41 / 0.012 | 550 / 43.76 / 0.001 | 554 / 44.40 / 0.043 |

#### Private path latency (ms)

| config | ICMP avg | ICMP mdev | UDP p50 | UDP p99 | UDP jitter | TCP p50 | TCP p99 | connect p50 | loaded p50 | loaded p99 | loaded jitter | loaded loss % |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline-default | 33.759 | 1.845 | 32.369 | 36.175 | 1.509 | 33.839 | 37.609 | 35.174 | 32.961 | 37.066 | 1.636 | 0.0 |
| pangolin-default | 34.194 | 1.428 | 33.392 | 36.411 | 1.378 | 35.190 | 38.510 | 35.014 | 33.372 | 37.970 | 1.718 | 0.2 |
| pangolin-relay | 35.575 | 1.592 | 33.742 | 36.723 | 1.298 | 36.354 | 39.566 | 35.412 | 33.012 | 37.967 | 1.620 | 0.1 |
| netbird-default | 38.992 | 3.385 | 33.969 | 36.836 | 1.501 | 39.900 | 45.709 | 37.372 | 34.581 | 38.890 | 2.039 | 0.0 |
| netbird-relay | 38.000 | 3.162 | 34.028 | 37.256 | 1.502 | – | – | 36.026 | 33.892 | 38.545 | 1.853 | 0.1 |
| netbird-userspace | 35.019 | 2.177 | 33.465 | 36.756 | 1.635 | 39.420 | 44.990 | 35.926 | 33.829 | 42.583 | 2.785 | 0.0 |

#### Private path HTTP (target nginx, 1 KiB)

| config | c1 req/s | c1 p99 | c64 req/s | c64 p50 | c64 p99 | c64 success |
|---|---|---|---|---|---|---|
| baseline-default | 30 | 36.159 | 1757 | 36.480 | 39.418 | 1.0000 |
| pangolin-default | 28 | 41.048 | 1848 | 34.199 | 42.371 | 1.0000 |
| pangolin-relay | 27 | 39.601 | 1878 | 33.613 | 41.126 | 1.0000 |
| netbird-default | 24 | 45.504 | 1519 | 42.870 | 46.673 | 1.0000 |
| netbird-relay | 25 | 45.035 | 1733 | 36.458 | 42.545 | 1.0000 |
| netbird-userspace | 26 | 45.007 | 1679 | 38.115 | 44.365 | 1.0000 |

#### Public HTTPS reverse-proxy path

| config | c1 req/s | c1 p50 | c1 p99 | c64 req/s | c64 p50 | c64 p99 | c64 success | 100MB Mbit/s | 4x100MB Mbit/s | CPU-s (c64, 15s) |
|---|---|---|---|---|---|---|---|---|---|---|
| pangolin-default | 25 | 39.328 | 48.938 | 1662 | 35.647 | 74.840 | 1.0000 | 109 | 371 | 21.0 |
| pangolin-relay | 24 | 42.539 | 50.274 | 1670 | 35.831 | 59.399 | 1.0000 | 111 | 274 | 21.9 |
| netbird-default | 26 | 39.555 | 46.543 | 1919 | 32.916 | 38.762 | 1.0000 | 314 | 503 | 6.7 |
| netbird-relay | 26 | 38.936 | 45.113 | 1938 | 32.617 | 36.819 | 1.0000 | 52 | 77 | 8.8 |
| netbird-userspace | 26 | 37.969 | 45.135 | 1934 | 32.696 | 37.807 | 1.0000 | 450 | 1933 | 7.1 |

#### Resources

| config | idle CPU (millicores, product) | idle mem MB (product) | TCP down x4: product CPU-s/GB | TCP down x4: system CPU-s/GB | UDP 500M: product CPU-s/GB | UDP 500M: system CPU-s/GB | under TCP down x4: cores / peak mem |
|---|---|---|---|---|---|---|---|
| baseline-default | 0.0 | 0 | 0.00 | 0.04 | 0.00 | 1.57 |  |
| pangolin-default | 19.4 | 633 | 55.16 | 69.81 | 33.22 | 38.38 | pg-pangolin: 0.01c/314MB, pg-gerbil: 0.00c/9MB, pg-traefik: 0.00c/28MB, site: 0.15c/113MB, client: 0.12c/88MB |
| pangolin-relay | 19.4 | 606 | 121.73 | 165.90 | 67.80 | 78.71 | pg-pangolin: 0.01c/293MB, pg-gerbil: 0.15c/18MB, pg-traefik: 0.00c/44MB, site: 0.35c/229MB, client: 0.23c/81MB |
| netbird-default | 5.8 | 151 | 0.23 | 15.73 | 0.06 | 19.25 | nb-server: 0.00c/51MB, nb-proxy: 0.00c/42MB, site: 0.00c/28MB, client: 0.00c/33MB |
| netbird-relay | 1.7 | 142 | 93.85 | 143.36 | 20.18 | 33.27 | nb-server: 0.21c/41MB, nb-proxy: 0.00c/34MB, site: 0.12c/39MB, client: 0.17c/38MB |
| netbird-userspace | 3.9 | 671 | 4.45 | 4.58 | 16.42 | 19.97 | nb-server: 0.00c/48MB, nb-proxy: 0.00c/41MB, site: 0.67c/1232MB, client: 0.75c/1379MB |

#### Ops

| config | up.sh s | client restart → reachable s | image MB (sum) | images |
|---|---|---|---|---|
| baseline-default | 1 | – | 302 | target=227, client-tools=75 |
| pangolin-default | 25 | 5.5 / 5.4 / 5.5 | 916 | pg-pangolin=547, pg-gerbil=62, pg-traefik=221, site=51, client=35 |
| pangolin-relay | 32 | 6.5 / 6.6 / 6.5 | 916 | pg-pangolin=547, pg-gerbil=62, pg-traefik=221, site=51, client=35 |
| netbird-default | 42 | 5.5 / 5.5 / 5.5 | 607 | nb-server=323, nb-proxy=111, site=87, client=87 |
| netbird-relay | 41 | 5.5 / 5.5 / 5.5 | 607 | nb-server=323, nb-proxy=111, site=87, client=87 |
| netbird-userspace | 30 | 5.5 / 5.5 / 5.5 | 607 | nb-server=323, nb-proxy=111, site=87, client=87 |

## Running

Requirements: Docker with a Linux kernel that has the WireGuard module (tested on OrbStack, Apple M4), Python 3, `jq`, `openssl`, internet access during bring-up.

```bash
sh common/build.sh                      # bench-rtt, bench-target, bench-tools images
python3 run.py netbird default lan      # one run → results/netbird-default-lan.json
bash run_all.sh                         # full matrix; skips runs that already have results (FORCE=1 to redo)
python3 report.py > results/REPORT.md
```

Tunables: `REPS` (default 3), `TP_SECS` (iperf3 seconds, default 10). Only one stack may run at a time. Each run executes `down.sh` before `up.sh` and tears the stack down afterwards.

## Caveats

- Everything runs on one host, so absolute numbers are higher than over a real WAN link. Compare the stacks relative to each other and to the `baseline` (no tunnel) row.
- NetBird's relay runs WebSocket without TLS, so QUIC is unavailable and its relayed results are pessimistic.
- NetBird's proxy runs with `NB_LAZY_CONN=off`. With the default (lazy connections on), the public path returned 502 errors for minutes.
- With the `wan` profile, UDP at 1 Gbit/s is capped by netem's queue (the baseline also loses about 44 %). Those cells don't compare the products.
