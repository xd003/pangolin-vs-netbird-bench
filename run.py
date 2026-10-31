#!/usr/bin/env python3
"""Tunnel benchmark runner.

usage: run.py <stack> <variant> <profile> [--skip-up] [--keep]
  stack:   baseline | pangolin | netbird
  variant: label; env for up.sh is taken from VARIANTS
  profile: lan | wan   (wan = netem 15ms egress delay on client and site wan ifaces)

Writes results/<stack>-<variant>-<profile>.json
"""
import http.client
import json
import os
import socket
import statistics
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
REPS = int(os.environ.get("REPS", "3"))
TP_SECS = int(os.environ.get("TP_SECS", "10"))

VARIANTS = {
    "default": {},
    "relay": {"RELAY": "1"},
    "userspace": {"WG_USERSPACE": "1"},
    "userspace-relay": {"WG_USERSPACE": "1", "RELAY": "1"},
}
PROFILES = {
    "lan": None,
    "wan": "delay 15ms",
}


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def sh(cmd, check=True, timeout=600, env=None):
    p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout, env=env)
    if check and p.returncode != 0:
        raise RuntimeError(f"cmd failed ({p.returncode}): {cmd}\n{p.stdout[-2000:]}\n{p.stderr[-2000:]}")
    return p.stdout


def dexec(container, *args, timeout=600, check=True):
    return sh(["docker", "exec", container, *args], timeout=timeout, check=check)


# ---------- docker API (cgroup CPU / memory accounting) ----------

def _docker_sock():
    for p in (os.path.expanduser("~/.orbstack/run/docker.sock"), "/var/run/docker.sock"):
        if os.path.exists(p):
            return p
    raise RuntimeError("docker socket not found")


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=30)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)


def docker_api(path):
    c = UnixHTTP(_docker_sock())
    c.request("GET", path)
    r = c.getresponse()
    body = r.read()
    c.close()
    return json.loads(body)


def container_exists(name):
    try:
        return docker_api(f"/containers/{name}/json")["State"]["Running"]
    except Exception:
        return False


def cstat(name):
    s = docker_api(f"/containers/{name}/stats?stream=false&one-shot=true")
    mem = s["memory_stats"]
    st = mem.get("stats", {})
    # docker CLI semantics on cgroup v2: usage - inactive_file
    used = mem.get("usage", 0) - st.get("inactive_file", 0)
    return {"cpu_ns": s["cpu_stats"]["cpu_usage"]["total_usage"], "mem": used}


GENERATORS = ("client-tools", "target", "loadgen")


def vm_busy_s():
    """VM-wide busy CPU seconds from /proc/stat (not namespaced). Captures in-kernel
    work (kernel WireGuard crypto in kworkers, softirq) that no container cgroup is charged for."""
    line = dexec("target", "head", "-1", "/proc/stat").split()
    user, nice, system, idle, iowait, irq, softirq, steal = (int(x) for x in line[1:9])
    return (user + nice + system + irq + softirq + steal) / os.sysconf("SC_CLK_TCK")


class ResourceMonitor:
    """CPU-seconds via cgroup counters (start/stop delta), memory sampled ~1Hz (peak + avg).
    Load generators are tracked too so they can be subtracted from VM-wide CPU."""

    def __init__(self, containers):
        self.containers = list(dict.fromkeys(list(containers) + [g for g in GENERATORS if container_exists(g)]))
        self.product = [c for c in containers if c not in GENERATORS]
        self.samples = {c: [] for c in self.containers}
        self._stop = threading.Event()

    def __enter__(self):
        self.t0 = time.time()
        self.vm0 = vm_busy_s()
        self.start = {c: cstat(c) for c in self.containers}
        self.th = threading.Thread(target=self._loop, daemon=True)
        self.th.start()
        return self

    def _loop(self):
        while not self._stop.wait(1.0):
            for c in self.containers:
                try:
                    self.samples[c].append(cstat(c)["mem"])
                except Exception:
                    pass

    def __exit__(self, *exc):
        self._stop.set()
        self.th.join()
        end = {c: cstat(c) for c in self.containers}
        vm = vm_busy_s() - self.vm0
        wall = time.time() - self.t0
        self.result = {"wall_s": wall, "containers": {}}
        for c in self.containers:
            mem = self.samples[c] + [end[c]["mem"]]
            cpu_s = (end[c]["cpu_ns"] - self.start[c]["cpu_ns"]) / 1e9
            self.result["containers"][c] = {
                "cpu_s": cpu_s,
                "cpu_cores": cpu_s / wall,
                "mem_avg_mb": statistics.mean(mem) / 2**20,
                "mem_peak_mb": max(mem) / 2**20,
            }
        cs = self.result["containers"]
        self.result["total_cpu_s"] = sum(cs[c]["cpu_s"] for c in self.product)
        gen = sum(cs[c]["cpu_s"] for c in cs if c in GENERATORS)
        self.result["vm_cpu_s"] = vm
        # everything the VM burned except the traffic generators/sinks: product userspace + kernel datapath
        self.result["system_cpu_s"] = vm - gen
        return False


# ---------- tests ----------

def iperf_tcp(tools, target, reverse=False, streams=1, secs=TP_SECS, port=5201):
    args = ["iperf3", "-c", target, "-p", str(port), "-t", str(secs), "-J", "-O", "1", "-P", str(streams)]
    if reverse:
        args.append("-R")
    j = json.loads(dexec(tools, *args, timeout=secs + 60))
    e = j["end"]
    return {
        "mbps": e["sum_received"]["bits_per_second"] / 1e6,
        "retransmits": e["sum_sent"].get("retransmits"),
        "bytes": e["sum_received"]["bytes"],
    }


def iperf_udp(tools, target, rate, reverse=False, secs=TP_SECS, length=1200):
    args = ["iperf3", "-c", target, "-u", "-b", rate, "-l", str(length), "-w", "4M", "-t", str(secs), "-J", "-O", "1"]
    if reverse:
        args.append("-R")
    j = json.loads(dexec(tools, *args, timeout=secs + 60))
    e = j["end"]
    s = e.get("sum_received") or e["sum"]
    return {
        "target_rate": rate,
        "mbps": s["bits_per_second"] / 1e6,
        "jitter_ms": s.get("jitter_ms"),
        "lost_pct": s.get("lost_percent"),
        "bytes": s.get("bytes"),
    }


def rtt(tools, mode, target, secs=20, rate=100):
    if mode == "connect":
        out = dexec(tools, "rtt", "connect", "-target", target, "-count", str(secs * 10), "-rate", "20", timeout=secs * 3 + 60)
    else:
        out = dexec(tools, "rtt", mode, "-target", target, "-duration", f"{secs}s", "-rate", str(rate), timeout=secs + 60)
    return json.loads(out)


def ping(tools, target, count=500):
    out = dexec(tools, "ping", "-q", "-i", "0.02", "-c", str(count), "-W", "2", target, check=False, timeout=count * 0.05 + 60)
    res = {"raw": out.strip().splitlines()[-2:]}
    for line in out.splitlines():
        if "packet loss" in line:
            res["loss_pct"] = float(line.split("%")[0].split()[-1])
        if line.startswith("rtt") or line.startswith("round-trip"):
            mn, avg, mx, mdev = line.split("=")[1].split()[0].split("/")
            res.update(min_ms=float(mn), avg_ms=float(avg), max_ms=float(mx), mdev_ms=float(mdev))
    return res


def oha(tools, url, conc, secs, resolve=None, http2=False):
    args = ["oha", "--no-tui", "--output-format", "json", "-z", f"{secs}s", "-c", str(conc), "--insecure"]
    if resolve:
        host, port, ip = resolve.split(":")
        args += ["--connect-to", f"{host}:{port}:{ip}:{port}"]
    if http2:
        args.append("--http2")
    args.append(url)
    j = json.loads(dexec(tools, *args, timeout=secs + 120))
    s, p = j["summary"], j["latencyPercentiles"]
    codes = j.get("statusCodeDistribution", {})
    return {
        "rps": s["requestsPerSec"],
        "success_rate": s["successRate"],
        "p50_ms": p["p50"] * 1e3 if p.get("p50") is not None else None,
        "p90_ms": p["p90"] * 1e3 if p.get("p90") is not None else None,
        "p99_ms": p["p99"] * 1e3 if p.get("p99") is not None else None,
        "status": codes,
        "errors": j.get("errorDistribution", {}),
    }


def curl_dl(tools, url, resolve=None, parallel=1):
    r = ["--resolve", resolve] if resolve else []
    cmd = " & ".join(
        [f"curl -sk {' '.join(r)} -o /dev/null -w '%{{speed_download}} %{{size_download}}\\n' {url}"] * parallel
    ) + " & wait"
    out = dexec(tools, "sh", "-c", cmd, timeout=600)
    vals = [line.split() for line in out.strip().splitlines()]
    return {
        "mbps_total": sum(float(v[0]) for v in vals) * 8 / 1e6,
        "bytes": sum(int(float(v[1])) for v in vals),
    }


def median_of(fn, reps=REPS, key="mbps"):
    runs = [fn() for _ in range(reps)]
    runs_sorted = sorted(runs, key=lambda r: r[key])
    med = dict(runs_sorted[len(runs_sorted) // 2])
    med["all"] = [round(r[key], 1) for r in runs]
    med["bytes"] = sum(r["bytes"] for r in runs)  # all reps: matches the resource window
    return med


def measured(name, containers, fn, results, bytes_key="bytes"):
    log("  ", name)
    with ResourceMonitor(containers) as mon:
        try:
            r = fn()
        except Exception as e:  # keep going; record failure
            r = {"error": str(e)[-500:]}
    r["resources"] = mon.result
    b = r.get(bytes_key) if isinstance(r, dict) else None
    if b:
        r["cpu_s_per_gb"] = mon.result["total_cpu_s"] / (b / 1e9)
        r["system_cpu_s_per_gb"] = mon.result["system_cpu_s"] / (b / 1e9)
        r["vm_cpu_s_per_gb"] = mon.result["vm_cpu_s"] / (b / 1e9)
    results[name] = r
    return r


# ---------- netem ----------

def wan_iface(container, prefix):
    out = sh(["docker", "run", "--rm", "--net", f"container:{container}", "bench-tools", "ip", "-o", "-4", "addr"])
    for line in out.splitlines():
        parts = line.split()
        if parts[3].startswith(prefix):
            return parts[1]
    raise RuntimeError(f"no {prefix} iface in {container}: {out}")


def netem(container, prefix, spec):
    iface = wan_iface(container, prefix)
    sh(["docker", "run", "--rm", "--net", f"container:{container}", "--cap-add", "NET_ADMIN", "bench-tools",
        "tc", "qdisc", "replace", "dev", iface, "root", "netem", *spec.split()])
    log(f"netem {spec} on {container}:{iface}")


# ---------- main ----------

def load_env(stack):
    out = sh(["bash", "-c", f"source {ROOT}/{stack}/env.sh && env"])
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def wait_reachable(tools, target, timeout=120):
    t0 = time.time()
    while time.time() - t0 < timeout:
        p = subprocess.run(["docker", "exec", tools, "rtt", "connect", "-target", target, "-count", "1"],
                           capture_output=True, text=True)
        try:
            if json.loads(p.stdout)["received"] == 1:
                return time.time() - t0
        except Exception:
            pass
        time.sleep(0.2)
    return None


def main():
    stack, variant, profile = sys.argv[1:4]
    flags = sys.argv[4:]
    sdir = os.path.join(ROOT, stack)
    env = dict(os.environ, NET_ID="0", NAME_SUFFIX="", **VARIANTS[variant])
    res = {"stack": stack, "variant": variant, "profile": profile, "started": time.strftime("%Y-%m-%dT%H:%M:%S")}

    if "--skip-up" not in flags:
        log(f"== {stack}/{variant}/{profile}: down + up")
        subprocess.run(["bash", "./down.sh"], cwd=sdir, env=env, capture_output=True)
        t0 = time.time()
        p = subprocess.run(["bash", "./up.sh"], cwd=sdir, env=env, capture_output=True, text=True)
        res["up_s"] = time.time() - t0
        if p.returncode != 0:
            raise SystemExit(f"up failed:\n{p.stdout[-3000:]}\n{p.stderr[-3000:]}")
    e = load_env(stack)
    tgt = e["PRIVATE_TARGET"]
    tools = "client-tools"
    stack_containers = e["SERVER_CONTAINERS"].split() + [e["SITE_CONTAINER"], e["CLIENT_CONTAINER"]]
    stack_containers = list(dict.fromkeys(stack_containers))
    res["containers"] = stack_containers
    res["env"] = {k: e[k] for k in ("PRIVATE_TARGET", "PUBLIC_HOST", "PUBLIC_RESOLVE") if k in e}

    # OrbStack routes between bridge networks even with `internal: true`, so a wan
    # container could reach the target without the tunnel. Drop everything arriving
    # via the sitelan bridge gateway; only on-link sitelan peers (site) remain.
    gw = tgt.rsplit(".", 1)[0] + ".1"
    sh(["docker", "run", "--rm", "--net", "container:target", "--cap-add", "NET_ADMIN", "bench-tools",
        "iptables", "-I", "INPUT", "-s", gw, "-j", "DROP"])
    if container_exists("loadgen"):
        p = subprocess.run(["docker", "exec", "loadgen", "rtt", "connect", "-target", f"{tgt}:7001", "-count", "2"],
                           capture_output=True, text=True)
        assert json.loads(p.stdout)["received"] == 0, "target reachable from wan without tunnel"

    # image info
    res["images"] = {}
    for c in stack_containers:
        info = docker_api(f"/containers/{c}/json")
        img = docker_api(f"/images/{info['Image']}/json")
        res["images"][c] = {"image": info["Config"]["Image"], "size_mb": img["Size"] / 2**20}

    # tunnel MTU as seen from the client netns
    res["client_links"] = dexec(tools, "ip", "-o", "link", check=False)

    if PROFILES[profile]:
        wan_prefix = e.get("WAN_PREFIX", "10.88.0.")
        netem(e["CLIENT_CONTAINER"], wan_prefix, PROFILES[profile])
        netem(e["SITE_CONTAINER"], wan_prefix, PROFILES[profile])

    log("settle + idle")
    time.sleep(20)
    r = {}
    measured("idle_60s", stack_containers, lambda: time.sleep(60) or {}, r)
    res["idle"] = r["idle_60s"]["resources"]

    T = {}
    res["private"] = T
    log("private path")
    T["reach_s"] = wait_reachable(tools, f"{tgt}:7001")
    T["ping"] = ping(tools, tgt)
    measured("rtt_udp_idle", stack_containers, lambda: rtt(tools, "udp", f"{tgt}:7000"), T)
    measured("rtt_tcp_idle", stack_containers, lambda: rtt(tools, "tcp", f"{tgt}:7001"), T)
    measured("tcp_connect", stack_containers, lambda: rtt(tools, "connect", f"{tgt}:80", secs=10), T)
    measured("tcp_up_1", stack_containers, lambda: median_of(lambda: iperf_tcp(tools, tgt)), T)
    measured("tcp_down_1", stack_containers, lambda: median_of(lambda: iperf_tcp(tools, tgt, reverse=True)), T)
    measured("tcp_up_4", stack_containers, lambda: median_of(lambda: iperf_tcp(tools, tgt, streams=4)), T)
    measured("tcp_down_4", stack_containers, lambda: median_of(lambda: iperf_tcp(tools, tgt, reverse=True, streams=4)), T)
    for rate in ("100M", "500M", "1G"):
        measured(f"udp_up_{rate}", stack_containers, lambda rate=rate: iperf_udp(tools, tgt, rate), T)
        measured(f"udp_down_{rate}", stack_containers, lambda rate=rate: iperf_udp(tools, tgt, rate, reverse=True), T)

    def loaded():
        bg = subprocess.Popen(["docker", "exec", tools, "iperf3", "-c", tgt, "-p", "5202", "-R", "-P", "4", "-t", "30"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(4)
        try:
            return rtt(tools, "udp", f"{tgt}:7000", secs=20)
        finally:
            bg.wait()
    measured("rtt_udp_under_load", stack_containers, loaded, T)

    measured("http_1k_c1", stack_containers, lambda: oha(tools, f"http://{tgt}/1k", 1, 15), T)
    measured("http_1k_c64", stack_containers, lambda: oha(tools, f"http://{tgt}/1k", 64, 15), T)
    measured("http_100m", stack_containers, lambda: median_of(lambda: curl_dl(tools, f"http://{tgt}/100m"), key="mbps_total"), T)

    # reconnect: restart client container, time until target reachable again
    if stack != "baseline":
        rec = []
        for _ in range(3):
            # stop, then time from start: daemon boot + login + peer/tunnel setup
            sh(["docker", "stop", "-t", "5", e["CLIENT_CONTAINER"]])
            sh(["docker", "stop", "-t", "0", tools])
            t0 = time.time()
            sh(["docker", "start", e["CLIENT_CONTAINER"]])
            # client-tools shares the client's netns; rejoin the new netns
            sh(["docker", "start", tools])
            d = wait_reachable(tools, f"{tgt}:7001", timeout=180)
            rec.append(None if d is None else time.time() - t0)
            if PROFILES[profile]:
                netem(e["CLIENT_CONTAINER"], e.get("WAN_PREFIX", "10.88.0."), PROFILES[profile])
            time.sleep(10)
        T["client_restart_to_reachable_s"] = rec

    # public reverse proxy path
    if e.get("PUBLIC_RESOLVE"):
        P = {}
        res["public"] = P
        log("public path")
        lg = "loadgen"
        url = f"https://{e['PUBLIC_HOST']}"
        rs = e["PUBLIC_RESOLVE"]
        if PROFILES[profile]:
            netem(lg, e.get("WAN_PREFIX", "10.88.0."), PROFILES[profile])
        pub_containers = list(dict.fromkeys(e["SERVER_CONTAINERS"].split() + [e["SITE_CONTAINER"]]))
        measured("https_1k_c1", pub_containers, lambda: oha(lg, f"{url}/1k", 1, 15, resolve=rs), P)
        measured("https_1k_c64", pub_containers, lambda: oha(lg, f"{url}/1k", 64, 15, resolve=rs), P)
        measured("https_100m", pub_containers, lambda: median_of(lambda: curl_dl(lg, f"{url}/100m", resolve=rs), key="mbps_total"), P)
        measured("https_100m_x4", pub_containers, lambda: median_of(lambda: curl_dl(lg, f"{url}/100m", resolve=rs, parallel=4), key="mbps_total"), P)

    out = os.path.join(ROOT, "results", f"{stack}-{variant}-{profile}.json")
    with open(out, "w") as f:
        json.dump(res, f, indent=1)
    log("wrote", out)
    if "--keep" not in flags:
        subprocess.run(["bash", "./down.sh"], cwd=sdir, env=env, capture_output=True)


if __name__ == "__main__":
    main()
