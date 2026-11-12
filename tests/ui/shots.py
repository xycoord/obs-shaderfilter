#!/usr/bin/env python3
"""Capture the fixed set of UI screenshots for review.

    shots.py --plugin SO --data DIR --out DIR   (OBS_PREFIX, UISHOT env or flags)

Every shader is chosen the way a person would: by setting the shader file and
firing the file property's change callback, as the properties panel does.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EX = HERE.parent.parent / "data" / "examples"


def pick(i, name):
    """Choose a shader file for filter i through the UI."""
    return [{"filter": i, "property": "from_file", "value": True},
            {"filter": i, "property": "shader_file_name", "value": str(EX / name)}]


def shots():
    stack = ["hue-rotaton.shader", "chromatic-aberration.shader", "VHS.shader", "glow.shader", "vignetting.shader"]
    ui = []
    for i, n in enumerate(stack):
        ui += pick(i, n)
    return [
        # Five filters on one graphic, the third selected.
        {"name": "1_stack", "filters": [{"settings": {}} for _ in stack], "ui": ui, "select": 2, "panel": True,
         "open_combo": 0},
        # A filter just added, before anything is chosen.
        {"name": "2_new_filter", "filters": [{"settings": {}}], "select": 0, "panel": True, "open_combo": 0},
        # A shader with several parameters.
        {"name": "3_parameters", "filters": [{"settings": {}}], "ui": pick(0, "glow.shader"), "select": 0,
         "panel": True},
        # A full .effect file.
        {"name": "4_effect_file", "filters": [{"settings": {}}], "ui": pick(0, "pulse.effect"), "select": 0,
         "panel": True},
        # A shader that fails to compile (on OpenGL).
        {"name": "5_error", "filters": [{"settings": {}}], "ui": pick(0, "hard_blink.shader"), "select": 0,
         "panel": True},
        # Trying shaders: coming back to a filter that has a shader, opening the
        # browsing tools and narrowing the list to one category.
        {"name": "7_browsing", "filters": [{"settings": {}}],
         "ui": pick(0, "glow.shader") + [{"filter": 0, "wait_ms": 1200},
                                         {"filter": 0, "property": "browse_shaders", "value": True},
                                         {"filter": 0, "property": "shader_category", "value": "Blur & Glow"}],
         "select": 0, "panel": True, "open_combo": 0},
        # A filter saved by an older version with code typed into it.
        {"name": "6_legacy_inline_code", "filters": [{"settings": {"shader_text": INLINE}}], "select": 0,
         "panel": True},
    ]


INLINE = """uniform float strength<
    string label = "Strength";
    string widget_type = "slider";
    float minimum = 0.0;
    float maximum = 1.0;
    float step = 0.01;
> = 0.5;

float4 mainImage(VertData v_in) : TARGET
{
    float4 c = image.Sample(textureSampler, v_in.uv);
    return float4(lerp(c.rgb, 1.0 - c.rgb, strength), c.a);
}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--obs-prefix", default=os.environ.get("OBS_PREFIX"))
    ap.add_argument("--uishot", default=os.environ.get("UISHOT"))
    ap.add_argument("--plugin", required=True)
    ap.add_argument("--data", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--locale", default=os.environ.get("OBS_FRONTEND_LOCALE"),
                    help="OBS frontend en-US.ini, for OBS's own widget strings")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    spec = {"image": a.image, "shots": shots()}
    (out / "spec.json").write_text(json.dumps(spec, indent=1))
    env = dict(os.environ, QT_QPA_PLATFORM="offscreen", LD_LIBRARY_PATH=f"{a.obs_prefix}/lib")
    r = subprocess.run([a.uishot, "--obs-prefix", a.obs_prefix, "--obs-plugin", a.plugin, "--data", a.data,
                        "--spec", str(out / "spec.json"), "--out", str(out)]
                       + (["--locale", a.locale] if a.locale else []), env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
    (out / "uishot.log").write_text(r.stdout)
    print("\n".join(sorted(p.name for p in out.glob("*.png"))))
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
