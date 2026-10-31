# Pangolin bench stack

Compose project `pg`. Driven by `up.sh` / `down.sh`; `env.sh` for the runner.

```
NET_ID=1 NAME_SUFFIX=-pgdev ./up.sh     # dev, from scratch (runs down.sh first), exit 0 = both paths verified
RELAY=1 NET_ID=0 NAME_SUFFIX= ./up.sh   # forced relayed private path
./down.sh                               # compose down -v, DOCKER-USER isolation rules, state/
. ./env.sh                              # runner exports (same NET_ID / NAME_SUFFIX)
```

Subnets: `wan` 10.88.<NET_ID>.0/24, `sitelan` 10.89.<NET_ID>.0/24 (internal). Fixed IPs: gerbil/traefik .5, pangolin .6, site .3 (wan) / .2 (sitelan), client .4, loadgen .7, target 10.89.<NET_ID>.10.

## Versions

| component | version |
|---|---|
| Pangolin server | fosrl/pangolin 1.25.3 |
| gerbil | fosrl/gerbil 1.5.2 |
| traefik | traefik v3.7 (+ plugin badger v1.7.0 from GitHub), `network_mode: service:gerbil` |
| newt (site) | fosrl/newt 1.19.1 |
| olm (client) | fosrl/olm 1.10.1 |

## Bootstrap (all via API, no UI)

1. `pangolin` starts; setup token read from its log (`Token: ...`).
2. `PUT /api/v1/auth/set-server-admin`, `POST /api/v1/auth/login` (cookie jar in container).
3. `PUT /api/v1/api-key` root key; every `ActionsEnum` value granted via `POST /api/v1/api-key/:id/actions` (IDs taken from the server bundle).
4. `gerbil` started and waited for: it registers the exit node (`pick-site-defaults` succeeds only then).
5. Integration API (`:3003/v1`, Bearer root key): org `bench`, check config domain `bench.test`, site (newt, own id/secret), client (olm, from `pick-client-defaults`), private resource `host 10.89.N.10` (tcp/udp/icmp, client+site), public HTTP resource `app` (domain1 -> `app.bench.test`), policy `sso:false` with no users/roles, target `10.89.N.10:80` via site.
6. Rest of the stack started; both paths polled; smoke commands run.

## Data paths (evidence from runs on NET_ID=1)

### Private: client-tools -> olm -> newt -> target

**Direct (default, RELAY unset).** olm status (`client-tools`: `curl 127.0.0.1:9452/status`): `isRelay:false`, `endpoint 10.88.1.3:<port>` (newt's wan address), `isLocal:true`. olm runs its rapid test against the site's wan endpoint and switches to it. Gerbil only coordinates: gerbil `wg0` rx/tx stayed at 1138708/22076 -> 1138852/22156 across a 1 MB tunnel transfer plus ping/rtt/iperf (control traffic only). The bypass probe from loadgen (`10.89.N.10` direct) returns `000`.

`ip route get 10.89.1.10` inside client-tools: `dev olm` (TUN). Traffic enters the olm TUN, is encrypted by olm's WG, goes UDP 10.88.1.4 -> 10.88.1.3 directly, is decrypted by newt, and is forwarded by newt's netstack into 10.89.1.10.

**RELAY=1.** Pangolin/olm have no relay-only switch (see Limitations). up.sh uses the product's own relay logic. olm's wrapper adds `blackhole 10.88.N.3/32`, so olm's direct hole-punch to the site fails three times (or the rapid test fails), and olm sends `olm/wg/relay`. The server answers with `gerbil:21820` (relay port) and olm points its WG peer there. Evidence: olm `isRelay:true`, `endpoint 10.88.1.3:<port>` (last holepunch endpoint). Gerbil logs show a proxy mapping client `10.88.1.4:<p>` -> site tunnel `100.89.128.4:<p>` (kernel WG peer). Gerbil `wg0` counters rose by 4.4 MB rx / 57 MB tx during the relay smoke tests (rx 5514676 -> 9907252, tx 57781772 -> 115299564).

Relay-path smoke numbers were lower (TCP about 100 Mbit/s, direct about 1.3 Gbit/s on the same host). These are smoke-level observations, not benchmarks.

### Public: loadgen -> traefik -> gerbil wg0 -> newt -> target

`curl --resolve app.bench.test:443:10.88.N.5 https://app.bench.test/1k` returns `200 1024`, and `/1m` returns `200 1048576`. traefik (gerbil's netns) routes to the site's tunnel address `100.89.128.x:<internalPort>` through gerbil's **kernel WG** `wg0`. Gerbil `wg0` rx rose by 1.13 MB during a 1 MB public fetch (1140548 -> 2275572). newt receives it on its netstack tunnel and dials `10.89.N.10:80`. SSO is disabled, so no auth is involved.

## Kernel vs userspace WireGuard per hop

| hop | WG implementation | notes |
|---|---|---|
| gerbil <-> newt (site tunnel, `wg0` 100.89.128.1/22) | **kernel** (gerbil creates `wg0` via netlink; VM kernel 7.2 has `wireguard` module) | used by public path and by relayed private traffic |
| newt <-> gerbil (newt side) | **userspace** netstack (newt default, `-native-main` off) | no WG interface in site netns |
| olm <-> newt (private, direct or relayed) | **userspace** (olm uses wireguard-go over TUN `olm`; `UAPI listener started`) | client netns has no kernel WG device |
| olm <-> gerbil relay | olm userspace proxy -> gerbil UDP 21820 -> gerbil kernel wg0 | relay only |
| newt netstack -> target | host-level TCP/UDP/ICMP proxy inside newt | target on sitelan |

## Non-default settings

- `config/config.yml`: `flags.enable_integration_api: true` (required for API automation). `telemetry.anonymous_usage: false`, `notifications.*: false`. `traefik.cert_resolver: ""` (no Let's Encrypt; routers emit no certResolver and Traefik serves the self-signed file-provider cert in `state/traefik/certs`). `gerbil.base_endpoint: pangolin.bench.test` (site/client resolve it via `extra_hosts` to gerbil's wan IP). `SERVER_SECRET` is a literal bench value in compose.
- Dashboard host `pangolin.bench.test`; base domain `bench.test`. Cert SANs cover `bench.test`, `*.bench.test`, `pangolin.bench.test`.
- Traefik: no ACME resolver. Dashboard uses `badger` middleware with `disableForwardAuth`, as upstream.
- newt: wrapper sets `LOCAL_ENDPOINT_INTERFACES` to the default-route (wan) interface. Otherwise newt advertises the sitelan address, olm probes it, and it only works because the host forwards between bridges.
- olm: `ENABLE_API=true`, `HTTP_ADDR=127.0.0.1:9452` (evidence endpoint in the shared netns). `RELAY=1` sets `BENCH_RELAY=1`, and the olm wrapper adds the blackhole route.
- gerbil: `--log-level=DEBUG`. Ports are not published to the host.
- Admin / root key / site/client creds are bench-only (generated per run; admin password fixed in `up.sh`).
- Startup ordering: gerbil is started before newt/olm, and up.sh waits for the exit node. If newt connects before gerbil registers, newt gets no exit node, never hole-punches, and stalls (the server withholds get-config until the site has an endpoint).

## Host-level change (outside compose)

`internal: true` does not isolate `sitelan` on this OrbStack host: the VM forwards between bridges (FORWARD ACCEPT, DOCKER-USER ACCEPT, `ip_forward=1`), so a wan-only container reached `10.89.N.10` directly (HTTP 200) before the fix. up.sh therefore inserts two DROP rules in the VM's `DOCKER-USER` chain for wan<->sitelan of this NET_ID (tag `bench-pg-isolate-<NET_ID>`), via a privileged `alpine --net=host` helper. down.sh removes all rules with that tag. After the fix, the bypass probe returns `000` and the tunnel path still works.

Target-side firewall (requested by the orchestrator): `iptables -A INPUT -s 10.89.N.1 -j DROP` in target's netns. Install it with `nsenter` (`--pid=host`): `nsenter -t $(docker inspect -f '{{.State.Pid}}' target-pgdev) -n iptables ...`. Verified in both modes: direct and relay paths all pass with it in place. Note: the target is on an internal network and has no internet, so `apk add` cannot run inside it; install iptables from a host-namespace helper instead.

## Limitations

- **No relay-only switch in Pangolin/olm.** `olm -disable-holepunch` (`DISABLE_HOLEPUNCH`) makes the server reject registration with `HOLEPUNCH_MISSING`, because `client.lastHolePunch` is only set by gerbil receiving olm hole-punch packets (`handleOlmRegisterMessage`, `updateHolePunch`). `-disable-relay` is the opposite. olm requests relay only after its direct test to the site's public endpoint fails (`peers/monitor`, `peers_manager.go`). So `RELAY=1` emulates a client that cannot reach the site directly (NAT/firewall): a blackhole route in the olm container. The relay itself is the product's own `olm/wg/relay` path. It is a host-network emulation, not a Pangolin flag.
- On this topology the direct path is "local endpoint" 10.88.N.3 (same bridge). The holepunch endpoint is the same address, so both are direct P2P, not via gerbil.
- Startup race: on a fresh state dir the first pangolin start can exit once with "No configuration file found" (bind-mount visibility). `restart: unless-stopped` recovers; up.sh polls health instead of `--wait`.
- up.sh needs internet for the traefik badger plugin (GitHub) and for `apk add iptables` (alpine helper). It uses host `jq` and `openssl`.
- `docker compose` must be v2+ (`up -d`, healthcheck `depends_on`).
- `client-tools` uses `network_mode: service:client`. Recreating `client` requires recreating `client-tools`.
- Not run: throughput benchmarks; only smoke checks.
