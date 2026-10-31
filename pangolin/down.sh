#!/bin/sh
# Tear down the Pangolin bench stack completely: compose project `pg` (containers, networks, volumes),
# the DOCKER-USER isolation rules added by up.sh, and all generated state (state/).
set -u
cd "$(dirname "$0")"
export NET_ID="${NET_ID:-0}"
export NAME_SUFFIX="${NAME_SUFFIX:-}"

docker compose -p pg down -v --remove-orphans

# Remove every isolation rule up.sh added (tagged bench-pg-isolate-<NET_ID>); the OrbStack VM firewall must not keep them.
docker run --rm -i --privileged --net=host alpine:3.22 sh -s <<'EOS' >/dev/null 2>&1 || echo "down.sh: warning: could not clean DOCKER-USER isolation rules" >&2
set -e
apk add -q --no-cache iptables >/dev/null
iptables -S DOCKER-USER | grep 'bench-pg-isolate' | sed 's/^-A DOCKER-USER //' | while read -r rule; do
    iptables -D DOCKER-USER $rule
done
EOS

rm -rf state
echo "pangolin bench: down (project pg, NET_ID=${NET_ID}, NAME_SUFFIX=${NAME_SUFFIX})"
