# Source from the benchmark runner (not executed): . ./env.sh
# Same NET_ID / NAME_SUFFIX as the stack was brought up with (defaults: final stack, NET_ID=0, no suffix).
export NET_ID="${NET_ID:-0}"
export NAME_SUFFIX="${NAME_SUFFIX:-}"
export RELAY="${RELAY:-0}"

export PRIVATE_TARGET="10.89.${NET_ID}.10"
export PUBLIC_HOST="app.bench.test"
export PUBLIC_RESOLVE="app.bench.test:443:10.88.${NET_ID}.5"

export SERVER_CONTAINERS="pg-pangolin${NAME_SUFFIX} pg-gerbil${NAME_SUFFIX} pg-traefik${NAME_SUFFIX}"
export SITE_CONTAINER="site${NAME_SUFFIX}"
export CLIENT_CONTAINER="client${NAME_SUFFIX}"
export CLIENT_TOOLS_CONTAINER="client-tools${NAME_SUFFIX}"
export LOADGEN_CONTAINER="loadgen${NAME_SUFFIX}"
export PROXY_CONTAINER="pg-traefik${NAME_SUFFIX}"
export RELAY_CONTAINER="pg-gerbil${NAME_SUFFIX}"
