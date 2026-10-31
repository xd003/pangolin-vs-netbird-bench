#!/usr/bin/env python3
"""Render results/*.json into REPORT tables (markdown on stdout)."""
import glob
import json
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
ORDER = ["baseline-default", "pangolin-default", "pangolin-relay", "netbird-default", "netbird-relay",
         "netbird-userspace", "netbird-userspace-relay"]


def load():
    runs = {}
    for f in glob.glob(os.path.join(ROOT, "results", "*.json")):
        r = json.load(open(f))
        runs[(f"{r['stack']}-{r['variant']}", r["profile"])] = r
    return runs


def g(d, *path, fmt="{:.0f}"):
    for p in path:
        if not isinstance(d, dict) or p not in d or d[p] is None:
            return "–"
        d = d[p]
    if "error" in path[-1:]:
        return str(d)
    return fmt.format(d)


def err(d, k):
    v = d.get(k, {}) if d else {}
    return "ERR" if isinstance(v, dict) and "error" in v else None


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def main():
    runs = load()
    profiles = sorted({p for _, p in runs})
    keys = [k for k in ORDER if any((k, p) in runs for p in profiles)]
    for prof in profiles:
        rs = [(k, runs[(k, prof)]) for k in keys if (k, prof) in runs]
        print(f"\n## Profile: {prof}\n")
        print("### Private path throughput (Mbit/s, median of reps)\n")
        rows = []
        for k, r in rs:
            T = r["private"]
            rows.append([k] + [err(T, t) or g(T, t, "mbps") for t in ("tcp_up_1", "tcp_down_1", "tcp_up_4", "tcp_down_4")]
                        + [err(T, "http_100m") or g(T, "http_100m", "mbps_total")]
                        + [g(T, "tcp_down_1", "retransmits")])
        print(table(["config", "TCP up 1", "TCP down 1", "TCP up 4", "TCP down 4", "HTTP 100MB", "retrans (down 1)"], rows))

        print("\n### Private path UDP (achieved Mbit/s / loss % / jitter ms)\n")
        rows = []
        for k, r in rs:
            T = r["private"]
            row = [k]
            for t in ("udp_up_100M", "udp_up_500M", "udp_up_1G", "udp_down_1G"):
                row.append(err(T, t) or f"{g(T, t, 'mbps')} / {g(T, t, 'lost_pct', fmt='{:.2f}')} / {g(T, t, 'jitter_ms', fmt='{:.3f}')}")
            rows.append(row)
        print(table(["config", "up 100M", "up 500M", "up 1G", "down 1G"], rows))

        print("\n### Private path latency (ms)\n")
        rows = []
        f2 = "{:.3f}"
        for k, r in rs:
            T = r["private"]
            rows.append([k,
                         g(T, "ping", "avg_ms", fmt=f2), g(T, "ping", "mdev_ms", fmt=f2),
                         g(T, "rtt_udp_idle", "p50_ms", fmt=f2), g(T, "rtt_udp_idle", "p99_ms", fmt=f2), g(T, "rtt_udp_idle", "jitter_ms", fmt=f2),
                         g(T, "rtt_tcp_idle", "p50_ms", fmt=f2), g(T, "rtt_tcp_idle", "p99_ms", fmt=f2),
                         g(T, "tcp_connect", "p50_ms", fmt=f2),
                         g(T, "rtt_udp_under_load", "p50_ms", fmt=f2), g(T, "rtt_udp_under_load", "p99_ms", fmt=f2),
                         g(T, "rtt_udp_under_load", "jitter_ms", fmt=f2), g(T, "rtt_udp_under_load", "loss_pct", fmt="{:.1f}")])
        print(table(["config", "ICMP avg", "ICMP mdev", "UDP p50", "UDP p99", "UDP jitter", "TCP p50", "TCP p99",
                     "connect p50", "loaded p50", "loaded p99", "loaded jitter", "loaded loss %"], rows))

        print("\n### Private path HTTP (target nginx, 1 KiB)\n")
        rows = []
        for k, r in rs:
            T = r["private"]
            rows.append([k, g(T, "http_1k_c1", "rps"), g(T, "http_1k_c1", "p99_ms", fmt=f2),
                         g(T, "http_1k_c64", "rps"), g(T, "http_1k_c64", "p50_ms", fmt=f2), g(T, "http_1k_c64", "p99_ms", fmt=f2),
                         g(T, "http_1k_c64", "success_rate", fmt="{:.4f}")])
        print(table(["config", "c1 req/s", "c1 p99", "c64 req/s", "c64 p50", "c64 p99", "c64 success"], rows))

        if any("public" in r for _, r in rs):
            print("\n### Public HTTPS reverse-proxy path\n")
            rows = []
            for k, r in rs:
                P = r.get("public")
                if not P:
                    continue
                rows.append([k, g(P, "https_1k_c1", "rps"), g(P, "https_1k_c1", "p50_ms", fmt=f2), g(P, "https_1k_c1", "p99_ms", fmt=f2),
                             g(P, "https_1k_c64", "rps"), g(P, "https_1k_c64", "p50_ms", fmt=f2), g(P, "https_1k_c64", "p99_ms", fmt=f2),
                             g(P, "https_1k_c64", "success_rate", fmt="{:.4f}"),
                             err(P, "https_100m") or g(P, "https_100m", "mbps_total"), err(P, "https_100m_x4") or g(P, "https_100m_x4", "mbps_total"),
                             g(P, "https_1k_c64", "resources", "total_cpu_s", fmt="{:.1f}")])
            print(table(["config", "c1 req/s", "c1 p50", "c1 p99", "c64 req/s", "c64 p50", "c64 p99", "c64 success",
                         "100MB Mbit/s", "4x100MB Mbit/s", "CPU-s (c64, 15s)"], rows))

        print("\n### Resources\n")
        rows = []
        for k, r in rs:
            T = r["private"]
            idle = {c: v for c, v in r["idle"]["containers"].items() if c not in ("client-tools", "target", "loadgen")}
            idle_cpu = sum(v["cpu_cores"] for v in idle.values()) * 1000
            idle_mem = sum(v["mem_avg_mb"] for v in idle.values())
            busy = T.get("tcp_down_4", {}).get("resources", {}).get("containers", {})
            per = ", ".join(f"{c}: {v['cpu_cores']:.2f}c/{v['mem_peak_mb']:.0f}MB" for c, v in busy.items() if c not in ("client-tools", "target", "loadgen"))
            rows.append([k, f"{idle_cpu:.1f}", f"{idle_mem:.0f}",
                         g(T, "tcp_down_4", "cpu_s_per_gb", fmt="{:.2f}"), g(T, "tcp_down_4", "system_cpu_s_per_gb", fmt="{:.2f}"),
                         g(T, "udp_up_500M", "cpu_s_per_gb", fmt="{:.2f}"), g(T, "udp_up_500M", "system_cpu_s_per_gb", fmt="{:.2f}"), per])
        print(table(["config", "idle CPU (millicores, product)", "idle mem MB (product)", "TCP down x4: product CPU-s/GB",
                     "TCP down x4: system CPU-s/GB", "UDP 500M: product CPU-s/GB", "UDP 500M: system CPU-s/GB",
                     "under TCP down x4: cores / peak mem"], rows))

        print("\n### Ops\n")
        rows = []
        for k, r in rs:
            T = r["private"]
            rec = T.get("client_restart_to_reachable_s")
            rows.append([k, g(r, "up_s", fmt="{:.0f}"),
                         " / ".join("–" if x is None else f"{x:.1f}" for x in rec) if rec else "–",
                         f"{sum(v['size_mb'] for v in r['images'].values()):.0f}",
                         ", ".join(f"{c}={v['size_mb']:.0f}" for c, v in r["images"].items())])
        print(table(["config", "up.sh s", "client restart → reachable s", "image MB (sum)", "images"], rows))


if __name__ == "__main__":
    main()
