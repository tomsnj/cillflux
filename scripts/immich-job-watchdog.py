#!/usr/bin/env python3
"""Watch the Talos node while Immich chews through a bulk job, and pause
the queues if it gets hot enough to threaten the household services
(DNS, cameras, password manager) sharing this single node.

The load lands on `talos-iok-xpu`, NOT on gsfarmctl - immich-machine-
learning generating CLIP embeddings, immich-server orchestrating,
Postgres doing vector search, and NFS reads pulling originals off
TrueNAS. Watching the control host tells you nothing.

Emits only on state transitions so it does not flood a watching agent
or a terminal: armed, threshold crossings, the pause action, queue
completion, and errors. Silence means running normally.

Pausing is safe and lossless - the queue stops consuming and keeps its
backlog. Resume with:

    PUT /api/jobs/<queue>  {"command": "resume"}

Usage:
    scripts/immich-job-watchdog.py            # watches smartSearch + duplicateDetection

Tune WARN_CPU / PAUSE_CPU / QUEUES below for other jobs. Needs
~/.immich-api-key, and Prometheus reachable at prometheus.gs-farm.net
(so it needs this host's own resolver - see
scripts/setup-gsfarmctl-dns.sh).
"""
import json, os, sys, time, urllib.parse, urllib.request

PROM   = "https://prometheus.gs-farm.net"
IMMICH = "https://major.gs-farm.net"
KEY    = open(os.path.expanduser("~/.immich-api-key")).read().strip()
QUEUES = ["smartSearch", "duplicateDetection"]

WARN_CPU, PAUSE_CPU = 70.0, 85.0
PAUSE_SAMPLES = 3            # consecutive samples over PAUSE_CPU before acting
INTERVAL      = 15

def say(msg):
    print(msg, flush=True)

def prom(q):
    u = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": q})
    with urllib.request.urlopen(u, timeout=15) as r:
        res = json.load(r)["data"]["result"]
    return float(res[0]["value"][1]) if res else 0.0

def immich(path, method="GET", body=None):
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(IMMICH + path, data=data, method=method,
        headers={"x-api-key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None

def queue_state():
    j = immich("/api/jobs")
    out = {}
    for name in QUEUES:
        c = j[name]["jobCounts"]
        out[name] = (int(c.get("active", 0)) + int(c.get("waiting", 0)),
                     int(c.get("failed", 0)),
                     j[name]["queueStatus"].get("isPaused", False))
    return out

say(f"watchdog armed: pause at {PAUSE_CPU:.0f}% node CPU for "
    f"{PAUSE_SAMPLES} samples ({PAUSE_SAMPLES*INTERVAL}s), polling {INTERVAL}s")

hot = 0
warned = False
idle_rounds = 0
while True:
    try:
        cpu = prom('100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100)')
        rx  = prom('sum(rate(node_network_receive_bytes_total{device!~"lo|cilium.*|lxc.*"}[2m]))/1048576')
        tx  = prom('sum(rate(node_network_transmit_bytes_total{device!~"lo|cilium.*|lxc.*"}[2m]))/1048576')
        qs  = queue_state()
    except Exception as e:
        say(f"WATCHDOG ERROR polling: {e}")
        time.sleep(INTERVAL)
        continue

    pending = sum(v[0] for v in qs.values())
    line = (f"cpu={cpu:.0f}% net rx/tx={rx:.0f}/{tx:.0f} MB/s  "
            + "  ".join(f"{k}:{v[0]}" for k, v in qs.items()))

    if cpu >= PAUSE_CPU:
        hot += 1
        if hot >= PAUSE_SAMPLES:
            for name, (p, f, paused) in qs.items():
                if not paused:
                    try:
                        immich(f"/api/jobs/{name}", "PUT", {"command": "pause"})
                        say(f"PAUSED {name} - {line}")
                    except Exception as e:
                        say(f"FAILED TO PAUSE {name}: {e} - {line}")
            say("watchdog exiting after pause; resume manually when ready")
            sys.exit(0)
    else:
        hot = 0

    if cpu >= WARN_CPU and not warned:
        warned = True
        say(f"WARN node CPU over {WARN_CPU:.0f}% - {line}")
    elif cpu < WARN_CPU - 5 and warned:
        warned = False
        say(f"recovered below {WARN_CPU-5:.0f}% - {line}")

    if pending == 0:
        idle_rounds += 1
        if idle_rounds >= 2:
            say(f"DONE both queues drained - {line}")
            for k, v in qs.items():
                if v[1]: say(f"  {k} failed count: {v[1]}")
            sys.exit(0)
    else:
        idle_rounds = 0

    time.sleep(INTERVAL)
