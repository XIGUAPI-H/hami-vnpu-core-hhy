#!/usr/bin/env python3
import glob
import re
from pathlib import Path

KY = "/mnt/local/m00953550/FinalTest/kylin/logs"
results = []


def parse_thr(s):
    if not s:
        return None
    m = re.search(r"([\d.]+)", str(s))
    return float(m.group(1)) if m else None


for csv in sorted(glob.glob(f"{KY}/kylin_native_sweep_*.csv")):
    tag = Path(csv).stem
    rows = {}
    with open(csv) as f:
        for line in f.readlines()[1:]:
            p = line.strip().split(",")
            if len(p) < 11:
                continue
            scen, side, thr = p[0], p[6], parse_thr(p[10])
            if thr is None:
                continue
            rows.setdefault(scen, {})[side] = thr
    for scen, d in rows.items():
        if "opt" in d and "origin" in d and d["origin"] > 0:
            results.append(
                {
                    "ratio": d["opt"] / d["origin"],
                    "opt": d["opt"],
                    "origin": d["origin"],
                    "source": f"sweep_csv:{tag}:{scen}",
                }
            )

for txt in sorted(glob.glob(f"{KY}/kylin_native_sweep_*.txt")):
    text = Path(txt).read_text(encoding="utf-8", errors="ignore")
    scen = None
    for line in text.splitlines():
        if line.startswith(">>> scenario="):
            scen = line.split("scenario=")[1].split()[0]
        m = re.search(
            r"Throughput:\s*opt=([\d.]+\s*token/s)\s*origin=([\d.]+\s*token/s)\s*=>\s*winner=(\w+)",
            line,
        )
        if m:
            opt, orig = parse_thr(m.group(1)), parse_thr(m.group(2))
            if opt and orig and orig > 0:
                results.append(
                    {
                        "ratio": opt / orig,
                        "opt": opt,
                        "origin": orig,
                        "source": f"sweep_txt:{Path(txt).stem}:{scen}:winner={m.group(3)}",
                    }
                )

for txt in sorted(glob.glob(f"{KY}/perf_kylin*.txt")) + sorted(
    glob.glob("/mnt/local/compare_perf_kylin*.log")
):
    text = Path(txt).read_text(encoding="utf-8", errors="ignore")
    m = re.search(r"speedup_vs_origin:\s*([\d.]+)x", text)
    if m:
        ratio = float(m.group(1))
        opt_m = re.search(
            r"OutputTokenThroughput\s+([\d.]+\s*token/s)\s+([\d.]+\s*token/s)", text
        )
        opt = orig = None
        if opt_m:
            opt, orig = parse_thr(opt_m.group(1)), parse_thr(opt_m.group(2))
        results.append(
            {
                "ratio": ratio,
                "opt": opt,
                "origin": orig,
                "source": f"report:{Path(txt).name}",
            }
        )
    elif "=== comparison ===" in text:
        opt_m = re.search(
            r"OutputTokenThroughput\s+([\d.]+\s*token/s)\s+([\d.]+\s*token/s)", text
        )
        hdr = re.search(r"Metric\s+(\S+)\s+(\S+)", text)
        if opt_m and hdr:
            a, b = parse_thr(opt_m.group(1)), parse_thr(opt_m.group(2))
            c1, c2 = hdr.group(1).lower(), hdr.group(2).lower()
            if a and b and b > 0:
                if "origin" in c2:
                    ratio = a / b
                    opt, orig = a, b
                else:
                    ratio = b / a
                    opt, orig = b, a
                results.append(
                    {
                        "ratio": ratio,
                        "opt": opt,
                        "origin": orig,
                        "source": f"report:{Path(txt).name}",
                    }
                )

# older perf reports without speedup line
for txt in sorted(glob.glob(f"{KY}/perf_kylin_*.txt")):
    text = Path(txt).read_text(encoding="utf-8", errors="ignore")
    if "speedup_vs_origin" in text or "=== comparison ===" in text:
        continue
    # look for optimized vs origin in narrative
    blocks = re.findall(
        r">>> \[A\].*?OutputTokenThroughput.*?([\d.]+)\s*token/s.*?>>> \[B\].*?OutputTokenThroughput.*?([\d.]+)\s*token/s",
        text,
        re.S,
    )
    for a, b in blocks:
        opt, orig = float(a), float(b)
        if orig > 0:
            results.append(
                {
                    "ratio": opt / orig,
                    "opt": opt,
                    "origin": orig,
                    "source": f"legacy:{Path(txt).name}",
                }
            )

results.sort(key=lambda x: x["ratio"], reverse=True)
print("=== TOP Kylin optimized vs origin (by throughput ratio) ===")
for i, r in enumerate(results[:20], 1):
    print(
        f"{i:2}. {r['ratio']:.4f}x  opt={r['opt']}  origin={r['origin']}  {r['source']}"
    )

if results:
    best = results[0]
    print("\n=== BEST (throughput) ===")
    print(best)
    worst = min(results, key=lambda x: x["ratio"])
    print("\n=== WORST (throughput) ===")
    print(worst)

# E2EL: lower is better for optimized
e2el_results = []


def parse_ms(s):
    if not s:
        return None
    m = re.search(r"([\d.]+)", str(s))
    return float(m.group(1)) if m else None


for csv in sorted(glob.glob(f"{KY}/kylin_native_sweep_*.csv")):
    tag = Path(csv).stem
    rows = {}
    with open(csv) as f:
        for line in f.readlines()[1:]:
            p = line.strip().split(",")
            if len(p) < 9:
                continue
            scen, side = p[0], p[6]
            e2el = parse_ms(p[7])
            if e2el is None:
                continue
            rows.setdefault(scen, {})[side] = e2el
    for scen, d in rows.items():
        if "opt" in d and "origin" in d and d["opt"] > 0:
            # lead = how much faster opt is vs origin (positive = opt wins)
            lead_pct = (d["origin"] - d["opt"]) / d["origin"] * 100
            e2el_results.append(
                {
                    "lead_pct": lead_pct,
                    "opt": d["opt"],
                    "origin": d["origin"],
                    "ratio_origin_over_opt": d["origin"] / d["opt"],
                    "source": f"sweep_csv:{tag}:{scen}",
                }
            )

for txt in sorted(glob.glob(f"{KY}/kylin_native_sweep_*.txt")):
    text = Path(txt).read_text(encoding="utf-8", errors="ignore")
    scen = None
    for line in text.splitlines():
        if line.startswith(">>> scenario="):
            scen = line.split("scenario=")[1].split()[0]
        m = re.search(
            r"E2EL:\s*opt=([\d.]+)\s*ms\s*origin=([\d.]+)\s*ms", line
        )
        if m:
            opt, orig = float(m.group(1)), float(m.group(2))
            if opt > 0:
                lead_pct = (orig - opt) / orig * 100
                e2el_results.append(
                    {
                        "lead_pct": lead_pct,
                        "opt": opt,
                        "origin": orig,
                        "ratio_origin_over_opt": orig / opt,
                        "source": f"sweep_txt:{Path(txt).stem}:{scen}",
                    }
                )

for txt in sorted(glob.glob(f"{KY}/perf_kylin*.txt")) + sorted(
    glob.glob("/mnt/local/compare_perf_kylin*.log")
):
    text = Path(txt).read_text(encoding="utf-8", errors="ignore")
    if "=== comparison ===" not in text and "speedup_vs_origin" not in text:
        continue
    hdr = re.search(r"Metric\s+(\S+)\s+(\S+)", text)
    m = re.search(r"E2EL\s+([\d.]+\s*ms)\s+([\d.]+\s*ms)", text)
    if m and hdr:
        a, b = parse_ms(m.group(1)), parse_ms(m.group(2))
        c2 = hdr.group(2).lower()
        if a and b:
            if "origin" in c2:
                opt, orig = a, b
            else:
                opt, orig = b, a
            if opt > 0:
                lead_pct = (orig - opt) / orig * 100
                e2el_results.append(
                    {
                        "lead_pct": lead_pct,
                        "opt": opt,
                        "origin": orig,
                        "ratio_origin_over_opt": orig / opt,
                        "source": f"report:{Path(txt).name}",
                    }
                )

e2el_results.sort(key=lambda x: x["lead_pct"], reverse=True)
print("\n=== TOP E2EL lead (opt faster than origin; higher lead_pct = better) ===")
for i, r in enumerate(e2el_results[:15], 1):
    print(
        f"{i:2}. lead={r['lead_pct']:+.2f}%  opt={r['opt']:.1f}ms  origin={r['origin']:.1f}ms  ({r['ratio_origin_over_opt']:.4f}x)  {r['source']}"
    )
if e2el_results:
    print("\n=== BEST E2EL ===")
    print(e2el_results[0])
    print("\n=== WORST E2EL (opt slower most) ===")
    print(min(e2el_results, key=lambda x: x["lead_pct"]))
