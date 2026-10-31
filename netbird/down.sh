#!/bin/sh
# Tear the NetBird benchmark stack down completely: containers, networks and the
# named volumes of compose project "nb", the host DOCKER-USER isolation rules
# tagged bench-nb-isolate-<NET_ID> (only this NET_ID's rules), plus the generated
# host-side state/ directory. Safe to run when nothing is up.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
. ./env.sh

docker compose down -v --remove-orphans --timeout 20
rm -rf state

ISO_TAG="bench-nb-isolate-${NET_ID}"
docker run --rm --net=host --privileged alpine:3.22 sh -c '
  apk add -q iptables >/dev/null 2>&1 || exit 1
  iptables -S DOCKER-USER | grep -- "--comment $1" | sed "s/^-A /-D /" | while read -r r; do iptables $r; done
  ! iptables -S DOCKER-USER | grep -q -- "--comment $1"
' sh "$ISO_TAG" || echo "down.sh: could not remove DOCKER-USER rules tagged $ISO_TAG" >&2

_left=$(docker ps -aq --filter "label=com.docker.compose.project=nb"
  docker network ls -q --filter "label=com.docker.compose.project=nb"
  docker volume ls -q --filter "label=com.docker.compose.project=nb")
if [ -n "$(printf '%s' "$_left" | tr -d '[:space:]')" ]; then
  echo "down.sh: resources still present for project nb:" >&2
  docker ps -a --filter "label=com.docker.compose.project=nb" --format '  container {{.Names}}' >&2
  docker network ls --filter "label=com.docker.compose.project=nb" --format '  network {{.Name}}' >&2
  docker volume ls --filter "label=com.docker.compose.project=nb" --format '  volume {{.Name}}' >&2
  exit 1
fi
echo "down.sh: nb stack removed (containers, networks, volumes, $ISO_TAG rules); state/ cleared" >&2
