# obs-shaderfilter (xycoord's fork)

A shader filter for [OBS Studio](https://obsproject.com/): add it to any source, pick a shader, and adjust it. About
180 shaders come with it, among them complete looks — film, VHS, CRT — that are quick to get right without knowing
what every part does, and it runs shaders you write yourself.

> **This is a fork** of [Exeldro's obs-shaderfilter](https://github.com/exeldro/obs-shaderfilter) (release 2.6.1),
> which grew from [nleseul's original plugin](https://github.com/nleseul/obs-shaderfilter). The plugin, the shader
> format and most of the bundled shaders are theirs and their contributors'; see [Credits](#credits). The fork isn't
> theirs: please report problems with it [here](https://github.com/xycoord/obs-shaderfilter/issues), not upstream.

## What's different in this fork

- **Complete looks, with parts you can switch off.** *Film Look* is one filter for a whole projected-film look: the
  print's colour, halation, grain, dust and scratches, gate weave, flicker, the frame's edge and the lens. Each part
  has a tick, so you can have the look without the dust. 13 tuned presets set everything at once, and each part is also
  a filter of its own. The *VHS & CRT* pack has all-in-one VHS Tape and CRT TV filters with presets, and each part
  on its own.
- **Presets of your own,** for any shader: **Save as a Preset…** keeps a filter's settings to use on other filters.
- **A settings panel you can use without knowing the shader:** a Preset list that says when you've changed a preset,
  and which parts are off, and puts it back; the main settings first and the rest behind **Show All Settings**; units on
  the numbers; and what the shader costs in GPU time.
- **Easier to find a shader:** **Recently used** first, categories, shaders few people need kept at the end, a
  Search box that matches names and categories, and ↑/↓ to step through shaders while watching the preview. Filters
  are named after their shader.
- **Faster stacks of shader filters**, with the same output (see [Speed](#speed)).

Scenes saved with 2.6.1 keep working, including filters with their shader code typed in.

Writing your own shaders, or working on the plugin itself? See [DEVELOPING.md](DEVELOPING.md).

## Installation

The package mirrors OBS Studio's installation folder: copy its contents over an OBS Studio install (on Windows,
usually `C:\Program Files\obs-studio\`). The plugin goes in `obs-plugins/64bit/`, and its shaders and translations in
`data/obs-plugins/obs-shaderfilter/` (`examples/` and `locale/`).

## Using it

Add the filter to any source through "Filters" when right-clicking it; it is called "Shader".

- **Shader** lists the shaders that come with the plugin, grouped by category, plus "Other file…" for a
  shader file anywhere else. `.shader` and `.effect` files are both listed and handled automatically.
  Choosing one applies it straight away and names the filter after it ("Glow", "Glow 2"…), so a stack of
  shader filters can be told apart; a name you typed yourself is never changed. A filter whose shader fails
  shows "⚠" before its name until it works again.
- After choosing a shader, **↑/↓ on the Shader list** applies the next or previous one, so you can step
  through shaders while watching the preview. **Search** narrows the list (and so what ↑/↓ steps through) to
  shaders whose name or category matches (film, blur, vhs…), with the shader's place among them
  ("Shader 3 of 8 matching "blur"").
- The list starts with the shaders you used last (**Recently used**). Shaders few people need (another shader or
  one of OBS's own filters does the job, or they're demos) are at the end, under **More shaders**; they all still
  work, and Search finds them.
- The shader's settings follow. Shaders with presets start with a **Preset** list: choosing one sets every setting,
  which you can then adjust. After a change the list says so ("Classic Film (16mm) — changed"), and **Back to** puts
  the preset back. A shader made of parts, such as Film Look, shows each part in a box with a tick on its heading:
  untick it to leave that part out (its settings are kept). Settings most people won't need are behind
  **Show All Settings**.
- **Your own presets:** **Save as a Preset…** keeps a filter's settings (part ticks included) as a preset of your own,
  for every filter using that shader; it's listed under **Your presets** after the shader's own, and works for any
  shader, with presets or without. Picking one sets everything it saved; after a change, **Update** saves the change
  into it, and **Delete** removes it. They're kept in OBS's plugin settings folder (`obs-shaderfilter/presets/`), one
  file per shader name.
- **How much it costs:** the Shader list marks shaders that take noticeably more GPU time than a simple
  color filter (Medium, Heavy, Very Heavy), and a chosen shader's settings show the GPU time it actually
  takes on this computer, per frame and as a share of a frame.
- **Show Advanced Options** holds the rest: "Add Space Around the Image" (extra pixels on each side, for
  effects such as shadows that draw outside the source; shown next to the settings of shaders that need it),
  "Reload Shader File" for after editing the file in a text editor, and, for filters saved by older versions
  with their shader code typed in, that code. Such filters keep working.

To use a shader of your own, pick **Other file…** in the Shader list. [DEVELOPING.md](DEVELOPING.md) explains how to
write one, and how to give a folder of your own shaders categories and presets.

## Bundled shaders

The shaders that come with the plugin are in [data/examples](data/examples), listed by category in the Shader
list as [library.ini](data/examples/library.ini) says: Film & Lens, VHS & CRT, Retro & Glitch, Color, Blur & Glow,
Light, Distort, Stylize, Shapes & Masks, Backgrounds & Patterns, Motion, Clocks & Meters and Utility. 44 that few
people need are listed last, under **More shaders**: near-copies of another shader, jobs one of OBS's own filters
does (Opacity, Flip, Color Key, Luma Key), and demos. They all still work.

Many shaders say at the top who wrote them or where they're adapted from (often Shadertoy).

## Speed

Several shader filters stacked on one source render much faster than in release 2.6.1, with the same output and no
change to your scenes: neighbouring shader filters hand their pictures straight to each other, and simple colour
filters are merged into the one before them. Five colour filters on one source, for example, went from 123 ms to
36 ms per frame in a software-GPU test. [DEVELOPING.md](DEVELOPING.md#how-stacks-are-drawn) has the details and
the measurements.

## Credits

- **[nleseul](https://github.com/nleseul/obs-shaderfilter)** wrote the original obs-shaderfilter.
- **[Exeldro](https://github.com/exeldro/obs-shaderfilter)** took it on from version 2 and built it into the plugin
  this fork starts from (setting annotations and groups, many of the standard parameters, and the bundled shader
  collection, gathered with their authors). If the plugin is useful to you, consider supporting Exeldro:
  [paypal.me/exeldro](https://www.paypal.me/exeldro).
- **Everyone who contributed upstream:** shaders, fixes and translations; see the
  [contributors](https://github.com/exeldro/obs-shaderfilter/graphs/contributors) and each shader's header.
- **This fork's changes** (listed [above](#whats-different-in-this-fork)) are xycoord's.

The plugin is under the GNU General Public License, version 2; see [LICENSE](LICENSE).
