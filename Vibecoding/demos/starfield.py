#!/usr/bin/env python3
"""Writes a deep-space sky as an equirectangular Radiance HDR (flat RGBE).

Stars follow a magnitude law (each magnitude about 3x as many stars, 2.5x
fainter), are denser in a tilted galactic band, and take a colour from their
temperature. The band itself is a faint, dusty glow. Nothing else lights the
scene, so the sun light does the work, as in space.

    python3 starfield.py [out.hdr] [width]      -> space.hdr, 4096 x 2048
"""
import sys
import numpy as np

out = sys.argv[1] if len(sys.argv) > 1 else "space.hdr"
W = int(sys.argv[2]) if len(sys.argv) > 2 else 4096
H = W // 2
rng = np.random.default_rng(1978)

# directions of each pixel centre (y up; u = 0.5 + atan2(x, -z) / 2pi, v = theta / pi)
v = (np.arange(H) + 0.5) / H
u = (np.arange(W) + 0.5) / W
theta = v[:, None] * np.pi
phi = (u[None, :] - 0.5) * 2 * np.pi
sx = np.sin(theta) * np.sin(phi)
sy = np.cos(theta) * np.ones_like(phi)
sz = -np.sin(theta) * np.cos(phi)

# the galactic plane: a tilted great circle
gn = np.array([0.35, 0.80, -0.48]); gn /= np.linalg.norm(gn)
gc = np.array([0.80, -0.10, 0.59]); gc -= gn * gc.dot(gn); gc /= np.linalg.norm(gc)
lat = np.arcsin(np.clip(sx * gn[0] + sy * gn[1] + sz * gn[2], -1, 1))
core = sx * gc[0] + sy * gc[1] + sz * gc[2]            # 1 toward the galactic centre

img = np.zeros((H, W, 3), np.float32)

# the band: diffuse glow brightest toward the core, cut by dust lanes
band = np.exp(-(lat / 0.16) ** 2) * (0.35 + 0.65 * np.clip(core, 0, 1) ** 2)
yy, xx = np.mgrid[0:H, 0:W]
dust = np.zeros((H, W), np.float32)
for f, a in ((3, 0.5), (7, 0.3), (17, 0.2), (41, 0.12)):
    ph = rng.uniform(0, 2 * np.pi, 4)
    dust += a * (np.sin(xx / W * 2 * np.pi * f + ph[0] + 2 * np.sin(yy / H * np.pi * f * 0.7 + ph[1]))
                 * np.sin(yy / H * np.pi * f * 1.3 + ph[2] + 1.5 * np.sin(xx / W * 2 * np.pi * f * 0.5 + ph[3])))
lanes = np.clip(0.55 + 0.6 * dust, 0, 1) * np.clip(1 - 0.8 * np.exp(-(lat / 0.035) ** 2), 0, 1)
glow = 0.0035 * band * lanes
img[..., 0] += glow * 1.00
img[..., 1] += glow * 0.86
img[..., 2] += glow * 0.70
# faint blue-grey airglow of unresolved stars everywhere
img += np.float32(0.00012) * np.array([0.8, 0.85, 1.0], np.float32)

# stars: uniform on the sphere, plus extra in the band
def dirs(n):
    z = rng.uniform(-1, 1, n); a = rng.uniform(0, 2 * np.pi, n); r = np.sqrt(1 - z * z)
    return np.stack([r * np.cos(a), z, r * np.sin(a)], 1)

d = dirs(60000)
db = dirs(400000)
blat = db @ gn
keep = rng.uniform(0, 1, len(db)) < np.exp(-(np.arcsin(np.clip(blat, -1, 1)) / 0.12) ** 2) * 0.5
d = np.concatenate([d, db[keep]])
n = len(d)
# magnitudes from 0 to 9.5, number per magnitude x3 (log10 3 = 0.48)
mag = 9.5 - rng.exponential(1 / (0.48 * np.log(10)), n)
mag = np.clip(mag, -1.0, 9.5)
flux = 10 ** (-0.4 * mag) * 4.0                          # mag 0 -> 4 in one pixel
temp = np.clip(rng.lognormal(np.log(5800), 0.35, n), 2800, 30000)

def bb_rgb(t):
    """Rough sRGB-linear colour of a blackbody, normalised to unit luminance."""
    t = t / 100.0
    r = np.where(t <= 66, 255, 329.7 * (np.maximum(t - 60, 1e-3)) ** -0.1332)
    g = np.where(t <= 66, 99.47 * np.log(t) - 161.1, 288.1 * (np.maximum(t - 60, 1e-3)) ** -0.0755)
    b = np.where(t >= 66, 255, np.where(t <= 19, 0, 138.5 * np.log(np.maximum(t - 10, 1e-3)) - 305.0))
    c = np.clip(np.stack([r, g, b], 1), 0, 255) / 255.0
    c = c ** 2.2
    lum = c @ np.array([0.2126, 0.7152, 0.0722])
    return c / lum[:, None]

col = bb_rgb(temp) * flux[:, None]
pu = 0.5 + np.arctan2(d[:, 0], -d[:, 2]) / (2 * np.pi)
pv = np.arccos(np.clip(d[:, 1], -1, 1)) / np.pi
px = np.clip((pu * W).astype(int), 0, W - 1)
py = np.clip((pv * H).astype(int), 0, H - 1)
# a pixel near the poles covers less sky: keep each star's solid angle right
wgt = 1.0 / np.maximum(np.sin(pv * np.pi), 0.02)
np.add.at(img, (py, px), (col * wgt[:, None]).astype(np.float32))

# RGBE, flat scanlines
m = img.max(axis=2)
e = np.zeros_like(m, np.int32)
mant, e = np.frexp(m)
scale = np.where(m > 1e-32, mant * 256.0 / np.maximum(m, 1e-32), 0)
rgbe = np.zeros((H, W, 4), np.uint8)
rgbe[..., :3] = np.clip(img * scale[..., None], 0, 255).astype(np.uint8)
rgbe[..., 3] = np.where(m > 1e-32, e + 128, 0).astype(np.uint8)
with open(out, "wb") as f:
    f.write(b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n")
    f.write(f"-Y {H} +X {W}\n".encode())
    f.write(rgbe.tobytes())
print(out, W, "x", H, n, "stars")
