import re
import urllib.request
import http.cookiejar
import json

op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
op.addheaders = [("User-Agent", "Mozilla/5.0")]
pw = [l.strip().split("=", 1)[1] for l in open("/home/kia/dns/.env") if l.startswith("ADMIN_PASSWORD=")][0]
r = urllib.request.Request("http://127.0.0.1:3001/api/auth",
                           data=json.dumps({"password": pw}).encode(),
                           headers={"Content-Type": "application/json"})
b = json.load(op.open(r))
sid, csrf = b["session"]["sid"], b["session"]["csrf"]

js = op.open("http://127.0.0.1:3001/admin/scripts/js/index.js").read().decode(errors="replace")
i = js.find("stats/summary")
print(js[max(0, i - 400):i + 200].replace("\n", " ")[:700])
print("======")
# find how the base url is defined
m = re.findall(r"[a-zA-Z_]*[Bb]ase[Aa]url[^;]{0,80}", js)
print(m[:10])
