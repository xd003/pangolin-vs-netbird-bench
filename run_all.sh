#!/bin/bash
# Run every stack/variant/profile sequentially (only one stack up at a time).
cd "$(dirname "$0")"
runs=(
  "baseline default"
  "pangolin default"
  "pangolin relay"
  "netbird default"
  "netbird relay"
  "netbird userspace"
)
for profile in lan wan; do
  for r in "${runs[@]}"; do
    set -- $r
    [ -f "results/$1-$2-$profile.json" ] && [ -z "$FORCE" ] && continue
    python3 run.py "$1" "$2" "$profile" || echo "FAILED $1 $2 $profile"
  done
done
