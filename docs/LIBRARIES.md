# Online model libraries

The Asset Browser shows the local content library (`~/BeeModel/library`)
and online sources. Click the source's name in its header to go round
them, or `lib.source <id>`; `lib.sources` lists them.

The first source is **NVIDIA SimReady**
([huggingface.co/datasets/nvidia/simready-assets](https://huggingface.co/datasets/nvidia/simready-assets),
CC-BY 4.0): 2673 simulation-ready props - food, kitchenware, boxes and
crates, tools, warehouse and hospital equipment - in OpenUSD, with
textured materials, masses, collision shapes and joints.

## Using it

- The catalog is fetched the first time a source is shown (about three
  seconds) and kept; `lib.refresh` fetches it again for new assets.
- Thumbnails come as their tiles show. The wheel scrolls; the search box
  (or `lib.search <words>`) narrows by name and category.
- Double-click a tile, or drag it into a viewport: the asset's files are
  downloaded the first time (only what an import needs), then it is
  imported ([USD.md](USD.md)) at the 3D cursor - or on the surface it is
  dropped on - with its materials and physics, and saved into the local
  library (`#simready #<category>`). The console names its source and
  licence.
- `lib.get <asset> [x y z]` does the same from the console, scripts and
  agents (MCP: `op_lib_get`).
- The status bar shows a download's progress; click it (or `lib.stop`) to
  stop. A tile with a green mark is downloaded.

Everything a source gives is kept under `~/BeeModel/cache/<id>/`:
`catalog.tsv`, `thumbs/`, and `assets/<name>/` laid out as in the dataset
(deleting it frees the space; it is fetched again when needed).
Downloads run in up to four `curl` processes in the background; curl
ships with Linux distributions and Windows 11.

## More sources

`~/BeeModel/sources.txt` adds Hugging Face datasets in SimReady's layout,
one a line (`#` comments):

    simready <id> <owner/dataset> <title>

A source kind is a few functions in `src/extlib.s`: the catalog's URLs, a
thumbnail's URL, which files an asset needs and its root. Other libraries
(other hubs, a folder of files) plug in there.

## Tests

`tests/extlib.py` runs a stand-in Hugging Face (paged listings,
paths-info, redirects to a "CDN", a failing file) and checks the catalog,
placing, the cache, retries, extra sources and, in a window, the Asset
Browser's thumbnails and double-click. `BEEMODEL_HF_URL` points BeeModel at
another server.
