#!/usr/bin/env python3
"""The v0.11 live link walkthrough. A session in the fake compositor serves
its scene (link.serve); a reader - tools/livelink.py, what a game engine
plugin does - connects over TCP, takes the snapshot (objects, meshes,
materials) and follows the changes: transforms (latency checked against
the server's clock, under a frame), vertex edits as MESH_DELTA, topology
changes as MESH, materials, renames, hiding, deletion. A reader that stops
reading while a thousand objects keep moving gets their latest places once
it reads again (backpressure coalesces transforms). Another BeeModel
mirrors the session (beemodel --link host:port), a late reader gets the
same scene in its snapshot, and a UNIX socket works too.

    python3 tests/livelink.py build/beemodel [outdir]
"""
import os, socket, sys, tempfile, threading, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    print('  -- live link --')
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-ll-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl, livelink
    sys.argv = argv
    port = free_port()
    a = fakewl.Fake()
    a.pump(1.0, until_frame=True)
    ma = fakewl.Mcp(a)
    qa = lambda code: (ma.tool('script_eval', {'code': code})[0] or '').strip()
    qa('add("sphere", "Ball", 2, 1, 0)\nmaterial("Gold")\nmatset("Gold", "base", 1, 0.8, 0.2)\nassign("Ball", "Gold")\n'
       'op("link.serve", "%d")' % port)
    a.pump(0.2)

    # a reader: the snapshot
    r = livelink.Reader('127.0.0.1:%d' % port, rcvbuf=64 * 1024)
    stop = [False]

    def run():
        while not stop[0]:
            try:
                r.poll(0.001)
            except Exception:
                return
    th = threading.Thread(target=run)
    th.start()
    t0 = time.time()
    while not r.synced and time.time() - t0 < 3:
        time.sleep(0.01)
    names = sorted(o['name'] for o in r.objects.values())
    uid, ball = r.by_name('Ball')
    nv = len(r.meshes.get(uid, {}).get('pos', [])) // 3
    check(r.synced and r.peer and r.peer[1] == 'BeeModel' and names == ['Ball', 'Camera', 'Cube', 'Light']
          and ball and ball['loc'] == (2.0, 1.0, 0.0) and nv == int(qa('print(everts("Ball"))'))
          and r.materials.get(0, {}).get('name') == 'Gold' and ball['material'] == 0,
          f'the snapshot: HELLO, every object with its mesh and material ({names}, {nv} vertices)')

    # transforms, with the latency on the server's clock
    lat = []
    for i in range(20):
        n = len(r.log)
        qa('move("Ball", %d, 1, 0)' % i)
        t = time.time()
        while time.time() - t < 1:
            xs = [l for l in r.log[n:] if l[0] == livelink.TRANSFORM]
            if xs:
                lat.append((xs[0][2] - xs[0][3]) / 1e6)
                break
            time.sleep(0.0005)
    lat.sort()
    check(len(lat) == 20 and r.objects[uid]['loc'] == (19.0, 1.0, 0.0) and lat[len(lat) // 2] < 16.7,
          f'moves arrive as TRANSFORM within a frame: median {lat[len(lat) // 2] if lat else -1:.2f} ms '
          f'from the server\'s TICK, worst {lat[-1] if lat else -1:.2f} ms')

    # a vertex: MESH_DELTA; a modifier: the whole MESH
    n = len(r.log)
    qa('vmove("Ball", 5, 0, 3, 0)')
    time.sleep(0.3)
    deltas = [l for l in r.log[n:] if l[0] == livelink.MESH_DELTA]
    check(len(deltas) == 1 and r.meshes[uid]['pos'][15:18] == [0.0, 3.0, 0.0],
          f'a vertex moved: one MESH_DELTA, the vertex there ({r.meshes[uid]["pos"][15:18]})')
    n = len(r.log)
    qa('select("Ball")\nop("object.modifier_add", "subsurf")')
    time.sleep(0.3)
    meshes = [l for l in r.log[n:] if l[0] == livelink.MESH]
    nv2 = len(r.meshes[uid]['pos']) // 3
    check(len(meshes) == 1 and nv2 == int(qa('print(everts("Ball"))')) and nv2 > nv,
          f'a modifier changes the topology: a MESH with the evaluated mesh ({nv} -> {nv2} vertices)')

    # material, name, hidden, deleted, new
    qa('matset("Gold", "roughness", 0.2)\nop("object.hide")')
    qa('select("Cube")\nop("object.duplicate")')
    time.sleep(0.3)
    mat = r.materials.get(0, {})
    hidden = r.objects[uid]['flags'] & 0x200
    dup = r.by_name('Cube.001')[1]
    check(abs(mat.get('roughness', 0) - 0.2) < 1e-6 and hidden and dup is not None,
          f'a material value (MATERIAL), hiding (PROPERTY), a duplicate (OBJECT) ({mat.get("roughness")}, '
          f'{hidden}, {dup and dup["name"]})')
    qa('delete("Cube.001")\nset("Cube", "x", 0)')
    time.sleep(0.3)
    check(r.by_name('Cube.001')[0] is None, 'deleted: DELETE')

    # a mirror: another BeeModel
    b = fakewl.Fake(['--link', '127.0.0.1:%d' % port])
    b.pump(1.0, until_frame=True)
    mb = fakewl.Mcp(b)
    qb = lambda code: (mb.tool('script_eval', {'code': code})[0] or '').strip()
    for _ in range(8):
        a.pump(0.05)
        b.pump(0.05)
    qa('move("Ball", -3, 2, 1)\nvmove("Ball", 7, 1, 1, 1)\nadd("cube", "Box", 5, 0.5, 5)\nset("Box", "ry", 0.5)')
    for _ in range(8):
        a.pump(0.05)
        b.pump(0.05)
    look = ('print(count(), get("Ball", "x"), get("Ball", "y"), everts("Ball"), get("Box", "ry"), matof("Ball"), '
            'round(matget("Gold", "roughness") * 10))')
    sa, sb = qa(look), qb(look)
    if OUT:
        b.shot('124_live_link_mirror.png')
    check(sa == sb and qb('print(livelink(4))') == '1',
          f'beemodel --link mirrors the session ({sb})')
    b.proc.kill()

    # backpressure: a reader that stops reading
    qa('for i in 0..1000 { add("cube", "M" + str(i), i % 40, 0, i / 40) }')
    time.sleep(0.5)
    stop[0] = True
    th.join()
    t0 = len([l for l in r.log if l[0] == livelink.TRANSFORM])
    for k in range(60):                            # it does not read now
        qa('for i in 0..1000 { set("M" + str(i), "y", %d) }' % (k + 1))
    coal = float(qa('print(livelink(6))'))
    r.poll(0.5)
    for _ in range(20):
        a.pump(0.05)
        r.poll(0.05)
    got = len([l for l in r.log if l[0] == livelink.TRANSFORM]) - t0
    ys = set(o['loc'][1] for o in r.objects.values() if o['name'].startswith('M'))
    check(coal > 0 and got < 60 * 1000 and ys == {60.0},
          f'backpressure: a reader behind gets fewer transforms ({got} for 60 x 1000 moves, {coal:.0f} held back), '
          f'each object at its latest place ({sorted(ys)})')

    # a late reader: the same scene in its snapshot
    r2 = livelink.Reader('127.0.0.1:%d' % port)
    r2.until(lambda: r2.synced, 3)
    same = all(r2.objects.get(u, {}).get('loc') == o['loc'] and r2.objects[u]['name'] == o['name']
               for u, o in r.objects.items()) and len(r2.objects) == len(r.objects)
    check(same and len(r2.objects) == int(qa('print(count())')),
          f'a reader joining later gets the same scene ({len(r2.objects)} objects)')
    r2.close()
    r.close()

    # a UNIX socket
    path = os.path.join(tempfile.mkdtemp(prefix='bee-ll-'), 'link.sock')
    qa('op("link.serve", "unix:%s")' % path)
    r3 = livelink.Reader('unix:' + path)
    r3.until(lambda: r3.synced, 3)
    check(r3.synced and r3.by_name('Ball')[0] is not None and qa('print(livelink(0))') == '1',
          f'served on a UNIX socket too ({len(r3.objects)} objects)')
    r3.close()
    qa('op("link.stop")')
    check(qa('print(livelink(0))') == '0', 'link.stop')
    a.proc.kill()
    print(f'\n{len(FAILS)} failure(s)' if FAILS else '\nlive link: all checks passed')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
