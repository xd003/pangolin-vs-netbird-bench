#!/bin/sh
# Bench wrapper for olm. RELAY=1 forces the relayed private path (BENCH_RELAY=1).
# Pangolin/olm have no relay-only switch: olm's DISABLE_HOLEPUNCH makes the server reject registration
# (HOLEPUNCH_MISSING), and DISABLE_RELAY disables relay. olm relays only after its direct hole-punch test to the
# site's public endpoint fails. So RELAY=1 emulates a client that cannot reach the site directly (NAT/firewall):
# a blackhole route for the site's wan address makes the direct probe fail, and olm then requests relay via gerbil
# through the product's own olm/wg/relay logic. olm<->gerbil stays reachable (different address).
if [ "${BENCH_RELAY:-0}" = "1" ] && [ -n "${BENCH_BLOCK_DIRECT_TO:-}" ]; then
    ip route replace blackhole "${BENCH_BLOCK_DIRECT_TO}/32"
fi
exec olm "$@"
