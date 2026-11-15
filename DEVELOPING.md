# Developing obs-shaderfilter

For people writing shaders for the plugin and people working on the plugin itself. Using the plugin is covered in
the [README](README.md).

Compared with release 2.6.1, this fork adds for shader authors: sections with a tick on their heading, settings
shown only under Show All Settings, units after numbers, several passes in one shader, buttons that switch a filter
to a larger shader keeping its settings, and presets files with defaults and descriptions. Every bundled shader,
chains of filters, transitions and the settings panel are tested against 2.6.1 in a headless OBS (see
[Testing](#testing)).

- [Writing shaders](#writing-shaders)
- [Shader folders: library.ini and presets](#shader-folders-libraryini-and-presets)
- [How stacks are drawn](#how-stacks-are-drawn)
- [Building](#building)
- [Testing](#testing)

## Writing shaders

Normally all that's required for OBS purposes is a pixel shader (a `.shader` file), and the plugin wraps it
with a standard template that adds a basic vertex shader and other boilerplate. A full `.effect` file lets
you customise the vertex shader or other parts of the effect; only `.shader` files can be merged with
neighbouring shader filters (see [How stacks are drawn](#how-stacks-are-drawn)). OBS shaders are written in OBS's version of HLSL.

Any parameters you add to your shader (defined as `uniform` variables) will be detected by the plugin and exposed
in the properties window to have their values set. Currently, only `int`, `float`, `bool`, `string`, `texture2d`, and `float4`
parameters are supported. (`float4` parameters will be interpreted by the properties window as colors.) `string` is used for 
notes and instructions, but could be used in an effect or shader. Variable names are displayed in the GUI with underscore replaced with space `uniform float Variable_Name` becomes `Variable Name`.

Annotations set a setting's label, widget, range, step and group. A slider from -1.0 to 1.0 in steps of 0.01:
```
// Contrast from -1.0 to 1.0
uniform float Contrast<
  string label = "Contrast Adjustment";
  string widget_type = "slider";
  string group = "Group";
  float minimum = -1.0;
  float maximum = 1.0;
  float step = 0.01;
> = 0.0;
```
A drop-down select widget for integer fields:
```
uniform int SelectTest<
  string label = "Int Select";
  string widget_type = "select";
  int    option_0_value = 0;
  string option_0_label = "First";
  int    option_1_value = 1;
  string option_1_label = "Second";
  int    option_2_value = 3;
  string option_2_label = "Third";
> = 3;
```
A text field the user can not edit:
```
uniform string notes<
    string widget_type = "info";
> = "add notes here";
```

A group with a tick on its heading, to switch a part of the shader on and off: a `bool` with `widget_type = "section"`
and the group's name. Unticked, the group folds to its heading; its settings
keep their values.
```
uniform bool Dust_On<
  string label = "Dust & Scratches";
  string widget_type = "section";
  string group = "Dust & Scratches";
> = true;
```
Settings most people won't need can be marked `string show = "more";`: they're shown only when the filter's
**Show All Settings** is ticked (which appears only for shaders that mark something), and still apply while hidden.
`string suffix = " %";` puts units after a number.

A `string` with `widget_type = "switch"` and a shader file (next to this one) as its value shows as a button that
makes the filter that shader, keeping its settings: each setting of the new shader takes this one's value of the same
name, or of a name its `string from = "film_grain:Amount, halation:Strength";` annotation gives for this shader; the
rest take the preset this filter had (or their defaults). The film pack's filters use it for **Switch to Film Look**,
and a run of Film, Projector and Lens filters can be combined into one Film Look the same way.

### Several passes

A shader that needs a pass's result around each pixel (a blur of an earlier effect, say) can do it in stages:
`float4 stage1(VertData v_in) : TARGET`, then `stage2` and so on (up to 4), before `mainImage`. Each stage is drawn
in full, at 16 bits a channel, and is the next one's `image`; all of them share the shader's parameters.
```
float4 stage1(VertData v_in) : TARGET
{
    return image.Sample(textureSampler, v_in.uv) * 0.5; // the first pass
}
float4 mainImage(VertData v_in) : TARGET
{
    return image.Sample(textureSampler, v_in.uv + float2(4.0 * uv_pixel_interval.x, 0.0)); // sees stage1's result
}
```

A wide blur is much cheaper at a reduced size: `#define STAGE1_SCALE 4` (at the start of a line) draws stage 1 at a
quarter of the filter's size each way (1 to 8). Every pass can also read the filter's input as `source_image`, the
stages drawn before it as `stage1_image` to `stage4_image`, and `stages_drawn` (true whenever stages are drawn), so a
shader can fall back to doing everything in `mainImage` where a host draws only that, such as release 2.6.1. Declare
the ones you use:
```
uniform texture2d source_image;
uniform texture2d stage3_image;
uniform bool stages_drawn;
```
[halo_parts.hlsl](data/examples/halo_parts.hlsl) and [glow_parts.hlsl](data/examples/glow_parts.hlsl) are worked
examples: a glow averaged into a quarter-size picture, blurred across and then down there, and read back at full
size, with a full-size fallback. (OBS's preprocessor reads `#define NAME (…)`, with a space before the bracket, as a
macro with arguments: start a macro's body with something other than a bracket.)

### Defaults

You set default values as a normal assignment ```uniform string notes = 'my note';```, except for `float4` 
which requires bracket \{\} notation like ```uniform float4 mycolor = { 0.75, 0.75, 0.75, 1.0};``` 

If your shader fails to compile, the filter passes the image through unchanged and its settings say why, with
the first compiler message; "Show Full Compiler Output" shows the rest. The parser output is also written to
the OBS log file (Help -> Log Files).

### Standard parameters

The plugin automatically populates a few parameters which your shader can use. If you choose to override the entire
effect, be sure to define these as `uniform` variables and use them where necessary. (The filter should gracefully 
handle these variables being missing, but the shader may malfunction.) A version in brackets is the release of
the original plugin that added it.

* **`ViewProj`** (`float4x4`)&mdash;The view/projection matrix. (Standard for all OBS filters.)
* **`image`** (`texture2d`)&mdash;The image to which the filter is being applied, either the original output of 
  the source or the output of the previous filter in the chain. (Standard for all OBS filters.)
* **`prevous_image`** (`texture2d`)&mdash;The previous image to which the filter is being applied (2.5.0)
* **`elapsed_time`** (`float`)&mdash;The time in seconds which has elapsed since the filter was created. Useful for 
  creating animations.
* **`elapsed_time_start`** (`float`)&mdash;The time in seconds which has elapsed since the shader was loaded (2.4.0).
* **`elapsed_time_show`** (`float`)&mdash;The time in seconds which has elapsed since the filter was shown (2.4.0).
* **`elapsed_time_active`** (`float`)&mdash;The time in seconds which has elapsed since the filter has become active (2.4.0).
* **`elapsed_time_enable`** (`float`)&mdash;The time in seconds which has elapsed since the filter was enabled (2.4.0).
* **`local_time`** (`float`)&mdash; a random float representing the local time.(1.2)
* **`loops`** (`int`)&mdash; count of how many seconds the shader has rendered a page.(1.2)
* **`loop_second`** (`float`)&mdash; a float going from 0.0 to 1.0 each loop.(2.4.0)
* **`current_time_ms`** (`int`)&mdash; the microseconds (0 to 999) of the current time.(2.4.1)
* **`current_time_sec`** (`int`)&mdash; the seconds (0 to 59) of the current time.(2.4.1)
* **`current_time_min`** (`int`)&mdash; the minutes (0 to 59) of the current time.(2.4.1)
* **`current_time_hour`** (`int`)&mdash; the hours (0 to 23) of the current time.(2.4.1)
* **`current_time_day_of_week`** (`int`)&mdash; the day of the week (0 to 6) of the current time.(2.4.1)
* **`current_time_day_of_month`** (`int`)&mdash; the day of the month (1 to 31) of the current time.(2.4.1)
* **`current_time_month`** (`int`)&mdash; the month (0 to 11) of the current time.(2.4.1)
* **`current_time_day_of_year`** (`int`)&mdash; the day of the month (0 to 365) of the current time.(2.4.1)
* **`current_time_year`** (`int`)&mdash; the number of years since 1900 of the current time.(2.4.1)
* **`rand_f`** (`float`)&mdash; a random float between 0 and 1. changes per frame.
* **`rand_activation_f`** (`float`)&mdash; a random float between 0 and 1. changes per activation, load or change of settings.(1.2)
* **`rand_instance_f`** (`float`)&mdash; a random float between 0 and 1. changes per instance on load.(1.2)
* **`uv_offset`** (`float2`)&mdash;The offset which should be applied to the UV coordinates of the vertices. This is
  used in the standard vertex shader to draw extra pixels on the borders of the source.
* **`uv_scale`** (`float2`)&mdash;The scale which should be applied to the UV coordinates of the vertices. This is 
  used in the standard vertex shader to draw extra pixels on the borders of the source.
* **`uv_size`** (`float2`)&mdash;The height and width of the screen.
* **`uv_pixel_interval`** (`float2`)&mdash;This is the size in UV coordinates of an individual texel. You can use
  this to convert the UV coordinates of the pixel being processed to the coordinates of that texel in the source
  texture, or otherwise scale UV coordinate distances into texel distances.
* **`prevous_output`** (`texture2d`)&mdash;The previous output of the filter (2.5.0)
* **`audio_peak`** (`float`)&mdash;The instantaneous maximum audio level (peak) from the selected audio source, normalized to 0.0-1.0.
  More reactive to sudden sounds like drums.
* **`audio_magnitude`** (`float`)&mdash;The RMS (Root Mean Square) audio level from the selected audio source, normalized to 0.0-1.0.
  Smoother representation of sustained audio levels.

### Optional Preprocessing Macros

The plugin provides some optional pre-processing macros.

* **`#include "<path-to-file>"`** The include macro will insert the contents file at the path `<path-to-file>` before the shader is compiled. This is useful to place commonly used functions, in a separate file that can be used by multiple shaders.  E.g.: `#include "util-fns.effect"`.
* **`#define <NAME> <value>`** This allows you to define constants to be used throughout your shader. Constants can be values or even simple functions. Anywhere the value in `<NAME>` is found in your shader, it will be replaced with whatever is in `<value>`.  For example, after putting `#define PI 3.14159` near the top of your shader file, you can use code like: `float circle_area = PI * radius * radius;`.  Note, the `#define` line should NOT be ended with a semicolon.
* **`#define USE_PM_ALPHA 1`** By default, OBS will pass through pre-multiplied alpha color values. This can cause issues if the source being filtered has opacity values that are not zero or one. By default, shaderfilter now corrects internally for premultipled alpha, but if you have written an older shader that does the correction itself, you can turn off the correction by placing `#define USE_PM_ALPHA 1` near the top of your shader file.

`data/examples/filter_template.shader` and `filter_template.effect` are starting points: they draw the image
unchanged.

## Shader folders: library.ini and presets

The shader list for a folder can be given categories, display names, cost ratings and the `more` flag with a `library.ini`
next to the shaders; see [data/examples/library.ini](data/examples/library.ini). Presets go in a
`<shader name>.presets.ini` beside the shader: one `[section]` per preset with `parameter = value` lines
(`;` starts a comment); see
[data/examples/film_grain.presets.ini](data/examples/film_grain.presets.ini). The Preset list remembers the one
picked, and after a change shows "*preset* — changed" rather than Custom, naming any sections that are unticked
(picking the preset again puts it back, with every section ticked). Before the first preset, a `default = <name>` line names the preset the
shader's defaults are, shown (of several with the same values) until another is picked, and a `label = ...` line
renames the list; a `description = ...` line in a preset is shown under the list.
The film pack's presets are all written from one table by [tools/film_looks.py](tools/film_looks.py).

## How stacks are drawn

Several shader filters stacked on one source render much faster than in release 2.6.1, with no change to
scenes or shaders:

* **Consecutive shader filters hand their output straight to each other.** Previously every filter made
  OBS render its input into a texture, copied it, ran its shader, and copied the result into the next
  filter's texture: three full-screen passes per filter. Now a run of N shader filters costs N + 2 passes.
  The first filter also lets a plain source (image, text, colour…) draw itself straight into its input.
* **Filters that only read the pixel they are drawing are merged into the filter before them.** Colour
  grading, invert, opacity, gamma, hue, vignette and many more only ever call
  `image.Sample(textureSampler, v_in.uv)`; such a filter is compiled together with the one upstream of it
  into a single shader, so a run of them costs one pass.
* Output is the same as before: the plugin reproduces, inside the shaders, exactly what the removed passes
  did to the pixels (8-bit storage, premultiplying and un-premultiplying alpha in linear light), so even
  translucent pixels match to within a rounding step.

Anything that can't be reproduced exactly keeps the old path for that link: full `.effect` files upstream,
a `.shader` containing its own `technique`, `previous_output` or `#define USE_PM_ALPHA 1` upstream, and
HDR colour spaces. Set the environment variable `SHADERFILTER_NO_FUSION=1` to turn merging off.

Each filter's own effect is compiled exactly as before; the linked and merged versions are separate effects,
so if one of them fails to compile the filters simply render the old way (the OBS log says so). Compiling
stalls OBS's graphics thread, so they are only compiled when that happens anyway: when a scene collection
loads, a filter is added, a shader is edited or "Reload effect" is pressed. Toggling, reordering or removing
filters during a show never causes a stall; until the new arrangement's effect has been prepared (at the
next of those moments), the filters render linked or the old way.

Measured on a software GPU at 1080p. These are relative, not absolute, numbers; a real GPU should gain at
least as much, since the passes removed are memory-bandwidth-bound copies:

| Filters on one source | before | after | full-screen draws |
|---|---|---|---|
| 5 colour filters (grade, invert, opacity, gamma, luminance) | 123 ms | 36 ms | 17 → 4 |
| 5 effects (hue, chromatic aberration, VHS, glow, vignette) | 167 ms | 99 ms | 17 → 7 |
| the same with glow expanded by 16 px | 170 ms | 97 ms | 17 → 7 |
| 1 filter | 29 ms | 23 ms | 5 → 4 |

## Building

If you wish to build the obs-shaderfilter plugin from source, you should just need [CMake](https://cmake.org/) 
and the OBS Studio libraries and headers.

* [This fork's source repository](https://github.com/xycoord/obs-shaderfilter)
* [OBS Studio source repository](https://github.com/obsproject/obs-studio)

1. In-tree build
    - Build OBS Studio: https://obsproject.com/wiki/Install-Instructions
    - Check out this repository to plugins/obs-shaderfilter
    - Add `add_subdirectory(obs-shaderfilter)` to plugins/CMakeLists.txt
    - Rebuild OBS Studio

1. Stand-alone build (Linux only)
    - Verify that you have package with development files for OBS
    - Check out this repository and run `cmake -S . -B build -DBUILD_OUT_OF_TREE=On && cmake --build build`

## Testing

`tests/` renders every example shader, chains of them, transitions, expansion, texture sources, temporal
shaders and live changes to the filter stack in a headless OBS, with this build and with release 2.6.1,
and compares the frames; it also times filter chains. On Ubuntu 24.04:

```
sudo tests/run.sh packages      # once: the packages needed
tests/run.sh setup              # once: a test build of libobs 33, both plugin builds
xvfb-run -a tests/run.sh parity
xvfb-run -a tests/run.sh parity --opaque
xvfb-run -a tests/run.sh bench
```

See [tests/README.md](tests/README.md) for what is compared and how differences are judged.

`tests/ui/` captures the filter's settings panel, drawn by OBS's own properties widget, in a set of fixed
scenarios (`tests/ui/shots.py`), for reviewing the UI. Pass `--theme` one of OBS's own themes (OBS 30's
`themes/Yami.qss` is its default) so group boxes, ticks and spacing are drawn as OBS draws them; without it a rough
stand-in style is used, whose group boxes look like no OBS theme's.
