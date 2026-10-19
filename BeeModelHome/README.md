# BeeModelHome — the BeeModel website

The site at **https://beemodel.hideterms.com**: features, a tour with screenshots,
demo videos, a render gallery, the download (latest release, live from GitHub),
the MIT license, and a releases page with every version's notes and an Atom feed.

Plain HTML, CSS and a little JavaScript — no framework, no build chain beyond
one Python script. Every image and video was made by BeeModel itself.

```
BeeModelHome/
  src/            page templates (index.html, releases.html, partials/), CSS, JS, logo
  site/           the built site (committed: the image and deploy need nothing else)
  tools/
    capture.py    UI screenshots: BeeModel in the test suite's fake compositor (tools/fakewl.py)
    render.py     path-traced renders of the walkthrough scenes (headless --eval)
    screencast.py viewport screencasts (a scene stepped frame by frame) -> MP4
    build.py      site/: pages, releases (CHANGELOG.md + GitHub), WebP images, web MP4s
  media/          raw captures (git-ignored)
  Dockerfile      nginx (unprivileged, :8080) with site/
  nginx.conf      caching, CSP, /healthz
  deploy/k3s/     namespace, deployment, NodePort service 32110, kustomization
  scripts/deploy-k3s.sh
```

## Updating

After a release (new CHANGELOG entry, new GitHub release):

```
python3 BeeModelHome/tools/build.py --no-media     # pages + releases only
./BeeModelHome/scripts/deploy-k3s.sh all           # site, image, push, deploy
```

New pictures (needs `build/beemodel`, Pillow, ffmpeg):

```
python3 BeeModelHome/tools/capture.py              # media/shots/*.png  (or: capture.py fields cad)
python3 BeeModelHome/tools/render.py               # media/renders/*.png
python3 BeeModelHome/tools/screencast.py           # media/video/*.mp4
Vibecoding/demos/render.sh wrecking-ball           # the demo films (Vibecoding/demos/out)
python3 BeeModelHome/tools/build.py                # everything into site/
```

Preview: `cd BeeModelHome/site && python3 -m http.server 8765`, or the image:
`./BeeModelHome/scripts/deploy-k3s.sh run` (http://127.0.0.1:8110). Add `?static`
to the URL to show every section at once (whole-page screenshots).

## Hosting

`deploy-k3s.sh` follows BeeGit's: podman builds and pushes
`beecodersregistry.azurecr.io/beemodel-home:<version>-<sha>` (and `:latest`),
then applies `deploy/k3s` on the VPS over ssh (namespace `beemodel-home`,
NodePort **32111** (32110 is reportai's reportgenerator), the `acr-secret` pull secret copied from another namespace).
Cloudflare Tunnel needs one ingress rule (`deploy-k3s.sh tunnel` prints it):

```
- hostname: beemodel.hideterms.com
  service: http://localhost:32111
```
