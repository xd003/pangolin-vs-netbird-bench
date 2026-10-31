# Source me: `. bench/netbird/env.sh`. Must match the NET_ID/NAME_SUFFIX used by up.sh.
# Stack: NetBird 0.82.0, compose project "nb".
NET_ID="${NET_ID:-0}"
NAME_SUFFIX="${NAME_SUFFIX-}"
export NET_ID NAME_SUFFIX

export PRIVATE_TARGET="10.89.${NET_ID}.10"
export PUBLIC_HOST="app.bench.test"
export PUBLIC_IP="10.88.${NET_ID}.20"
export PUBLIC_RESOLVE="app.bench.test:443:10.88.${NET_ID}.20"

export NB_SERVER_CONTAINER="nb-server${NAME_SUFFIX}"
export PROXY_CONTAINER="nb-proxy${NAME_SUFFIX}"
export RELAY_CONTAINER="nb-server${NAME_SUFFIX}"
export SERVER_CONTAINERS="nb-server${NAME_SUFFIX} nb-proxy${NAME_SUFFIX}"
export SITE_CONTAINER="site${NAME_SUFFIX}"
export CLIENT_CONTAINER="client${NAME_SUFFIX}"
export CLIENT_TOOLS_CONTAINER="client-tools${NAME_SUFFIX}"
export LOADGEN_CONTAINER="loadgen${NAME_SUFFIX}"
export TARGET_CONTAINER="target${NAME_SUFFIX}"
