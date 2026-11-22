#!/usr/bin/env python3
import sys
v = 50.0
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if f[0] == "@hello": print("@hello\t1", flush=True)
    elif f[0] == "count":
        if len(f) > 2 and f[1] == "+": v += float(f[2])
        elif len(f) > 2 and f[1] == "=": v = float(f[2])
        v = max(0, min(100, v))
        print(f"count\t{v}", flush=True)
