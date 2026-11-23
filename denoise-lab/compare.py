"""Decide whether a candidate beats the current best on the tuning set.

A candidate is accepted only if its score beats the best by more than the score
tolerance AND no guard is worse than the best's by more than its tolerance.
Tolerances live in climb_rules.json.

Usage: python compare.py results/tuning/<best>.json results/tuning/<candidate>.json
Exit code 0 = accept, 1 = reject.
"""

import json
import sys
from pathlib import Path

rules = json.loads((Path(__file__).parent / "climb_rules.json").read_text())
best = json.loads(Path(sys.argv[1]).read_text())
cand = json.loads(Path(sys.argv[2]).read_text())

ok = True
gain = cand["score"] - best["score"]
need = rules["score_min_gain"]
print(f"score {best['score']:+.3f} -> {cand['score']:+.3f} ({gain:+.3f}, need > {need:+.3f})"
      f" {'ok' if gain > need else 'NOT ENOUGH'}")
ok &= gain > need
for key, rule in rules["guards"].items():
    b, c = best.get(key), cand.get(key)
    if b is None or c is None:
        continue
    if rule["better"] == "higher":
        worse_by = b - c
    else:
        worse_by = c - b
    tol = rule["tolerance"] if rule.get("kind") != "relative" else rule["tolerance"] * abs(b)
    passed = worse_by <= tol
    ok &= passed
    print(f"  {key:28s} {b:9.4f} -> {c:9.4f}  {'ok' if passed else 'WORSE beyond tolerance'}")
limit = rules.get("max_seconds_per_megapixel_frame")
if limit is not None and cand["seconds_per_megapixel_frame"] > limit:
    ok = False
    print(f"  too slow: {cand['seconds_per_megapixel_frame']:.2f} s/MP-frame (limit {limit})")
print("ACCEPT" if ok else "REJECT")
sys.exit(0 if ok else 1)
