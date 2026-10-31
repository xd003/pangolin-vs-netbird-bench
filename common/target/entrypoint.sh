#!/bin/sh
iperf3 -s -p 5201 -D
iperf3 -s -p 5202 -D
nginx
exec rtt server -udp :7000 -tcp :7001
