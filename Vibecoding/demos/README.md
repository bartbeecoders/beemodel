# Demo scenes

Three short scenes built around the newest features: the rigid body solver
(v0.17), ground and landscapes (v0.18) and shatter (v0.19). Each is one
BeeScript file that builds the whole scene. It replaces whatever is open.

| Demo | Length | Shows |
|---|---|---|
| `wrecking-ball.bees` | 8 s | A brick wall cut by **Shatter › bricks** with **glue** joints, hit by a steel ball on a chain of **point joints**. Only the bricks the ball reaches break loose, and the rest of the wall stands. |
| `gallery-smash.bees` | 6 s | Three exhibits stay whole until a steel ball lands on them (**impact**): a revolved glass vase (preset `glass`), a marble sphere (shards gathered `at` the hit point, glued) and a sandstone cube that bursts into 260 gravel **balls**. |
| `rockfall-island.bees` | 10 s | An **island landscape** (generated, eroded, painted by slope and height) with a **Flatten** layer as a pad for a glued brick tower. Boulders roll down the **heightfield collider** and knock the tower down. Pine crates **float** in the sea, and boulders that reach it sink. |

## Running them

In BeeModel, type this in the console, then press Space:

```
script.run ~/path/to/Vibecoding/demos/wrecking-ball.bees
```

You can also drive a running BeeModel over MCP, the way the Coca-Cola demo
does:

```
./play.sh rockfall-island
```

The first time through, the physics is simulated live. After that, playback
comes from the simulation cache, and scrubbing back shows the wall, vase and
tower whole again.

## Rendering a video

The viewport plays from your own view. Each demo also keys a camera
(`Cam`). `render.sh` runs the scene headless, path-traces every frame through
that camera, and joins the frames into an MP4 with ffmpeg:

```
./render.sh wrecking-ball                 # 1280x720, 48 samples -> out/wrecking-ball.mp4
./render.sh gallery-smash 1920 1080 96
```

At 720p and 48 samples, a demo takes one to three minutes on 32 threads.

## Values that matter

These were tuned by simulating headless and checking the numbers:

- **Glue holds the weight.** Glued pieces don't collide with each other, so
  the joints carry the whole load. On the wall, 30 000 N/m² gives a clean
  hole. Weaker glue lets the bricks shift, and much stronger glue makes the
  wall fall over as one slab. A 10 m tower needs about 400 000.
- **The impact threshold is an impulse per step.** A heavy object's own
  resting weight counts toward it. The marble sphere uses density 800 and
  `impact 800` so that it waits for the ball.
- **Give bodies a real mass near water.** Buoyancy uses the body's volume, so
  a boulder left at the default mass shoots up out of the sea. The boulders
  set `mass` to 2700 kg/m³ × their volume.
- The flatten layer's area is written `at x z r`, with no `radius` keyword.
