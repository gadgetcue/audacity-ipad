"""Reads `simctl list devices available -j` on stdin, prints the UDID of the best iPhone or iPad."""
import json
import re
import sys

kind = sys.argv[1]
data = json.load(sys.stdin)["devices"]


def ver(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


best = None
for rt in sorted((r for r in data if "iOS" in r), key=ver):
    for d in data[rt]:
        n = d["name"]
        if kind == "iphone" and n.startswith("iPhone") and "Pro" in n and "Max" not in n:
            best = d
        elif kind == "ipad" and n.startswith("iPad Pro") and "13" in n:
            best = d
if best is None:
    for rt in sorted((r for r in data if "iOS" in r), key=ver):
        for d in data[rt]:
            if d["name"].lower().startswith(kind):
                best = d
print(best["udid"] if best else "")
