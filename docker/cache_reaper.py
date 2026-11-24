"""Cache reaper: wipe vLLM's caches after CACHE_IDLE_MINUTES without requests, wake it on the next one.

Runs in its own container on the internal network, next to vLLM. Standard library only.
- nginx calls GET /ensure-awake (via auth_request, after the key check) before every API request. That records
  activity and, if the caches were released, wakes vLLM and holds the request until it's ready.
- Every CHECK_SECONDS it checks vLLM's own counters. After CACHE_IDLE_MINUTES with no running or waiting
  requests it resets the prefix and image caches, pauses the engine (vLLM requires it) and releases the KV
  cache memory back to the box. Weights stay loaded, so waking (~1.2 s measured) only re-reserves the KV cache.
- /health is never routed here, so health checks don't count as activity.
CACHE_IDLE_MINUTES=0 disables releasing; /ensure-awake then just answers 204.
"""
import http.server
import json
import os
import re
import threading
import time
import urllib.error
import urllib.request

VLLM = os.environ.get("VLLM_URL", "http://vllm:8000")
IDLE_SECONDS = float(os.environ.get("CACHE_IDLE_MINUTES", "15")) * 60
CHECK_SECONDS = float(os.environ.get("CHECK_SECONDS", "30"))
LISTEN_PORT = int(os.environ.get("PORT", "8090"))

lock = threading.Lock()  # serialises release and wake
state = {"released": False, "last_activity": time.time(), "releases": 0, "wakes": 0, "last_wake_s": None}


def log(msg):
    print(f"[{time.strftime('%Y-%m-%dT%H:%M:%S')}] {msg}", flush=True)


def call(method, path, timeout=600):
    req = urllib.request.Request(VLLM + path, method=method, data=b"" if method == "POST" else None)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def vllm_is_sleeping():
    try:
        return bool(json.loads(call("GET", "/is_sleeping", 10)).get("is_sleeping", False))
    except urllib.error.HTTPError as e:
        if e.code == 404:  # sleep mode not enabled (CACHE_IDLE_MINUTES=0)
            return False
        raise


def vllm_busy():
    text = call("GET", "/metrics", 10).decode()
    total = 0.0
    for name in ("vllm:num_requests_running", "vllm:num_requests_waiting"):
        total += sum(float(v) for v in re.findall(rf"^{re.escape(name)}(?:\{{[^}}]*\}})? ([0-9.eE+-]+)$", text, re.M))
    return total > 0


def ensure_awake():
    with lock:
        state["last_activity"] = time.time()
        if not state["released"]:
            return
        start = time.monotonic()
        call("POST", "/wake_up")  # re-reserves the KV cache; also un-pauses the scheduler when fully awake
        if json.loads(call("GET", "/is_paused", 10)).get("is_paused"):
            call("POST", "/resume")
        while vllm_is_sleeping():
            time.sleep(0.2)
        state.update(released=False, wakes=state["wakes"] + 1, last_wake_s=round(time.monotonic() - start, 2))
        log(f"woke vLLM in {state['last_wake_s']} s")


def reaper_loop():
    while True:
        time.sleep(CHECK_SECONDS)
        if IDLE_SECONDS <= 0:
            continue
        try:
            with lock:
                state["released"] = vllm_is_sleeping()  # resync (e.g. after a vLLM restart)
                if state["released"]:
                    continue
                if vllm_busy():  # long generations count as activity
                    state["last_activity"] = time.time()
                    continue
                idle = time.time() - state["last_activity"]
                if idle < IDLE_SECONDS:
                    continue
                call("POST", "/reset_prefix_cache")
                call("POST", "/reset_mm_cache")
                # vLLM only releases KV memory from a completed pause ("wait" lets anything in flight finish).
                call("POST", "/pause?mode=wait")
                try:
                    call("POST", "/release_kv_cache_memory")
                except Exception:
                    call("POST", "/resume")  # never leave the engine paused (it would 503 every request)
                    raise
                state.update(released=True, releases=state["releases"] + 1)
                log(f"idle {idle / 60:.1f} min: cleared prefix + image caches, released KV cache memory")
        except Exception as e:  # keep running; report and retry next tick
            log(f"check failed: {e!r}")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ensure-awake":
            try:
                ensure_awake()
                self.send_response(204)
                self.end_headers()
            except Exception as e:
                log(f"wake failed: {e!r}")
                self.send_response(503)
                self.end_headers()
        elif self.path == "/status":
            body = json.dumps({**state, "idle_seconds": round(time.time() - state["last_activity"]),
                               "cache_idle_minutes": IDLE_SECONDS / 60}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):  # nginx already logs every request
        pass


if __name__ == "__main__":
    log(f"cache reaper: release after {IDLE_SECONDS / 60:g} idle min (0 = never), checking every {CHECK_SECONDS:g} s")
    threading.Thread(target=reaper_loop, daemon=True).start()
    http.server.ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
