FROM bench-rtt AS rtt
FROM alpine:3.22
RUN apk add --no-cache iperf3 nginx iproute2 \
 && mkdir -p /srv/www \
 && echo ok > /srv/www/index.html \
 && head -c 1024 /dev/urandom > /srv/www/1k \
 && head -c 1048576 /dev/urandom > /srv/www/1m \
 && head -c 104857600 /dev/urandom > /srv/www/100m
COPY --from=rtt /rtt /usr/local/bin/rtt
COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
# iperf3 :5201, :5202 (parallel jobs), http :80, rtt udp :7000 / tcp :7001
CMD ["/bin/sh", "/entrypoint.sh"]
