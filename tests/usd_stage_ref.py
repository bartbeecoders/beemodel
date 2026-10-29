#!/usr/bin/env python3
"""OpenUSD's own reading of a stage (needs pxr): for each Mesh prim drawn
(not a guide / proxy, visible, active; instances too), named as BeeModel
names objects - the face count and world bounding box, Y up, metres. Prints
JSON; tests/usd.py compares file.import_usd with it (golden in fixtures).

    python3 tests/usd_stage_ref.py stage.usda > golden.json
"""
import json, re, sys
from pxr import Usd, UsdGeom


def objname(n):
    if n.startswith('sm_') and len(n) > 3:
        n = n[3:]
    n = n[:31]
    m = re.match(r'(.{1,})_mesh_\d+$', n)
    if m:
        n = m.group(1)
    return n[:26]


def read(path):
    st = Usd.Stage.Open(path)
    up, mpu = UsdGeom.GetStageUpAxis(st), UsdGeom.GetStageMetersPerUnit(st)
    xc, ref = UsdGeom.XformCache(), {}
    for prim in st.Traverse(Usd.TraverseInstanceProxies()):
        if not prim.IsA(UsdGeom.Mesh):
            continue
        im = UsdGeom.Imageable(prim)
        if im.ComputeVisibility() == 'invisible' or im.ComputePurpose() in ('guide', 'proxy'):
            continue
        m = UsdGeom.Mesh(prim)
        M = xc.GetLocalToWorldTransform(prim)
        r = ref.setdefault(objname(prim.GetName()), [0, [1e30] * 3, [-1e30] * 3])
        r[0] += sum(1 for c in m.GetFaceVertexCountsAttr().Get() if c >= 3)
        for p in m.GetPointsAttr().Get():
            w = M.Transform(p)
            w = (w[0], w[2], -w[1]) if up == 'Z' else (w[0], w[1], w[2])
            for i in range(3):
                r[1][i] = min(r[1][i], w[i] * mpu)
                r[2][i] = max(r[2][i], w[i] * mpu)
    return ref


if __name__ == '__main__':
    print(json.dumps(read(sys.argv[1]), indent=1, sort_keys=True))
