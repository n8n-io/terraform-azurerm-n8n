#!/usr/bin/env python3
"""Exercise the planned exporter probes against a hanging local Redis peer.

Requires Terraform initialized at the module root and a redis_exporter binary
built from the module's pinned upstream version (passed as the first argument).
No Azure, Kubernetes, Docker daemon, or third-party Python packages are needed.
"""

import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request


def main():
    root = Path(__file__).resolve().parents[2]
    result = subprocess.run(
        ["terraform", "test", "-json", "-verbose",
         "-filter=tests/chart-values.tftest.hcl", "-var=redis_exporter_enabled=true"],
        cwd=root, capture_output=True, text=True, check=True,
    )
    events = [json.loads(line) for line in result.stdout.splitlines()]
    plan = next(e["test_plan"] for e in events
                if e.get("type") == "test_plan" and e.get("@testrun") == "multi_main")
    deployment = next(r["change"]["after"] for r in plan["resource_changes"]
                      if r["address"] == "kubernetes_deployment_v1.redis_exporter[0]")
    container = deployment["spec"][0]["template"][0]["spec"][0]["container"][0]
    binary = str(Path(sys.argv[1]).resolve())
    version = container["image"].rsplit(":", 1)[1]
    build = subprocess.check_output(["go", "version", "-m", binary], text=True)
    assert f"github.com/oliver006/redis_exporter\t{version}" in build, build

    # Accept TCP but never read or reply. Keeping sockets open distinguishes
    # the timeout failure from a fast connection-refused error.
    with socket.socket() as redis, socket.socket() as http:
        redis.bind(("127.0.0.1", 0))
        redis.listen()
        http.bind(("127.0.0.1", 0))
        port = http.getsockname()[1]
        http.close()
        accepted = threading.Event()
        stop = threading.Event()

        def hang():
            redis.settimeout(0.2)
            clients = []
            try:
                while not stop.is_set():
                    try:
                        client, _ = redis.accept()
                        clients.append(client)
                        accepted.set()
                    except socket.timeout:
                        pass
            finally:
                for client in clients:
                    client.close()

        thread = threading.Thread(target=hang)
        thread.start()
        env = {k: v for k, v in os.environ.items() if not k.startswith("REDIS_")}
        env.update({e["name"]: e["value"] for e in container["env"] if e.get("value")})
        env["REDIS_ADDR"] = f"redis://127.0.0.1:{redis.getsockname()[1]}"
        env["REDIS_EXPORTER_WEB_LISTEN_ADDRESS"] = f"127.0.0.1:{port}"

        def get(path, timeout):
            with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as response:
                return response.read().decode()

        with tempfile.TemporaryFile() as log:
            process = subprocess.Popen([binary], env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    try:
                        get("/health", 0.2)
                        break
                    except OSError:
                        time.sleep(0.05)
                else:
                    raise AssertionError("Exporter did not start")
                with concurrent.futures.ThreadPoolExecutor() as pool:
                    started = time.monotonic()
                    scrape = pool.submit(get, "/metrics", 10)
                    assert accepted.wait(2), "Scrape never contacted the hanging Redis peer"
                    for key in ("liveness_probe", "readiness_probe"):
                        probe = container[key][0]
                        assert get(probe["http_get"][0]["path"], 1).strip() == "ok"
                        assert not scrape.done(), "Redis fixture must still be hanging during probes"
                    metrics = scrape.result(timeout=10)
                    elapsed = time.monotonic() - started
                    assert "redis_up 0" in metrics.splitlines(), metrics
                    assert 2 <= elapsed < 10, f"Unexpected scrape duration: {elapsed:.2f}s"
                    assert process.poll() is None, "Exporter exited during Redis outage"
                    print(f"PASS: both planned probes respond during a stalled scrape; redis_up=0 in {elapsed:.2f}s")
            finally:
                # Release hanging Redis reads before waiting for the
                # exporter's graceful HTTP shutdown, including failed tests.
                stop.set()
                thread.join(timeout=2)
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
