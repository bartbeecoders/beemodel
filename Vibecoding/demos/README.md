# Demo scenes

Short scenes built around the newest features: the rigid body solver
(v0.17), ground and landscapes (v0.18), shatter (v0.19), and particles and
liquid (v0.22). Each is one BeeScript file that builds the whole scene. It
replaces whatever is open.

| Demo | Length | Shows |
|---|---|---|
| `wrecking-ball.bees` | 8 s | A brick wall cut by **Shatter › bricks** with **glue** joints, hit by a steel ball on a chain of **point joints**. Only the bricks the ball reaches break loose, and the rest of the wall stands. |
| `gallery-smash.bees` | 6 s | Three exhibits stay whole until a steel ball lands on them (**impact**): a revolved glass vase (preset `glass`), a marble sphere (shards gathered `at` the hit point, glued) and a sandstone cube that bursts into 260 gravel **balls**. |
| `rockfall-island.bees` | 10 s | An **island landscape** (generated, eroded, painted by slope and height) with a **Flatten** layer as a pad for a glued brick tower. Boulders roll down the **heightfield collider** and knock the tower down. Pine crates **float** in the sea, and boulders that reach it sink. |
| `galactica.bees` | 10 s | The **Battlestar Galactica** (2004) at full scale, 1 438 m long, over the gas giant Ragnar. The hull is lofted from octagon stations, with procedural armour plating. Six Vipers coast out of the starboard launch tubes at 125 m/s, with **zero gravity and zero damping**. A Cylon Raider rams the flight pod at 240 m/s and **shatters on impact**. Needs `python3 starfield.py` first (the star-field HDRI). |
| `fireworks.bees` | 10 s | Three launchers on a jetty fire rockets over a night sea. A rocket's **died** event bursts it into a shell of 400 stars, and each star that burns out drops a spark of glitter (events from events). The particles glow through a **Vertex Color → Emission** material. Uses `space.hdr` for the sky when it is there. |
| `dam-break.bees` | 6 s | A column of 50 000 **liquid** particles is let go in a glass tank. Its **surface** is meshed every frame, **spray** events make foam, the wave breaks round a concrete pier, and pine crates dropped into it **float** (the first, landing ahead of the water, stays on the bottom) while a steel ball rolls along it. |
| `leaf-twister.bees` | 10 s | A **Vortex** field, keyed to wander, crosses an autumn park, with **Turbulence** for gusts. 18 000 leaves drawn as **objects** (turned at random, in three colours) lie on the lawn. The whirl lifts them up its funnel, and they settle again behind it. Dust **sprites** ride the same fields. |
| `rainstorm.bees` | 8 s | 40 000 drops a second fall on a valley **landscape** and on a cabin's roof (rigid body triangles). Each **hit** kills the drop and throws up three splashes. A **Wind** field whose strength is keyed rises with the squall and slants the rain. |

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

## Galactica: what is real in it

- **Scale.** Galactica is 1 438 m long, 536 m across the pods and 214 m high. A Viper Mk II is 8.6 m long, and a Raider is 9.5 m across. Everything is in metres.
- **Materials.** The armour is painted steel, a dielectric with roughness 0.6–0.75: Voronoi plates with no randomness, darker seams with bump, and grime noise. The ribs and guns are bare steel (metallic). The engine bells are heat-tinted refractory alloy. The Raider is a satin silver alloy. The lights take colours from their temperatures: 2 200 K exhaust, 4 000 K bay floods, and red to port, green to starboard.
- **Light.** The sun is the only real light, at the irradiance of the sun light at power 0.9, with a 0.53° disc. The sky is a star field (`starfield.py`: a magnitude law, a galactic band, blackbody colours) that adds next to no light, so shadows are black, as in space. The only fill is planetshine from Ragnar. The planet is shaded in its own material (albedo × E × max(0, N·L) / π as emission), because shadow rays on 800 km triangles only meet float rounding.
- **Physics.** There is no gravity and no drag (damping 0), so every body coasts in a straight line. The Vipers start inside their tubes, as far back as they travel before their launch, so they come out one after another at 125 m/s. The Raider is one closed SDF mesh, shattered with `impact 25000` into 48 shards that gather at its nose. The pod is a solid passive box: a mesh collider let the shards that spawn inside it fall through. The world steps at 480 Hz. Its break comes at frame 182, t = 6.03 s, from a run set up to hit at 6.0 s.

## Particles: what makes them work

- **Renders take the emitter's material**, tinted by each particle's
  colour (the base colour only). For particles that glow, give the emitter
  a material whose emission is driven by a **Vertex Color** node
  (fireworks). For a separate look, emit from a hidden helper with its own
  material (the dust pad under the lawn in leaf-twister).
- **Objects mode uses the object's mesh, not its scale.** The instance is
  the mesh as modelled, times the particle's `size`. A default plane is 2 m
  across, so `size 0.045` makes 9 cm leaves.
- **Events chain.** Rockets `died` → stars, stars `died` → glitter, each a
  system `from events` on the same emitter. Spray from a liquid works the
  same way (dam-break's foam).
- **The liquid's domain holds only the water.** Rigid bodies need walls of
  their own. Passive boxes placed exactly on the domain's faces grip the
  water, so dam-break stands them 2 cm outside it. Bodies resting on the
  floor before the water reaches them stay down, so the crates are dropped
  in once the wave is there.
- **Keyed fields cost nothing extra now.** A field moved by keys, or a keyed
  `field:Name:strength`, used to change the simulation cache's key every
  frame, so each frame simulated again from the start (930 ms a frame by the
  end of leaf-twister). `fl_mix` now hashes their keys instead (3 ms a
  frame).

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
