# Online model libraries

The Asset Browser shows the local content library (`~/BeeModel/library`)
and online sources. Click the source's name in its header to go round
them, or `lib.source <id>`; `lib.sources` lists them.

The first source is **NVIDIA SimReady**
([huggingface.co/datasets/nvidia/simready-assets](https://huggingface.co/datasets/nvidia/simready-assets),
CC-BY 4.0): 2673 simulation-ready props - food, kitchenware, boxes and
crates, tools, warehouse and hospital equipment - in OpenUSD, with
textured materials, masses, collision shapes and joints.

The second is **SimReady Central** (`lib.source central`): NVIDIA's index
of reviewed Hugging Face datasets from other makers
([github.com/NVIDIA-Omniverse/simready-central](https://github.com/NVIDIA-Omniverse/simready-central)),
about 1,200 assets in November 2026: PalatialSim's household props (957),
ForgeCAD's appliances, tools and furniture, ALLSIDES's scanned objects,
Vertiv's data-centre racks, LG's appliances, and robot arms and grippers
(FANUC, Franka, Robotiq, OnRobot, Comau, Deep Robotics, AgiBot, Standard
Bots). See [SimReady Central](#simready-central) below.

The third is **Poly Haven** (`lib.source polyhaven`,
[polyhaven.com](https://polyhaven.com), CC0): 521 models in November 2026
- furniture, props, plants, food, tools, lights - with textured
materials, served as USD. No physics: they come in as plain objects. See
[Poly Haven](#poly-haven) below.

## Using it

- The catalog is fetched the first time a source is shown (about three
  seconds) and kept; `lib.refresh` fetches it again for new assets.
- Thumbnails come as their tiles show. The wheel scrolls; the search box
  (or `lib.search <words>`) narrows by name and category (Poly Haven:
  its tags too).
- Double-click a tile, or drag it into a viewport: the asset's files are
  downloaded the first time (only what an import needs), then it is
  imported ([USD.md](USD.md)) at the 3D cursor - or on the surface it is
  dropped on - with its materials and physics, and saved into the local
  library (`#simready #<category>`). The console names its source and
  licence.
- `lib.get <asset> [x y z] [static] [nosave]` does the same from the
  console, scripts and agents (MCP: `op_lib_get`); `static` leaves out
  rigid bodies and joints, `nosave` keeps it out of the local library.
- SimReady textures are 4096 a side: imports keep them at most
  `file.usd_texture_size` (1024 by default; a whole scene: 512), shrunk
  once and cached beside the original. A scene can hold 2048 images, the
  GPU sees 1024 of them.
- `Vibecoding/demos/auto-factory.bees` builds a car assembly hall from
  SimReady assets.
- The status bar shows a download's progress; click it (or `lib.stop`) to
  stop. A tile with a green mark is downloaded.

Everything a source gives is kept under `~/BeeModel/cache/<id>/`:
`catalog.tsv`, `thumbs/`, and `assets/<name>/` laid out as in the dataset
(deleting it frees the space; it is fetched again when needed).
Downloads run in up to four `curl` processes in the background; curl
ships with Linux distributions and Windows 11.

## SimReady Central

- The catalog comes from the index: one request lists its
  `submissions/<owner>/<dataset>` files. Then each dataset's licence and
  gating come from the Hugging Face API, and its index file from GitHub.
  That's about three seconds for the whole index. New datasets come in with
  `lib.refresh`.
- Only **public datasets under an open licence** are taken in (CC0,
  CC-BY, Apache, MIT, BSD, ...; not -NC or -ND, "other" or gated ones);
  the console names each one left out. `nvidia/simready-assets` is left out
  too: it is the NVIDIA SimReady source already.
- Each asset is the one the index names, **at the commit it was reviewed
  at**; when the index names a folder again at a later commit, that one is
  taken. Its category is the dataset's owner (search "forgecad", "vertiv",
  ...); the search also looks in the dataset's name. A folder name that
  another dataset already has gets `_<owner>` added (`crate_beta`).
- An asset's **package** says which files it has (its bill of materials,
  `.metadata/com.nvidia.simready.packaging.bom.json`). It is fetched when
  the tile shows or the asset is placed, and kept in `bom/`. Its USD root
  is the USD that a thumbnail in `simready_usd/.thumbs/<size>/` shows
  (256x256 first), else the first USD in `simready_usd/`. The thumbnail
  is that one, and the files to fetch are the package's, without
  `.thumbs/`, `source_assets/` or MDL.
- The Asset Browser's line for the selected asset, and the console's
  credit when it is placed, name its dataset and licence
  (`ForgeCAD/simready-assets  cc-by-4.0`); placed assets are saved into
  the local library as `#central #<owner>`.
- **Robots and grippers** come in with their bodies and joints, held in
  the pose they come in (their drives, and a gripper's mimic joints, held
  where they start): FANUC's, Franka's, Comau's arms, Robotiq's, OnRobot's
  and AgiBot's grippers stay within a centimetre under physics. `lib.get
  <name> static` places one without bodies or joints.

## Poly Haven

- The catalog is one request to Poly Haven's API
  (`api.polyhaven.com/assets?t=models`). An asset's category is its first
  one; its other categories and its tags go into the search ("chair"
  finds the sofas too).
- Thumbnails are Poly Haven's renders (asked for as PNG), cut out and not
  square: the tile fits them in, over a neutral backdrop.
- Placing an asset asks `/files/<id>` which files it has, kept in `bom/`.
  BeeModel takes the **1k** set (else 2k, 4k): the `.usdc` and the
  textures its `include` list names. Textures that list gives as
  OpenEXR (normal and metal maps, compressed in ways BeeModel doesn't
  read) come as the JPEG of the same map, which the same answer lists; the
  importer finds the JPEG beside the `.exr` the USD names.
- The models come from Blender: Z up, metres, separate metallic and
  roughness maps, which the importer makes one map.
- Placed assets are saved into the local library as
  `#polyhaven #<category>`; the console's credit says "Poly Haven, CC0".
- **Terms.** The models are CC0. Poly Haven's
  [API terms](https://polyhaven.com/our-api) make the API free for
  non-commercial projects and research, which BeeModel is (commercial use
  would need their permission, usually a sponsorship). Every request
  BeeModel makes says `User-Agent: BeeModel/<version>`, as they ask.

## More sources

`~/BeeModel/sources.txt` adds Hugging Face datasets in SimReady's layout,
and indexes in SimReady Central's, one a line (`#` comments):

    simready <id> <owner/dataset> <title>
    central  <id> <github owner/repo> <title>

A `simready` line wants NVIDIA's naming (an asset's root
`simready_usd/sm_<asset>_01.usd`); other makers' datasets come through
SimReady Central, or through a `central` line naming a copy of its index.

Poly Haven has no `sources.txt` kind: it's one API, built in.

A source kind is a few functions in `src/extlib.s`: the catalog's URLs, a
thumbnail's URL, which files an asset needs and its root. Other libraries
(other hubs, a folder of files) plug in there.

## Tests

`tests/extlib.py` runs a stand-in Hugging Face (paged listings,
paths-info, redirects to a "CDN", a failing file) and checks the catalog,
placing, the cache, retries, extra sources and, in a window, the Asset
Browser's thumbnails and double-click. A stand-in SimReady Central (a
GitHub index, datasets pinned to commits, packages) checks what is taken
in and left out, the commits, the roots and the files fetched. A
stand-in Poly Haven API checks the catalog, the 1k set, EXRs fetched as
JPEGs, the combined metallic-roughness map, the User-Agent and, in a
window, a cut-out thumbnail over the backdrop. `BEEMODEL_HF_URL`,
`BEEMODEL_GH_URL` and `BEEMODEL_PH_URL` point BeeModel at other servers.
