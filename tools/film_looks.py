#!/usr/bin/env python3
"""The film pack's Looks, defined once, written into every shader's presets.

    python3 tools/film_looks.py        (writes data/examples/*.presets.ini)

Each Look sets every setting of Film Look (Film, Projector and Lens use the
same names) except the Amounts and the section ticks: a Look sets the values,
the ticks stay the person's. The single-effect shaders (Film Grain, Halation,
...) get the same Looks, mapped to their own setting names, so the same Look
can be picked in each filter of a chain. (Where two Looks come to the same
values for a shader, the list shows the one that was picked.)

Looks run from the mildest to the strongest. Flicker is kept gentle in all of
them (at most 5% from frame to frame, 8 dark frames a minute, 20% darker),
since fast flashing over a whole projected wall can be uncomfortable.
"""
from pathlib import Path

EX = Path(__file__).resolve().parent.parent / "data" / "examples"

# Film Look's settings, in its own order.
KEYS = ["Speed",
        "Stock", "Warmth", "Fade", "Contrast", "White", "Roll_Off", "Black_Lift", "Softness",
        "Halation_Strength", "Halation_Size", "Halation_Threshold",
        "Grain", "Grain_Size", "Grain_Colour", "Grain_Shadows", "Grain_Highlights",
        "Dust", "Scratches", "Speck_Size", "Light_Specks", "Dust_Strength",
        "Weave", "Jump", "Hand_Cranking",
        "Exposure_Flicker", "Lamp_Flicker", "Dark_Frames", "Dark_Frame_Depth", "Uneven_Illumination",
        "Lamp_Brightness",
        "Corner_Radius", "Inset", "Gate_Softness",
        "Fringing", "Corner_Falloff", "Distortion", "Corner_Softness"]

COLOUR, BW, SEPIA, AMBER, BLUE = 0, 1, 2, 3, 4

LOOKS = {
    # Barely there: a little grain and glow, a gentle edge.
    "Subtle": dict(
        Speed=24, Stock=COLOUR, Warmth=15, Fade=5, Contrast=20, White=98, Roll_Off=25, Black_Lift=0, Softness=0.3,
        Halation_Strength=8, Halation_Size=12, Halation_Threshold=75,
        Grain=12, Grain_Size=1.2, Grain_Colour=15, Grain_Shadows=50, Grain_Highlights=30,
        Dust=0, Scratches=0, Speck_Size=4, Light_Specks=20, Dust_Strength=40,
        Weave=0.2, Jump=0.15, Hand_Cranking=0,
        Exposure_Flicker=1.0, Lamp_Flicker=0.7, Dark_Frames=0, Dark_Frame_Depth=10, Uneven_Illumination=0.5,
        Lamp_Brightness=100,
        Corner_Radius=12, Inset=3, Gate_Softness=4,
        Fringing=1.5, Corner_Falloff=10, Distortion=0.5, Corner_Softness=0.3),
    # A good modern 35mm print in a cinema.
    "Clean 35mm": dict(
        Speed=24, Stock=COLOUR, Warmth=20, Fade=10, Contrast=30, White=97, Roll_Off=30, Black_Lift=0, Softness=0.5,
        Halation_Strength=11, Halation_Size=15, Halation_Threshold=70,
        Grain=15, Grain_Size=1.0, Grain_Colour=15, Grain_Shadows=60, Grain_Highlights=30,
        Dust=0.2, Scratches=0, Speck_Size=4, Light_Specks=20, Dust_Strength=40,
        Weave=0.3, Jump=0.25, Hand_Cranking=0,
        Exposure_Flicker=1.5, Lamp_Flicker=1.0, Dark_Frames=1, Dark_Frame_Depth=10, Uneven_Illumination=0.7,
        Lamp_Brightness=100,
        Corner_Radius=12, Inset=4, Gate_Softness=4,
        Fringing=2.5, Corner_Falloff=15, Distortion=0.5, Corner_Softness=0.5),
    # 16mm: the defaults.
    "16mm": dict(
        Speed=24, Stock=COLOUR, Warmth=50, Fade=30, Contrast=35, White=96, Roll_Off=40, Black_Lift=0, Softness=1.0,
        Halation_Strength=15, Halation_Size=30, Halation_Threshold=70,
        Grain=30, Grain_Size=2.4, Grain_Colour=25, Grain_Shadows=85, Grain_Highlights=30,
        Dust=0.5, Scratches=0, Speck_Size=5, Light_Specks=25, Dust_Strength=50,
        Weave=0.8, Jump=0.6, Hand_Cranking=0,
        Exposure_Flicker=3.5, Lamp_Flicker=2.5, Dark_Frames=4, Dark_Frame_Depth=15, Uneven_Illumination=1.5,
        Lamp_Brightness=100,
        Corner_Radius=30, Inset=6, Gate_Softness=8,
        Fringing=5, Corner_Falloff=25, Distortion=2, Corner_Softness=1.0),
    # Home movies: big grain, warm, a lively weave.
    "Super 8": dict(
        Speed=18, Stock=COLOUR, Warmth=70, Fade=35, Contrast=40, White=95, Roll_Off=45, Black_Lift=0, Softness=1.5,
        Halation_Strength=17, Halation_Size=55, Halation_Threshold=65,
        Grain=40, Grain_Size=4.0, Grain_Colour=30, Grain_Shadows=90, Grain_Highlights=35,
        Dust=1, Scratches=0.1, Speck_Size=7, Light_Specks=30, Dust_Strength=55,
        Weave=1.5, Jump=1.2, Hand_Cranking=0,
        Exposure_Flicker=5, Lamp_Flicker=4, Dark_Frames=5, Dark_Frame_Depth=15, Uneven_Illumination=2.5,
        Lamp_Brightness=100,
        Corner_Radius=45, Inset=8, Gate_Softness=10,
        Fringing=7, Corner_Falloff=35, Distortion=3, Corner_Softness=1.5),
    # A 1970s colour print whose colour has faded.
    "Faded Colour": dict(
        Speed=24, Stock=COLOUR, Warmth=40, Fade=70, Contrast=25, White=94, Roll_Off=40, Black_Lift=0, Softness=1.0,
        Halation_Strength=15, Halation_Size=30, Halation_Threshold=70,
        Grain=30, Grain_Size=2.4, Grain_Colour=25, Grain_Shadows=85, Grain_Highlights=30,
        Dust=0.5, Scratches=0, Speck_Size=5, Light_Specks=25, Dust_Strength=50,
        Weave=0.8, Jump=0.6, Hand_Cranking=0,
        Exposure_Flicker=3.5, Lamp_Flicker=2.5, Dark_Frames=4, Dark_Frame_Depth=15, Uneven_Illumination=1.5,
        Lamp_Brightness=100,
        Corner_Radius=30, Inset=6, Gate_Softness=8,
        Fringing=5, Corner_Falloff=25, Distortion=2, Corner_Softness=1.0),
    # A strong glow round everything bright, soft all over, a soft frame.
    "Dreamy": dict(
        Speed=24, Stock=COLOUR, Warmth=45, Fade=20, Contrast=20, White=96, Roll_Off=60, Black_Lift=0, Softness=1.6,
        Halation_Strength=45, Halation_Size=45, Halation_Threshold=55,
        Grain=18, Grain_Size=2.0, Grain_Colour=20, Grain_Shadows=60, Grain_Highlights=30,
        Dust=0.2, Scratches=0, Speck_Size=5, Light_Specks=25, Dust_Strength=40,
        Weave=0.6, Jump=0.4, Hand_Cranking=0,
        Exposure_Flicker=2, Lamp_Flicker=2, Dark_Frames=0, Dark_Frame_Depth=10, Uneven_Illumination=1.5,
        Lamp_Brightness=100,
        Corner_Radius=60, Inset=10, Gate_Softness=20,
        Fringing=4, Corner_Falloff=35, Distortion=2, Corner_Softness=2.0),
    # Clean black and white, without the silent era's wear.
    "Black & White": dict(
        Speed=24, Stock=BW, Warmth=10, Fade=0, Contrast=40, White=96, Roll_Off=40, Black_Lift=0, Softness=0.8,
        Halation_Strength=15, Halation_Size=18, Halation_Threshold=70,
        Grain=25, Grain_Size=1.8, Grain_Colour=0, Grain_Shadows=60, Grain_Highlights=30,
        Dust=0.4, Scratches=0, Speck_Size=5, Light_Specks=40, Dust_Strength=50,
        Weave=0.6, Jump=0.5, Hand_Cranking=0,
        Exposure_Flicker=3, Lamp_Flicker=2, Dark_Frames=3, Dark_Frame_Depth=12, Uneven_Illumination=1.5,
        Lamp_Brightness=100,
        Corner_Radius=25, Inset=6, Gate_Softness=8,
        Fringing=2, Corner_Falloff=25, Distortion=1.5, Corner_Softness=0.8),
    # A print that's been through the projector many times: dust, scratches,
    # dark frames, a jumpier gate.
    "Worn Print": dict(
        Speed=24, Stock=COLOUR, Warmth=50, Fade=40, Contrast=35, White=95, Roll_Off=40, Black_Lift=0, Softness=1.0,
        Halation_Strength=15, Halation_Size=30, Halation_Threshold=70,
        Grain=30, Grain_Size=2.4, Grain_Colour=25, Grain_Shadows=85, Grain_Highlights=30,
        Dust=6, Scratches=1.5, Speck_Size=8, Light_Specks=60, Dust_Strength=80,
        Weave=0.8, Jump=1.8, Hand_Cranking=0,
        Exposure_Flicker=4, Lamp_Flicker=2.5, Dark_Frames=8, Dark_Frame_Depth=20, Uneven_Illumination=2,
        Lamp_Brightness=100,
        Corner_Radius=30, Inset=6, Gate_Softness=8,
        Fringing=5, Corner_Falloff=25, Distortion=2, Corner_Softness=1.0),
    # Sepia-toned black and white.
    "Sepia": dict(
        Speed=18, Stock=SEPIA, Warmth=30, Fade=0, Contrast=40, White=94, Roll_Off=45, Black_Lift=0, Softness=1.3,
        Halation_Strength=28, Halation_Size=18, Halation_Threshold=65,
        Grain=35, Grain_Size=1.8, Grain_Colour=0, Grain_Shadows=85, Grain_Highlights=35,
        Dust=2, Scratches=0.3, Speck_Size=7, Light_Specks=50, Dust_Strength=70,
        Weave=1.2, Jump=1.0, Hand_Cranking=6,
        Exposure_Flicker=4, Lamp_Flicker=3, Dark_Frames=6, Dark_Frame_Depth=12, Uneven_Illumination=2.5,
        Lamp_Brightness=100,
        Corner_Radius=40, Inset=8, Gate_Softness=10,
        Fringing=2, Corner_Falloff=30, Distortion=2.5, Corner_Softness=1.5),
    # A 1920s silent film: black and white, 18 frames a second, a little
    # hand-cranked.
    "Silent Film": dict(
        Speed=18, Stock=BW, Warmth=30, Fade=0, Contrast=40, White=94, Roll_Off=45, Black_Lift=0, Softness=1.3,
        Halation_Strength=28, Halation_Size=18, Halation_Threshold=65,
        Grain=35, Grain_Size=1.8, Grain_Colour=0, Grain_Shadows=85, Grain_Highlights=35,
        Dust=2, Scratches=0.3, Speck_Size=7, Light_Specks=50, Dust_Strength=70,
        Weave=1.2, Jump=1.0, Hand_Cranking=6,
        Exposure_Flicker=4, Lamp_Flicker=3, Dark_Frames=6, Dark_Frame_Depth=12, Uneven_Illumination=2.5,
        Lamp_Brightness=100,
        Corner_Radius=40, Inset=8, Gate_Softness=10,
        Fringing=2, Corner_Falloff=30, Distortion=2.5, Corner_Softness=1.5),
    # Silent film tinted blue, as night scenes were.
    "Blue Tint (night)": dict(
        Speed=18, Stock=BLUE, Warmth=0, Fade=0, Contrast=40, White=92, Roll_Off=45, Black_Lift=0, Softness=1.3,
        Halation_Strength=28, Halation_Size=18, Halation_Threshold=65,
        Grain=35, Grain_Size=1.8, Grain_Colour=0, Grain_Shadows=85, Grain_Highlights=35,
        Dust=2, Scratches=0.3, Speck_Size=7, Light_Specks=50, Dust_Strength=70,
        Weave=1.2, Jump=1.0, Hand_Cranking=6,
        Exposure_Flicker=4, Lamp_Flicker=3, Dark_Frames=6, Dark_Frame_Depth=12, Uneven_Illumination=2.5,
        Lamp_Brightness=100,
        Corner_Radius=40, Inset=8, Gate_Softness=10,
        Fringing=2, Corner_Falloff=30, Distortion=2.5, Corner_Softness=1.5),
}
DEFAULT_LOOK = "16mm"

# Each shader's own setting names: its name -> Film Look's (or a function of
# the Look's values).
SAME = lambda *names: {n: n for n in names}
FILM = SAME(*KEYS[:KEYS.index("Weave")])
PROJECTOR = SAME("Speed", *KEYS[KEYS.index("Weave"):KEYS.index("Fringing")])
LENS = SAME(*KEYS[KEYS.index("Fringing"):])
SHADERS = {
    "film_look": SAME(*KEYS),
    "film": FILM,
    "projector": PROJECTOR,
    "lens": LENS,
    "film_print": SAME("Stock", "Contrast", "White", "Roll_Off", "Fade", "Warmth", "Black_Lift"),
    "halation": {"Strength": "Halation_Strength", "Size": "Halation_Size", "Threshold": "Halation_Threshold",
                 "Film": lambda v: 0 if v["Stock"] == COLOUR else 1},
    "film_grain": {"Amount": "Grain", "Grain_Size": "Grain_Size", "Color_Amount": "Grain_Colour",
                   "Shadows": "Grain_Shadows", "Highlights": "Grain_Highlights", "Speed": "Speed"},
    "dust_scratches": {"Dust": "Dust", "Speck_Size": "Speck_Size", "Light_Specks": "Light_Specks",
                       "Strength": "Dust_Strength", "Scratches": "Scratches", "Speed": "Speed"},
    "gate_weave": SAME("Weave", "Jump", "Speed"),
    "projector_flicker": SAME("Exposure_Flicker", "Lamp_Flicker", "Dark_Frames", "Dark_Frame_Depth",
                              "Uneven_Illumination", "Speed", "Hand_Cranking", "Lamp_Brightness"),
    "projector_gate": {"Corner_Radius": "Corner_Radius", "Edge_Softness": "Gate_Softness", "Inset": "Inset"},
    "lens_distortion": SAME("Distortion"),
    "lens_softness": {"Softness": "Softness", "Edge_Softness": "Corner_Softness"},
    "lens_chromatic_aberration": SAME("Fringing"),
    "lens_vignette": SAME("Corner_Falloff"),
}

# Presets a shader has besides the Looks.
EXTRAS = {
    "film_grain": {
        "35mm, Fast Stock": dict(Amount=28, Grain_Size=1.3, Color_Amount=20, Shadows=85, Highlights=25, Speed=24),
        "Pushed High-Speed Film": dict(Amount=45, Grain_Size=2.0, Color_Amount=0, Shadows=100, Highlights=40,
                                       Speed=24),
        "Digital, High ISO": dict(Amount=22, Grain_Size=1.0, Color_Amount=60, Shadows=100, Highlights=10, Speed=60),
    },
    "projector_gate": {
        "Soft": dict(Corner_Radius=30, Edge_Softness=22, Inset=14),
    },
}

HEADER = """; Presets for {name}.shader, written by tools/film_looks.py from the film
; pack's Looks (change them there, not here). Each Look sets every setting it
; lists; the Amounts and the section ticks are left as they are.
label = Look
"""


def fmt(x):
    return str(int(x)) if float(x) == int(x) else ("%g" % x)


def main():
    for k, v in LOOKS.items():
        assert list(v) == KEYS, (k, [a for a in KEYS if a not in v], [a for a in v if a not in KEYS])
        assert v["Exposure_Flicker"] <= 5 and v["Dark_Frames"] <= 8 and v["Dark_Frame_Depth"] <= 20, k
        assert v["Black_Lift"] == 0, k
    for name, mapping in SHADERS.items():
        sections = []
        for look, values in LOOKS.items():
            out = {}
            for own, src in mapping.items():
                out[own] = src(values) if callable(src) else values[src]
            sections.append((look, out))
        for extra, values in EXTRAS.get(name, {}).items():
            sections.append((extra, values))
        text = HEADER.format(name=name)
        for look, values in sections:
            text += "\n[%s]\n" % look + "".join("%s = %s\n" % (k, fmt(v)) for k, v in values.items())
        (EX / (name + ".presets.ini")).write_text(text)
        print("%-28s %s" % (name, ", ".join(s for s, _ in sections)))


if __name__ == "__main__":
    main()
