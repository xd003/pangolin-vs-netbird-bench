#!/bin/sh
set -e
cd "$(dirname "$0")"
docker build -q -t bench-rtt rtt
docker build -q -t bench-target target
docker build -q -t bench-tools tools
