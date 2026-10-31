# pangolin-vs-netbird-bench

Reproducible benchmark of two self-hosted WireGuard remote-access stacks:

- **Pangolin** 1.25.3 (gerbil 1.5.2, traefik v3.7, newt 1.19.1 site connector, olm 1.10.1 client)
- **NetBird** 0.82.0 (combined server, reverse-proxy, netbird client as routing peer and as client)

Both stacks are brought up fully automatically through each product's API (no UI). Each run measures two paths:

1. **Private access:** VPN client → tunnel → site connector → target on an isolated site LAN.
2. **Public reverse proxy:** HTTPS `app.bench.test` → product proxy → tunnel → site → target.

Full results: [`results/REPORT.md`](results/REPORT.md). Raw data: `results/*.json`. Stack details (data path evidence, kernel vs userspace WireGuard, non-default settings): `pangolin/NOTES.md`, `netbird/NOTES.md`.

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
