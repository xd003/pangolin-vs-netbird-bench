FROM bench-rtt AS rtt
FROM alpine:3.22
RUN apk add --no-cache iperf3 curl iputils iproute2 iptables bind-tools jq bash coreutils
ARG OHA_VERSION=1.16.0
ARG TARGETARCH
RUN curl -fsSL -o /usr/local/bin/oha https://github.com/hatoo/oha/releases/download/v${OHA_VERSION}/oha-linux-${TARGETARCH} \
 && chmod +x /usr/local/bin/oha
COPY --from=rtt /rtt /usr/local/bin/rtt
CMD ["sleep", "infinity"]
