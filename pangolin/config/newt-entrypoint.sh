#!/bin/sh
# Bench wrapper for newt. The site container is dual-homed (wan = default route, sitelan = connected-only).
# Report only the default-route (wan) interface as local endpoint. Clients live on wan, so advertising the
# sitelan address would make olm probe an address it cannot reach (sitelan is not routable from wan).
LOCAL_ENDPOINT_INTERFACES=$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route)
export LOCAL_ENDPOINT_INTERFACES
exec newt "$@"
