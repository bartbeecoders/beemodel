# Marketing

Posts and media for announcing BeeModel.

```
x-posts/
  01-introducing-beemodel.md   the first post: what BeeModel is (single post + a 5-post thread)
  02-v0.24-gpu-viewport.md     v0.24.0 "Viewport on the GPU" (single post + a 3-post thread)
  03-how-it-compares.md        the website's comparison with Blender, Unreal Engine and Godot
media/
  beemodel-dam-break.mp4       the dam-break demo playing in the viewport, 1080p60, 5.8 s
```

Each post is in its own code block, ready to paste, and fits X's 280 characters
(X counts a link as 23 and an emoji as 2).

## Rules of thumb

- Every number must come from something we measured: `tools/playbench.py` for
  playback, the release assets for sizes, the CHANGELOG for features. Say which
  shading mode a number is for (rainstorm is 181 fps in Material Preview, 27 in
  Rendered).
- Attach a video when there is one; X loops short clips.
- Link to https://beemodel.hideterms.com (downloads, demos, releases) or the
  GitHub repo.

## The dam-break clip

`media/beemodel-dam-break.mp4` was recorded in real time from the 3D viewport
(Material Preview, GPU viewport, 1920 x 1080), with the glass front of the tank
hidden so the water shows: Material Preview draws glass opaque. The window
drew about 125 frames a second during the recording.
