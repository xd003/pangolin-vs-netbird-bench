#!/bin/sh
# Bring up the NetBird 0.82.0 benchmark stack from scratch and wait until the
# private path (client -> site -> target) and the public path
# (loadgen -> nb-proxy -> site -> target) both work. Exits 0 only when both
# checks pass. Everything is driven through the management REST API, executed
# from inside the loadgen container (no host ports are published).
#
# Usage:  [NET_ID=2] [NAME_SUFFIX=-nbdev] [RELAY=1] [WG_USERSPACE=1] ./up.sh
#   RELAY=1         site and client run with NB_FORCE_RELAY=true (relayed via nb-server)
#   WG_USERSPACE=1  site and client run with NB_WG_KERNEL_DISABLED=true (userspace WG)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
. ./env.sh

RELAY=${RELAY:-0}
WG_USERSPACE=${WG_USERSPACE:-0}
case $RELAY in 0 | 1) ;; *) echo "RELAY must be 0 or 1" >&2; exit 2 ;; esac
case $WG_USERSPACE in 0 | 1) ;; *) echo "WG_USERSPACE must be 0 or 1" >&2; exit 2 ;; esac

if [ "$RELAY" = 1 ]; then NB_FORCE_RELAY=true; else NB_FORCE_RELAY=; fi
if [ "$WG_USERSPACE" = 1 ]; then NB_WG_KERNEL_DISABLED=true; else NB_WG_KERNEL_DISABLED=; fi
export NB_FORCE_RELAY NB_WG_KERNEL_DISABLED

BASE="http://nb-server:8080"
SITE_LAN_CIDR="${PRIVATE_TARGET}/32"
DEFAULT_POLICY_NAME="Default"

log() { printf '[up %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# poll DESC TIMEOUT_S CMD...  re-runs CMD every 3s until it succeeds
poll() {
  _desc=$1; _limit=$2; shift 2
  _t=0
  until "$@" >/dev/null 2>&1; do
    _t=$((_t + 3))
    if [ "$_t" -ge "$_limit" ]; then log "FAIL: timed out waiting for: $_desc"; return 1; fi
    sleep 3
  done
  log "ok: $_desc (~${_t}s)"
}

# --- preflight ---------------------------------------------------------------
for img in bench-target bench-tools; do
  docker image inspect "$img" >/dev/null 2>&1 || {
    log "image $img missing, building via bench/common/build.sh"
    sh "$HERE/../common/build.sh"
  }
done
if [ -e state ] || [ -n "$(docker compose ps -aq 2>/dev/null)" ] ||
  [ -n "$(docker volume ls -q --filter label=com.docker.compose.project=nb)" ]; then
  die "stale state present (state/, nb containers or nb volumes). Run ./down.sh first."
fi

# --- state + static certificate for the public hostname -----------------------
mkdir -p state/certs
openssl ecparam -name prime256v1 -param_enc named_curve -genkey -noout -out state/certs/tls.key
openssl req -x509 -new -key state/certs/tls.key -out state/certs/tls.crt -days 3650 \
  -subj "/CN=bench.test" -addext "subjectAltName=DNS:bench.test,DNS:*.bench.test"
chmod 644 state/certs/tls.crt state/certs/tls.key

# --- API helper: curl runs inside loadgen (wan); JSON body on stdin -------------
# api METHOD PATH [JSON]: prints the body on 2xx; otherwise logs the error, returns 1.
api() {
  _m=$1; _p=$2; _b=${3-}
  if [ -n "$_b" ]; then
    _out=$(printf '%s' "$_b" | docker exec -i "loadgen${NAME_SUFFIX}" curl -sS -X "$_m" \
      -H "Authorization: Token $PAT" -H 'Content-Type: application/json' \
      --data-binary @- -w '\n%{http_code}' "$BASE$_p") || return 1
  else
    _out=$(docker exec "loadgen${NAME_SUFFIX}" curl -sS -X "$_m" \
      -H "Authorization: Token $PAT" -w '\n%{http_code}' "$BASE$_p") || return 1
  fi
  _code=$(printf '%s' "$_out" | tail -n 1)
  _resp=$(printf '%s' "$_out" | sed '$d')
  case $_code in
    2*) printf '%s' "$_resp" ;;
    *) log "API $_m $_p -> HTTP $_code: $_resp"; return 1 ;;
  esac
}

# --- 0. isolate wan<->sitelan at the host bridge layer ---------------------------
# On this OrbStack VM internal:true does not stop bridge forwarding: a wan-only
# container reaches 10.89.X.10 directly, bypassing the tunnel. Insert DROP rules
# into DOCKER-USER for this NET_ID only, tagged so down.sh removes exactly them.
ISO_TAG="bench-nb-isolate-${NET_ID}"
log "installing host DOCKER-USER isolation rules (tag $ISO_TAG)"
docker run --rm --net=host --privileged alpine:3.22 sh -c '
  apk add -q iptables >/dev/null 2>&1 || exit 1
  tag=$1; net=$2
  iptables -S DOCKER-USER | grep -q -- "--comment $tag" && exit 0
  iptables -I DOCKER-USER 1 -s 10.89.$net.0/24 -d 10.88.$net.0/24 -m comment --comment "$tag" -j DROP
  iptables -I DOCKER-USER 1 -s 10.88.$net.0/24 -d 10.89.$net.0/24 -m comment --comment "$tag" -j DROP
  iptables -S DOCKER-USER | grep -q -- "--comment $tag"
' sh "$ISO_TAG" "$NET_ID" >/dev/null || die "could not install DOCKER-USER isolation rules"
# --- 1. combined server (management + signal + relay + STUN + embedded IdP) ----
log "starting nb-server, loadgen, target"
docker compose up -d nb-server loadgen target >/dev/null
poll "management API up" 120 docker exec "loadgen${NAME_SUFFIX}" curl -sf "$BASE/api/instance"

# --- 2. bootstrap admin + PAT (NB_SETUP_PAT_ENABLED=true) ---------------------
log "bootstrapping admin via /api/setup"
_setup=$(printf '%s' '{"email":"admin@bench.test","password":"Bench-e2e-Passw0rd!","name":"Bench Admin","create_pat":true,"pat_expire_in":1}' |
  docker exec -i "loadgen${NAME_SUFFIX}" curl -sS -H 'Content-Type: application/json' \
    --data-binary @- "$BASE/api/setup") || die "setup request failed"
PAT=$(printf '%s' "$_setup" | jq -r '.personal_access_token // empty')
[ -n "$PAT" ] || die "setup returned no PAT: $_setup"

# --- 3. global proxy token via server CLI, then the reverse proxy -------------
log "minting proxy token (server CLI)"
NB_PROXY_TOKEN=$(docker exec "nb-server${NAME_SUFFIX}" /go/bin/netbird-server token create \
  --name bench-proxy --config /nb/config.yaml 2>/dev/null | sed -n 's/^Token: //p')
[ -n "$NB_PROXY_TOKEN" ] || die "token create produced no token"
export NB_PROXY_TOKEN
log "creating nb-proxy, copying static certificate into its volume, starting"
docker compose up -d --no-start nb-proxy >/dev/null
docker cp state/certs/. "nb-proxy${NAME_SUFFIX}:/certs/"
docker compose start nb-proxy >/dev/null

cluster_online() {
  api GET /api/reverse-proxies/clusters |
    jq -e '.[] | select(.address == "bench.test" and .online == true)' >/dev/null
}
poll "proxy cluster bench.test online" 120 cluster_online

# --- 4. groups, setup keys, network, resource, routing peer, policy, service --
log "creating groups, setup keys, network, resource, routing peer"
GROUP_SITES=$(api POST /api/groups '{"name":"bench-sites"}' | jq -r .id)
GROUP_CLIENTS=$(api POST /api/groups '{"name":"bench-clients"}' | jq -r .id)
GROUP_TARGET=$(api POST /api/groups '{"name":"bench-target"}' | jq -r .id)

SITE_SETUP_KEY=$(api POST /api/setup-keys \
  "{\"name\":\"bench-site\",\"type\":\"reusable\",\"expires_in\":86400,\"auto_groups\":[\"$GROUP_SITES\"]}" | jq -r .key)
CLIENT_SETUP_KEY=$(api POST /api/setup-keys \
  "{\"name\":\"bench-client\",\"type\":\"reusable\",\"expires_in\":86400,\"auto_groups\":[\"$GROUP_CLIENTS\"]}" | jq -r .key)
export SITE_SETUP_KEY CLIENT_SETUP_KEY

NETWORK_ID=$(api POST /api/networks '{"name":"bench-site-lan","description":"bench private site LAN (sitelan)"}' | jq -r .id)
RESOURCE_ID=$(api POST "/api/networks/$NETWORK_ID/resources" \
  "{\"name\":\"bench-target\",\"address\":\"$SITE_LAN_CIDR\",\"enabled\":true,\"groups\":[\"$GROUP_TARGET\"]}" | jq -r .id)
api POST "/api/networks/$NETWORK_ID/routers" \
  "{\"peer_groups\":[\"$GROUP_SITES\"],\"metric\":9999,\"masquerade\":true,\"enabled\":true}" >/dev/null

# The account is created with NetBird's automatic "Default" All<->All policy. Remove
# it so the bench policy below is the only ACL path to the resource.
_default_ids=$(api GET /api/policies | jq -r ".[] | select(.name == \"$DEFAULT_POLICY_NAME\") | .id")
for _id in $_default_ids; do
  api DELETE "/api/policies/$_id" >/dev/null
  log "removed automatic policy '$DEFAULT_POLICY_NAME' ($_id)"
done

api POST /api/policies "{\"name\":\"bench-clients-to-target\",\"description\":\"private access: clients -> $PRIVATE_TARGET, all protocols\",\"enabled\":true,\"rules\":[{\"name\":\"clients-to-target-all\",\"enabled\":true,\"action\":\"accept\",\"bidirectional\":true,\"protocol\":\"all\",\"sources\":[\"$GROUP_CLIENTS\"],\"destinationResource\":{\"id\":\"$RESOURCE_ID\",\"type\":\"host\"}}]}" >/dev/null

log "creating public reverse-proxy service $PUBLIC_HOST -> $PRIVATE_TARGET:80 (no auth)"
api POST /api/reverse-proxies/services "{\"name\":\"bench-app\",\"domain\":\"$PUBLIC_HOST\",\"enabled\":true,\"mode\":\"http\",\"private\":false,\"targets\":[{\"target_id\":\"$RESOURCE_ID\",\"target_type\":\"host\",\"protocol\":\"http\",\"port\":80,\"enabled\":true,\"path\":\"/\",\"access_action\":\"inherit\"}]}" >/dev/null

# --- 5. routing peer + client enrollment ---------------------------------------
log "starting site, client, client-tools"
docker compose up -d site client client-tools >/dev/null

mgmt_connected() { docker exec "$CLIENT_CONTAINER" netbird status 2>/dev/null | grep -q 'Management: Connected'; }
poll "client management connected" 180 mgmt_connected
site_mgmt_connected() { docker exec "$SITE_CONTAINER" netbird status 2>/dev/null | grep -q 'Management: Connected'; }
poll "site management connected" 180 site_mgmt_connected

# --- 6. path checks -----------------------------------------------------------
# Peers are lazy by default: the first probe wakes the tunnel, so poll.
private_ok() {
  docker exec "$CLIENT_TOOLS_CONTAINER" ping -c 1 -W 3 "$PRIVATE_TARGET" >/dev/null 2>&1 &&
    docker exec "$CLIENT_TOOLS_CONTAINER" curl -sf -m 10 -o /dev/null "http://$PRIVATE_TARGET/1k"
}
poll "private path (ICMP + HTTP through site)" 240 private_ok

public_ok() {
  _r=$(docker exec "$LOADGEN_CONTAINER" curl -sk -m 15 --resolve "$PUBLIC_RESOLVE" \
    "https://$PUBLIC_HOST/1k" -o /dev/null -w '%{http_code} %{size_download}') || return 1
  [ "$_r" = "200 1024" ]
}
poll "public path (loadgen -> nb-proxy -> site -> target)" 240 public_ok

# --- 7. verify the requested connection type and WG implementation ------------
# site_peer_field CONTAINER FIELD: value of FIELD for the site peer in `netbird status -d`
site_peer_field() {
  docker exec "$1" netbird status -d 2>/dev/null |
    awk -v f="$2" '/^ [^ ]/ { p = ($0 ~ /^ site\./) } p && index($0, f ":") { sub(/.*: */, ""); print; exit }'
}
want_type=P2P
[ "$RELAY" = 1 ] && want_type=Relayed
want_iface=Kernel
[ "$WG_USERSPACE" = 1 ] && want_iface=Userspace

conn_type_ok() { [ "$(site_peer_field "$CLIENT_CONTAINER" "Connection type")" = "$want_type" ]; }
poll "client->site connection type = $want_type" 120 conn_type_ok

for _c in "$CLIENT_CONTAINER" "$SITE_CONTAINER"; do
  _if=$(docker exec "$_c" netbird status 2>/dev/null | sed -n 's/^Interface type: *//p')
  [ "$_if" = "$want_iface" ] || die "$_c interface type is '$_if', expected $want_iface"
  log "ok: $_c interface type $_if"
done

# --- 8. smoke checks (short durations; these are not benchmarks) ---------------
ct=$CLIENT_TOOLS_CONTAINER
smoke() { _desc=$1; shift; "$@" >/dev/null || die "smoke failed: $_desc"; log "ok: $_desc"; }
smoke "iperf3 TCP" docker exec "$ct" iperf3 -c "$PRIVATE_TARGET" -t 2
smoke "iperf3 UDP 100M" docker exec "$ct" iperf3 -c "$PRIVATE_TARGET" -u -b 100M -t 2
smoke "rtt udp" sh -c "docker exec '$ct' rtt udp -target '$PRIVATE_TARGET:7000' -duration 2s | jq -e '.received > 0'"
smoke "rtt tcp" sh -c "docker exec '$ct' rtt tcp -target '$PRIVATE_TARGET:7001' -duration 2s | jq -e '.received > 0'"
smoke "ping" docker exec "$ct" ping -c 3 -W 3 "$PRIVATE_TARGET"
_mb=$(docker exec "$ct" curl -sf -m 30 -o /dev/null -w '%{size_download}' "http://$PRIVATE_TARGET/1m") || die "curl /1m failed"
[ "$_mb" = 1048576 ] || die "curl /1m returned $_mb bytes"
log "ok: private curl /1m = $_mb bytes"
_pub=$(docker exec "$LOADGEN_CONTAINER" curl -sk -m 30 --resolve "$PUBLIC_RESOLVE" \
  "https://$PUBLIC_HOST/1k" -o /dev/null -w '%{http_code} %{size_download}') || die "public curl failed"
[ "$_pub" = "200 1024" ] || die "public /1k returned '$_pub'"
log "ok: public https://$PUBLIC_HOST/1k = $_pub"

log "UP: RELAY=$RELAY WG_USERSPACE=$WG_USERSPACE NET_ID=$NET_ID NAME_SUFFIX='$NAME_SUFFIX'"
log "client->site: $(site_peer_field "$CLIENT_CONTAINER" "Connection type"), interface: $want_iface"
