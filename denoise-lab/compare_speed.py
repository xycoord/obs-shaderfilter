"""Speed-climb acceptance: faster, with quality held at the starting point's level.

Quality is compared with the fixed starting point (not the previous step), so small
losses can't add up over many steps:
  - score may fall by at most 0.1 dB;
  - each guard must stay within its tolerance in climb_rules.json;
  - fine texture may fall by at most 0.01 on any single clip.
Speed must improve by at least 10 % over the current fastest (timings vary ~5-10 %).

Usage: python compare_speed.py <start.json> <candidate.json> <current_fastest_s> <candidate_s>
"""
import json
import sys
from pathlib import Path

rules = json.loads((Path(__file__).parent / "climb_rules.json").read_text())
start = json.loads(Path(sys.argv[1]).read_text())
cand = json.loads(Path(sys.argv[2]).read_text())
fastest, speed = float(sys.argv[3]), float(sys.argv[4])
ok = True
d = cand["score"] - start["score"]
ok &= d >= -0.1
print(f"score {start['score']:+.3f} -> {cand['score']:+.3f} ({d:+.3f}, may fall 0.1) {'ok' if d >= -0.1 else 'TOO LOW'}")
for key, rule in rules["guards"].items():
    b, c = start.get(key), cand.get(key)
    if b is None or c is None or rule.get("kind") == "floor":
        continue
    worse = (b - c) if rule["better"] == "higher" else (c - b)
    tol = rule["tolerance"] * (abs(b) if rule.get("kind") == "relative" else 1)
    ok &= worse <= tol
    print(f"  {key:16s} {b:8.4f} -> {c:8.4f}  {'ok' if worse <= tol else 'WORSE'}")
for clip, r in start["synthetic"].items():
    c = cand["synthetic"][clip]["detail_texture"]
    passed = c >= r["detail_texture"] - 0.01
    ok &= passed
    if not passed:
        print(f"  texture on {clip}: {r['detail_texture']:.3f} -> {c:.3f}  WORSE")
gain = fastest / speed
ok &= gain >= 1.1
print(f"speed {fastest:.3f} -> {speed:.3f} s/MP-frame ({gain:.2f}x, need 1.10x) {'ok' if gain >= 1.1 else 'NOT ENOUGH'}")
print("ACCEPT" if ok else "REJECT")
sys.exit(0 if ok else 1)
