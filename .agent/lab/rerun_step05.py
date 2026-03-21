import json
import time
import urllib.request

BASE = "http://167.86.69.250:3000"
TOKEN = "ad523da5c086098ca5ac3afb"


def post(path, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        BASE + path,
        data=data,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {TOKEN}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.status, json.loads(resp.read().decode() or "{}")


def get_status():
    req = urllib.request.Request(
        BASE + "/api/status",
        headers={"Authorization": f"Bearer {TOKEN}"},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode() or "{}")

print("RUN05", post("/api/steps/05-core-services/run", {}))
for i in range(30):
    time.sleep(10)
    st = get_status()
    m = {s["id"]: s["status"] for s in st.get("steps", [])}
    print(f"T+{(i+1)*10}s", m.get("05-core-services"), m.get("06-source-repos"), m.get("11-finalize"))
    if m.get("05-core-services") in ("done", "error"):
        break

print("FINAL", get_status().get("steps", []))
