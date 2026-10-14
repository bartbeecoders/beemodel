#!/usr/bin/env python3
"""The v0.11 content library walkthrough. A script saves every kind of
asset into the library (objects with their materials, a node tree, a rig
with its skinned mesh, an action, a whole scene; one object twice under two
names), tags them, searches them, follows their dependencies and makes the
path-traced thumbnails (child processes). The test checks the library on
disk: each blob named by the hash of its bytes (recomputed here), stored
once however many assets use it. A pack is written and imported into a
fresh library twice (nothing doubles). Then, in a window (the fake
compositor), the Asset Browser shows the tiles while new thumbnails are made
in the background, a tile is dragged into the viewport and lands on the
surface under the pointer, and the same is done over MCP.

    python3 tests/library.py build/beemodel [outdir]
"""
import os, shutil, subprocess, sys, tempfile, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
CI = 2 if os.environ.get('CI') else 1
FAILS = []
M64 = (1 << 64) - 1


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def lbhash(b, seed=0):
    """library.s's lb_hash: 8 bytes a step, FNV-like, finalized."""
    h = 0xcbf29ce484222325 ^ seed
    p = 0x100000001b3
    i, n = 0, len(b)
    while n - i >= 8:
        h ^= int.from_bytes(b[i:i + 8], 'little')
        h = (h * p) & M64
        h ^= h >> 32
        i += 8
    while i < n:
        h ^= b[i]
        h = (h * p) & M64
        i += 1
    h ^= n
    h = (h * 0x9e3779b97f4a7c15) & M64
    h ^= h >> 31
    return h


def run(home, code):
    env = dict(os.environ, HOME=home, XDG_CACHE_HOME='')
    r = subprocess.run([BIN, '--eval', code], env=env, capture_output=True, text=True, timeout=300)
    out = {}
    for line in r.stdout.splitlines():
        w = line.split()
        if w:
            out[w[0]] = w[1:]
    if r.returncode != 0 or r.stderr.strip():
        print(r.stdout[-2000:], r.stderr[-2000:])
    return out


MAKE = '''
material("Gold")
matset("Gold", "base", 1, 0.77, 0.34)
matset("Gold", "metallic", 1)
matset("Gold", "roughness", 0.25)
material("Clay")
matset("Clay", "base", 0.75, 0.38, 0.22)
assign("Cube", "Gold")
add("cylinder", "Pillar", 3, 1, 0)
scale("Pillar", 0.5, 1, 0.5)
assign("Pillar", "Clay")
add("sphere", "Orb", -3, 1, 0)
modifier("Orb", "subsurf")
assign("Orb", "Gold")
select("Cube")
op("lib.save", "object GoldBox #metal #box")
select("Pillar")
op("lib.save", "object Pillar #stone #column")
select("Orb")
op("lib.save", "object Orb #metal #round")
select("Orb")
op("lib.save", "object Orb2 #metal")
select("Cube", "Pillar")
op("lib.save", "object Gate #stone #metal")
t = gtree("Steps")
o = gnode(t, "output")
g = gnode(t, "grid", 4, 8)
glink(t, g, o, 1)
op("lib.save", "tree Steps #nodes")
add("cylinder", "Limb", 0, 1, 4)
scale("Limb", 0.3, 1, 0.3)
a = armature("Rig")
move("Rig", 0, 0, 4)
op("arm.parent", "Limb Rig")
select("Limb", "Rig")
op("lib.save", "rig Puppet #character")
key("Cube:x", 1, 0)
key("Cube:x", 25, 4)
key("Cube:ry", 1, 0)
key("Cube:ry", 25, 3.14)
select("Cube")
op("anim.action", "Spin")
op("lib.save", "action Spin #move")
op("lib.save", "scene Yard #template")
op("lib.tag", "Pillar #heavy")
op("lib.tag", "Orb2 -metal")
print("count", lib(0), lib(1))
print("find", libfind("metal", 0), libfind("metal", 1), libfind("metal", 2), libfind("stone column", 0))
print("uses", libinfo("Gate", "uses"))
print("users", libinfo("Gold", "users"))
print("kinds", libinfo("Puppet", "kind"), libinfo("Spin", "kind"), libinfo("Yard", "kind"), libinfo("Steps", "kind"))
print("tags", libinfo("Pillar", "tags"), libinfo("Orb2", "tags"))
print("same", libinfo("Orb", "blob") == libinfo("Orb2", "blob"), libinfo("Orb", "id") == libinfo("Orb2", "id"))
c0 = clock()
op("lib.thumbnails")
print("thumbs", lib(2), lib(3), round(clock() - c0))
op("lib.pack", "~/BeeModel/metal.bee metal")
op("lib.pack", "~/BeeModel/all.bee")
op("file.new")
delete("Cube")
op("lib.place", "Gate 10 0 0")
op("lib.place", "Puppet -10 0 0")
print("placed", get("Cube", "x"), get("Pillar", "x"), get("Rig", "x"), get("Limb", "x"), bones("Rig"))
'''


def window(home):
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-lb-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake()
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    shutil.copytree(os.path.join(home, 'BeeModel', 'library'), os.path.join(f.home, 'BeeModel', 'library'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    res = {}
    f.enter(600, 700)
    f.move(600, 700)                                # the console area: the browser
    f.pump(0.3)
    q('op("area.type_asset_browser")')
    f.pump(0.5)
    tools = ((m.call('tools/list') or {}).get('result') or {}).get('tools', [])
    res['tools'] = sorted(t['name'] for t in tools if t['name'].startswith('op_lib_'))
    # new assets over MCP: their thumbnails are made in the background
    q('add("torus", "Ring", 0, 0, 0)\nselect("Ring")')
    m.tool('op_lib_save', {'arg': 'object Ring #mcp #round'})
    m.tool('op_lib_save', {'arg': 'object Ring2 #mcp'})
    lat, t0 = [], time.time()
    while time.time() - t0 < 30:
        f.latencies = []
        f.t_input = time.time()
        f.key(106)
        f.pump(0.05)
        lat += f.latencies
        if q('print(lib(3))') == '0':
            break
    res['bg'] = (time.time() - t0, sorted(lat), q('print(lib(2), lib(3), libinfo("Ring", "thumb"))'))
    q('op("lib.search", "")')
    f.pump(0.5)
    if OUT:
        f.shot('115_content_browser.png')
    # drag the first tile into the viewport: it lands on the cube under the pointer
    first = q('print(libfind("box", 0))')        # (the tiles: boxes only)
    f.pump(0.3)
    f.drag(240, 700, 600, 360, steps=12)
    f.pump(0.5)
    res['drop'] = q('print(active(), get(active(), "x"), get(active(), "y"), get(active(), "z"))')
    res['first'] = first
    # search narrows the tiles; over MCP an asset is placed
    q('op("lib.search", "stone")')
    f.pump(0.3)
    res['search'] = q('print(lib(4))')
    if OUT:
        f.shot('116_content_browser_search.png')
    m.tool('op_lib_place', {'arg': 'Pillar 4 0 4'})
    res['mcp_place'] = q('print(get("Pillar", "x"), get("Pillar", "z"))')
    f.proc.kill()
    return res


def main():
    print('  -- the content library --')
    home = tempfile.mkdtemp(prefix='bee-lb-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    t = time.time()
    out = run(home, MAKE)
    secs = time.time() - t
    lib = os.path.join(home, 'BeeModel', 'library')
    index = open(os.path.join(lib, 'index.txt')).read().splitlines() if os.path.exists(os.path.join(lib, 'index.txt')) else []
    blobs = os.listdir(os.path.join(lib, 'blobs')) if os.path.isdir(os.path.join(lib, 'blobs')) else []
    kinds = sorted(set(l.split('\t')[1] for l in index))
    check(out.get('count', [''])[0] == str(len(index)) and len(index) >= 10
          and kinds == ['action', 'material', 'object', 'rig', 'scene', 'tree'],
          f'{len(index)} assets saved, every kind ({", ".join(kinds)}), in {secs:.1f} s with their thumbnails')
    ok = all(lbhash(open(os.path.join(lib, 'blobs', b), 'rb').read()) == int(b[:16], 16) for b in blobs)
    used = set(l.split('\t')[3] for l in index)
    check(ok and len(blobs) == len(used) and len(blobs) < len(index),
          f'content-addressed: each of the {len(blobs)} blobs is named by the hash of its bytes; '
          f'{len(index)} assets share them (an object saved twice: one blob, {out.get("same")})')
    check(out.get('find', [])[:3] == ['GoldBox', 'Orb', 'Gate'] and out.get('find', [])[3:] == ['Pillar']
          and out.get('tags') == ['stone,column,heavy'],
          f'tags and search: "metal" {out.get("find", [])[:3]}, "stone column" {out.get("find", [])[3:]}; '
          f'tags {out.get("tags")} (Orb2: "metal" taken away)')
    check(out.get('uses') == ['Gold,', 'Clay'] and 'GoldBox,' in out.get('users', []),
          f'dependencies: Gate uses {" ".join(out.get("uses", []))}; Gold is used by {" ".join(out.get("users", []))}')
    th = out.get('thumbs', [])
    thumbs = os.listdir(os.path.join(lib, 'thumbs')) if os.path.isdir(os.path.join(lib, 'thumbs')) else []
    check(len(th) == 3 and th[0] == str(len(index)) and th[1] == '0' and len(thumbs) == len(index)
          and all(open(os.path.join(lib, 'thumbs', p), 'rb').read(4) == b'\x89PNG' for p in thumbs),
          f'{th[:1]} thumbnails path-traced by child processes in {th[2:]} ms')
    check(out.get('placed', [])[:2] == ['10', '13'],
          f'placed: Gate (two objects, their materials first) at x 10, the rig with its skinned mesh ({out.get("placed")})')
    # packs into a fresh library
    home2 = tempfile.mkdtemp(prefix='bee-lb2-')
    os.makedirs(os.path.join(home2, 'BeeModel'))
    for p in ('metal.bee', 'all.bee'):
        shutil.copy(os.path.join(home, 'BeeModel', p), os.path.join(home2, 'BeeModel', p))
    head = open(os.path.join(home2, 'BeeModel', 'all.bee'), 'rb').read(4)
    imp = run(home2, 'op("lib.import", "~/BeeModel/metal.bee")\nprint("metal", lib(0), libinfo("GoldBox", "uses"))\n'
                     'op("lib.import", "~/BeeModel/all.bee")\nprint("all", lib(0), lib(2))\n'
                     'op("lib.import", "~/BeeModel/all.bee")\nprint("again", lib(0))\n'
                     'op("lib.place", "Orb 0 0 0")\nprint("orb", matget("Gold", "metallic"))\n')
    lib2 = os.path.join(home2, 'BeeModel', 'library')
    blobs2 = os.listdir(os.path.join(lib2, 'blobs'))
    check(head == b'BEEM' and imp.get('metal', [''])[0] == '5' and imp.get('all', [''])[0] == str(len(index))
          and imp.get('again') == [str(len(index))] and len(blobs2) == len(blobs) and imp.get('orb') == ['1'],
          f'packs: a .bee file; "metal" brings 5 assets (with Gold and Clay, which they use), the whole pack the rest, '
          f'again nothing; {len(blobs2)} blobs, each once ({imp})')
    r = window(home)
    bg = r['bg']
    med = bg[1][len(bg[1]) // 2] if bg[1] else 1e9
    check(set(['op_lib_place', 'op_lib_save', 'op_lib_search', 'op_lib_pack', 'op_lib_import', 'op_lib_tag']) <= set(r['tools']),
          f'over MCP: {", ".join(r["tools"])}')
    check(bg[2].split()[1:] == ['0', '1'] and med < 25 * CI,
          f'saved over MCP, their thumbnails made in the background in {bg[0]:.1f} s while the window answered keys '
          f'in {med:.1f} ms at the median ({bg[2]})')
    d = r['drop'].split()
    on = len(d) == 4 and abs(max(abs(float(d[1])), abs(float(d[2]) - 1), abs(float(d[3]))) - 1) < 0.05
    check(on,
          f'a tile dragged into the viewport lands on the cube under the pointer ({r["first"]} at {d[1:]})')
    check(r['search'] == '2' and r['mcp_place'] == '4 4',
          f'searching "stone" leaves {r["search"]} tiles; lib.place over MCP puts Pillar at {r["mcp_place"]}')
    shutil.rmtree(home, ignore_errors=True)
    shutil.rmtree(home2, ignore_errors=True)
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nthe content library: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
