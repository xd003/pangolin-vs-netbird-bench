#!/bin/sh
# Bring up the Pangolin 1.25.3 bench stack from scratch, bootstrap everything through the product APIs,
# wait until the private (olm -> newt -> target) and public (loadgen -> traefik -> newt -> target) paths work,
# then smoke-test them. Exit 0 only when both paths work.
#
#   NET_ID=1 NAME_SUFFIX=-pgdev ./up.sh          # dev
#   NET_ID=0 NAME_SUFFIX= ./up.sh                # final
#   RELAY=1 NET_ID=0 NAME_SUFFIX= ./up.sh        # force the private path through the gerbil relay
#
# Always starts from scratch (runs down.sh first). Requires docker (compose v2+), jq, openssl.
set -eu
cd "$(dirname "$0")"

export NET_ID="${NET_ID:-0}"
export NAME_SUFFIX="${NAME_SUFFIX:-}"
RELAY="${RELAY:-0}"
case "$RELAY" in 0|1) ;; *) echo "RELAY must be 0 or 1" >&2; exit 2 ;; esac
export RELAY

S="$NAME_SUFFIX"
PG="pg-pangolin$S"
GERBIL="pg-gerbil$S"
TRAEFIK="pg-traefik$S"
SITE="site$S"
CLIENT="client$S"
CLIENT_TOOLS="client-tools$S"
LOADGEN="loadgen$S"

WAN_CIDR="10.88.${NET_ID}.0/24"
SL_CIDR="10.89.${NET_ID}.0/24"
GERBIL_WAN_IP="10.88.${NET_ID}.5"
TARGET_IP="10.89.${NET_ID}.10"

ORG_ID="bench"
ADMIN_EMAIL="admin@bench.test"
ADMIN_PASSWORD="BenchAdmin!2026"
JAR="/tmp/bench-admin.jar"
CSRF="X-CSRF-Token: x-csrf-protection"

log()  { printf '[up %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { printf '[up] FAILED: %s\n' "$*" >&2; exit 1; }

for tool in docker jq openssl; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done
for img in bench-target bench-tools; do
    if ! docker image inspect "$img" >/dev/null 2>&1; then
        log "image $img missing: building bench images"
        sh ../common/build.sh
    fi
done

# ---- helpers -------------------------------------------------------------------------------------------

# admin_api METHOD PATH [JSON]  -> Pangolin dashboard API (:3000/api/v1), session cookie + CSRF header
admin_api() {
    m=$1; p=$2; b=${3-}
    if [ -n "$b" ]; then
        printf '%s' "$b" | docker exec -i "$PG" curl -sS -X "$m" -b "$JAR" -c "$JAR" -H "$CSRF" \
            -H 'Content-Type: application/json' --data-binary @- "http://localhost:3000/api/v1$p"
    else
        docker exec "$PG" curl -sS -X "$m" -b "$JAR" -c "$JAR" -H "$CSRF" "http://localhost:3000/api/v1$p"
    fi
}

# int_api METHOD PATH [JSON]  -> integration API (:3003/v1), Bearer root API key. Dies on success=false.
int_api() {
    m=$1; p=$2; b=${3-}
    if [ -n "$b" ]; then
        out=$(printf '%s' "$b" | docker exec -i "$PG" curl -sS -X "$m" -H "Authorization: Bearer $API_KEY" \
            -H 'Content-Type: application/json' --data-binary @- "http://localhost:3003/v1$p")
    else
        out=$(docker exec "$PG" curl -sS -X "$m" -H "Authorization: Bearer $API_KEY" "http://localhost:3003/v1$p")
    fi
    if ! printf '%s' "$out" | jq -e '.success == true' >/dev/null 2>&1; then
        fail "integration API $m $p: $out"
    fi
    printf '%s' "$out"
}

# poll DESC TIMEOUT_S CMD...  -> retry CMD every 2s until success
poll() {
    desc=$1; limit=$2; shift 2
    waited=0
    while ! "$@" >/dev/null 2>&1; do
        [ "$waited" -ge "$limit" ] && fail "$desc: not ready after ${limit}s"
        sleep 2; waited=$((waited + 2))
    done
    log "$desc: ready after ${waited}s"
}

rand_alnum() { LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c "$1"; }
rand_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

# exit_node_ready -> succeeds once gerbil has registered an exit node (pick-site-defaults needs one)
exit_node_ready() {
    docker exec "$PG" curl -sS -H "Authorization: Bearer $API_KEY" "http://localhost:3003/v1/org/$ORG_ID/pick-site-defaults" \
        | jq -e '.success == true' >/dev/null
}

pangolin_healthy() { [ "$(docker inspect -f '{{.State.Health.Status}}' "$PG" 2>/dev/null)" = healthy ]; }

check_public() {
    docker exec "$LOADGEN" sh -c "curl -sk --max-time 5 --resolve app.bench.test:443:$GERBIL_WAN_IP -o /dev/null -w '%{http_code} %{size_download}' https://app.bench.test/1k" | grep -qx '200 1024'
}
check_private() {
    docker exec "$CLIENT_TOOLS" sh -c "curl -s --max-time 5 -o /dev/null -w '%{http_code} %{size_download}' http://$TARGET_IP/1k" | grep -qx '200 1024'
}
# Path mode as reported by olm itself (olm API on 127.0.0.1:9452 in the shared client netns).
check_mode() {
    want=$([ "$RELAY" = 1 ] && echo true || echo false)
    docker exec "$CLIENT_TOOLS" sh -c 'curl -s --max-time 3 http://127.0.0.1:9452/status' \
        | jq -e --argjson want "$want" '(.peers | length) > 0 and ([.peers[] | (.connected == true and .isRelay == $want)] | all)' >/dev/null
}

# DOCKER-USER isolation. The OrbStack/Docker host forwards between bridges, so `internal: true` alone does not stop
# wan clients from reaching sitelan directly. Drop wan<->sitelan forwarding for this stack's subnets only.
isolate_apply() {
    docker run --rm -i --privileged --net=host alpine:3.22 sh -s -- "$WAN_CIDR" "$SL_CIDR" "bench-pg-isolate-$NET_ID" <<'EOS'
set -e
apk add -q --no-cache iptables >/dev/null
WAN=$1; SL=$2; TAG=$3
for dir in 1 2; do
    if [ "$dir" = 1 ]; then src=$WAN; dst=$SL; else src=$SL; dst=$WAN; fi
    iptables -C DOCKER-USER -s "$src" -d "$dst" -m comment --comment "$TAG" -j DROP 2>/dev/null \
        || iptables -I DOCKER-USER -s "$src" -d "$dst" -m comment --comment "$TAG" -j DROP
done
EOS
}

# ---- 0. clean slate -------------------------------------------------------------------------------------

log "clean slate (down.sh)"
sh ./down.sh >/dev/null

mkdir -p state/pangolin/letsencrypt state/gerbil state/traefik/certs
cp config/config.yml state/pangolin/config.yml
echo '{}' > state/pangolin/letsencrypt/acme.json
openssl req -x509 -newkey rsa:2048 -nodes -keyout state/traefik/certs/bench.test.key \
    -out state/traefik/certs/bench.test.crt -days 3650 -subj "/CN=bench.test" \
    -addext "subjectAltName=DNS:bench.test,DNS:*.bench.test,DNS:pangolin.bench.test" >/dev/null 2>&1

# ---- 1. control plane first (site/client credentials are created through the API) -----------------------

log "starting pangolin (NET_ID=$NET_ID NAME_SUFFIX='$NAME_SUFFIX')"
docker compose -p pg up -d pangolin >/dev/null
# Not `--wait`: on a fresh state dir the first start can race the bind mount of config/ and exit once
# ("No configuration file found"); restart: unless-stopped recovers it, so poll health instead.
poll "pangolin healthy" 180 pangolin_healthy

log "reading setup token from pangolin logs"
TOKEN=""
i=0
while [ -z "$TOKEN" ]; do
    TOKEN=$(docker logs "$PG" 2>&1 | sed -n 's/^Token: \([a-z0-9]\{32\}\)$/\1/p' | tail -1)
    [ -n "$TOKEN" ] && break
    [ "$i" -ge 60 ] && fail "setup token not found in pangolin logs"
    sleep 2; i=$((i + 1))
done

log "bootstrapping server admin"
out=$(admin_api PUT /auth/set-server-admin "$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" --arg t "$TOKEN" \
    '{email:$e,password:$p,setupToken:$t}')")
printf '%s' "$out" | jq -e '.success == true' >/dev/null || fail "set-server-admin: $out"

out=$(admin_api POST /auth/login "$(jq -nc --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" '{email:$e,password:$p}')")
printf '%s' "$out" | jq -e '.success == true' >/dev/null || fail "login: $out"

log "creating root API key and granting every action"
out=$(admin_api PUT /api-key '{"name":"bench-root"}')
API_KEY_ID=$(printf '%s' "$out" | jq -r '.data.apiKeyId // empty')
API_KEY_SECRET=$(printf '%s' "$out" | jq -r '.data.apiKey // empty')
[ -n "$API_KEY_ID" ] && [ -n "$API_KEY_SECRET" ] || fail "create api key: $out"
API_KEY="$API_KEY_ID.$API_KEY_SECRET"

# Action IDs are the ActionsEnum values compiled into the server bundle (the same set ensureActions seeds).
ACTION_IDS=$(docker exec "$PG" sh -c 'grep -o "ActionsEnum2\[\"[A-Za-z0-9]*\"\] = \"[A-Za-z0-9]*\"" /app/dist/server.mjs | sed "s/.*= \"\(.*\)\"/\1/" | sort -u')
[ -n "$ACTION_IDS" ] || fail "could not extract ActionsEnum from server bundle"
ACTIONS_JSON=$(printf '%s\n' "$ACTION_IDS" | jq -R . | jq -sc '{actionIds: .}')
out=$(admin_api POST "/api-key/$API_KEY_ID/actions" "$ACTIONS_JSON")
printf '%s' "$out" | jq -e '.success == true' >/dev/null || fail "grant actions: $out"

# ---- 2. objects via the integration API --------------------------------------------------------------

log "creating org $ORG_ID"
int_api PUT /org "$(jq -nc --arg o "$ORG_ID" '{orgId:$o,name:"Bench",subnet:"100.90.128.0/24",utilitySubnet:"100.96.128.0/24"}')" >/dev/null

log "checking config-managed domain bench.test"
int_api GET "/org/$ORG_ID/domains" | jq -e '.data.domains[] | select(.domainId == "domain1" and .baseDomain == "bench.test" and .verified == true)' >/dev/null \
    || fail "domain1 (bench.test) not present for org $ORG_ID"

# newt/olm learn their exit node only from the connect response, and the server withholds get-config until the
# site has hole-punched. If newt connects before gerbil has registered its exit node it never hole-punches and
# stalls. So start gerbil (which registers the exit node with pangolin) and wait for it before creating
# the site/client and starting newt/olm.
log "starting gerbil (registers exit node with pangolin)"
docker compose -p pg up -d gerbil >/dev/null
poll "exit node registered (gerbil)" 180 exit_node_ready

NEWT_ID=$(rand_alnum 15)
NEWT_SECRET=$(rand_secret 48)
log "creating site (newt $NEWT_ID)"
out=$(int_api PUT "/org/$ORG_ID/site" "$(jq -nc --arg id "$NEWT_ID" --arg s "$NEWT_SECRET" \
    '{name:"bench-site",niceId:"bench-site",type:"newt",newtId:$id,secret:$s}')")
SITE_ID=$(printf '%s' "$out" | jq -r '.data.siteId')

log "creating machine client (olm) from pick-client-defaults"
pick=$(int_api GET "/org/$ORG_ID/pick-client-defaults")
OLM_ID=$(printf '%s' "$pick" | jq -r '.data.olmId')
OLM_SECRET=$(printf '%s' "$pick" | jq -r '.data.olmSecret')
OLM_SUBNET=$(printf '%s' "$pick" | jq -r '.data.subnet')
out=$(int_api PUT "/org/$ORG_ID/client" "$(jq -nc --arg id "$OLM_ID" --arg s "$OLM_SECRET" --arg n "$OLM_SUBNET" \
    '{name:"bench-client",type:"olm",olmId:$id,secret:$s,subnet:$n}')")
CLIENT_ID=$(printf '%s' "$out" | jq -r '.data.clientId')

log "creating private site resource $TARGET_IP (tcp/udp/icmp) for client $CLIENT_ID via site $SITE_ID"
int_api PUT "/org/$ORG_ID/private-resource" "$(jq -nc --arg d "$TARGET_IP" --argjson s "$SITE_ID" --argjson c "$CLIENT_ID" \
    '{name:"sitelan-target",mode:"host",destination:$d,siteIds:[$s],clientIds:[$c],roleIds:[],userIds:[],tcpPortRangeString:"*",udpPortRangeString:"*",disableIcmp:false}')" >/dev/null

log "creating public http resource app.bench.test -> $TARGET_IP:80 (no SSO, no auth)"
out=$(int_api PUT "/org/$ORG_ID/resource" '{"name":"app-public","mode":"http","domainId":"domain1","subdomain":"app"}')
RESOURCE_ID=$(printf '%s' "$out" | jq -r '.data.resourceId')
POLICY_ID=$(printf '%s' "$out" | jq -r '.data.defaultResourcePolicyId')
int_api POST "/resource-policy/$POLICY_ID/access-control" '{"sso":false,"userIds":[],"roleIds":[]}' >/dev/null
int_api PUT "/resource/$RESOURCE_ID/target" "$(jq -nc --argjson s "$SITE_ID" --arg ip "$TARGET_IP" \
    '{siteId:$s,ip:$ip,port:80,method:"http",enabled:true}')" >/dev/null

# ---- 3. data-plane containers -------------------------------------------------------------------------

log "isolating $WAN_CIDR <-> $SL_CIDR in DOCKER-USER"
isolate_apply

log "starting the rest of the stack (RELAY=$RELAY)"
export NEWT_ID NEWT_SECRET OLM_ID OLM_SECRET
docker compose -p pg up -d >/dev/null

# ---- 4. wait for both paths ---------------------------------------------------------------------------

poll "public path (loadgen -> traefik -> site -> target)" 300 check_public
poll "private path (client-tools -> olm -> site -> target)" 300 check_private
poll "olm path mode (RELAY=$RELAY)" 120 check_mode

# ---- 5. smoke checks (short, correctness only: not benchmarks) ------------------------------------------

log "smoke: ICMP"
docker exec "$CLIENT_TOOLS" ping -c 3 -W 3 "$TARGET_IP" | tail -2 >&2
log "smoke: rtt udp / tcp"
docker exec "$CLIENT_TOOLS" rtt udp -target "$TARGET_IP:7000" -duration 2s | jq -c '{mode,sent,received,loss_pct}' >&2
docker exec "$CLIENT_TOOLS" rtt tcp -target "$TARGET_IP:7001" -duration 2s | jq -c '{mode,sent,received,loss_pct}' >&2
log "smoke: iperf3 tcp / udp 100M"
docker exec "$CLIENT_TOOLS" iperf3 -c "$TARGET_IP" -t 2 | tail -3 >&2
docker exec "$CLIENT_TOOLS" iperf3 -c "$TARGET_IP" -u -b 100M -t 2 | tail -3 >&2
log "smoke: http private /1m"
docker exec "$CLIENT_TOOLS" curl -s -o /dev/null -w '%{http_code} %{size_download}\n' "http://$TARGET_IP/1m" >&2
log "smoke: http public /1k and /1m"
docker exec "$LOADGEN" sh -c "curl -sk --resolve app.bench.test:443:$GERBIL_WAN_IP -o /dev/null -w '%{http_code} %{size_download}\n' https://app.bench.test/1k; curl -sk --resolve app.bench.test:443:$GERBIL_WAN_IP -o /dev/null -w '%{http_code} %{size_download}\n' https://app.bench.test/1m" >&2

MODE_JSON=$(docker exec "$CLIENT_TOOLS" sh -c 'curl -s --max-time 3 http://127.0.0.1:9452/status' | jq -c '.peers | to_entries | map(.value | {endpoint,isRelay,connected})')
log "olm peers: $MODE_JSON"
log "UP OK: NET_ID=$NET_ID NAME_SUFFIX='$NAME_SUFFIX' RELAY=$RELAY (private + public paths verified)"
