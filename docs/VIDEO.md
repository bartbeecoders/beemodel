# Rendering an animation into a video

**Render › Render Animation…** renders every frame of the animation's
range at the render settings (Render › Render Settings: size and
samples) and saves them as a video. The save dialog suggests
`animation.mp4`. Pick another kind of file by its extension:

| Extension | What you get | Needs |
|---|---|---|
| `.mp4`, `.mov` | H.264, quality 18 (`-crf 18`), index at the front for the web | ffmpeg |
| `.mkv` | H.264, as `.mp4` | ffmpeg |
| `.webm` | VP9 (`-crf 32`) | ffmpeg |
| `.gif` | A GIF with a palette made from the animation, looping | ffmpeg |
| `.apng` | An animated PNG, lossless and looping; plays in browsers | nothing |
| `.png` | A folder of frames named like the file: `shot.png` → `shot/0001.png` … | nothing |

H.264 and VP9 need an even width and height, so an odd one loses its
last column or row. The frame rate is the animation's (Timeline ›
Range, `anim.range`).

While it renders, the status bar shows "Rendering the animation (Esc
stops)" and how far it is. **Esc** stops it after the frame it is on.
The video then has the frames rendered so far, and the console says
"(stopped)". Nothing else can be done meanwhile.

From the console, scripts and the AI:

```
render.animation ~/films/shot.mp4              # the animation's range
render.animation ~/films/shot.webm 1 48        # frames 1 to 48
render.animation ~/films/frames                # a folder: 0001.png ...
op("render.animation", "~/films/title.apng")
```

The console then says, for example, `rendered frames 1 to 144 ->
/home/you/films/shot.mp4, ms: 41230`.

## ffmpeg

Videos are made by [ffmpeg](https://ffmpeg.org), which BeeModel runs
when it needs it. It is found on `PATH`; set `BEEMODEL_FFMPEG` to use
another one. Install it with your distribution (`pacman -S ffmpeg`,
`apt install ffmpeg`, `dnf install ffmpeg`). Without it, BeeModel says
so before it renders anything, and `.apng` and `.png` still work.

The frames go to ffmpeg's standard input as raw pixels while the next
frame renders, so no PNGs are written in between and the video is ready
when the last frame is. ffmpeg's messages go to
`~/.cache/beemodel/ffmpeg.log`. If it fails, for example when its
build has no H.264 encoder, the render stops at the next frame and the
console shows ffmpeg's first line:

```
render.animation: ffmpeg could not make the video: Unknown encoder 'libx264'
```

Then try `.webm` or `.apng`, or another ffmpeg build.

## How it works

`hive_render_frames` (hive_pt.s) renders the frames as it always has. On
the GPU the next frame is simulated and built while the GPU traces one,
and sample reuse works the same (docs/GPU.md). Each finished frame goes
to `rf_out` when one is set, or to `folder/NNNN.png` when not.
`src/video.s` sets `rf_out` from the file's extension:

- **ffmpeg.** A socket pair is the child's standard input (a socket, so
  a dead ffmpeg is an error from `send`, never a SIGPIPE). The arguments
  are `-f rawvideo -pix_fmt bgr0 -video_size WxH -framerate N/1000 -i -`,
  then the codec's (`libx264 -crf 18 -pix_fmt yuv420p`, `libvpx-vp9 -crf
  32 -b:v 0`, or `palettegen` / `paletteuse` for a GIF). At the end the
  socket is closed and BeeModel waits for ffmpeg to finish. Exit status 0
  means the video is made.
- **APNG.** Each frame is encoded by BeeModel's PNG encoder (png.s) and
  taken apart into chunks. The file gets the first frame's IHDR, then
  `acTL` (the number of frames, playing for ever). Each frame gets an
  `fcTL` (its size and delay: 100 / (fps × 100) s) and its image data:
  IDAT chunks for the first frame, then `fdAT` chunks. When the render
  ends, `acTL` is rewritten with the number of frames actually written,
  so a stopped render plays what it has.

The render runs as a long job (jobui.s, `JOB_OP`). The status bar shows
each frame's share of the range. Esc is the one key a long job listens
to (`job_key` sets `job_stop`), and `hive_render_frames` checks it after
each frame.

The tests are in `tests/video.py`. They cover a folder, `.png`, `.apng`
(chunk order, sequence numbers, CRCs, delays, the pictures), `.mp4`
`.mkv` `.webm` `.gif` through ffmpeg (ffprobe: codec, size, frames,
rate, the pictures), a stand-in ffmpeg that fails, no ffmpeg at all, and
the menu, the dialog and Esc in the fake compositor.
