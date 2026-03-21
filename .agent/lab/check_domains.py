import socket
import urllib.request

ua = {"User-Agent": "Mozilla/5.0"}
domains = [
    "kaanbal-console.automation.com.mx",
    "kaanbal-api.automation.com.mx",
    "api.automation.com.mx",
]

print("=== DNS ===")
for d in domains:
    try:
        print(d, "->", socket.gethostbyname_ex(d)[2])
    except Exception as e:
        print(d, "DNS_ERR", e)

print("\n=== HTTPS ===")
urls = [
    "https://kaanbal-console.automation.com.mx/",
    "https://kaanbal-console.automation.com.mx/api/v1/setup/status",
    "https://kaanbal-api.automation.com.mx/health",
]
for u in urls:
    try:
        req = urllib.request.Request(u, headers=ua)
        with urllib.request.urlopen(req, timeout=20) as r:
            b = r.read().decode("utf-8", "ignore")
            print(u, "->", r.status, "len", len(b))
            if "setup/status" in u:
                print("  body=", b)
    except Exception as e:
        print(u, "-> ERR", e)
