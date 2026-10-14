#!/usr/bin/env python3
"""A reference reader for BeeModel's live link (docs/LIVELINK.md): what a
game engine plugin does - connect, say HELLO, take the snapshot, then apply
the changes as they come, keeping a scene of its own.

    python3 tools/livelink.py host:port | unix:/path     (prints what changes)

As a module: Reader(address) -> .poll(seconds) applies what came; .objects,
.meshes, .materials hold the scene; .log the messages (type, uid, time).
"""
import socket, struct, sys, time

HELLO, SNAP_BEGIN, SNAP_END, TICK = 1, 2, 3, 4
OBJECT, DELETE, TRANSFORM, PROPERTY = 10, 11, 12, 13
MESH, MESH_DELTA, MATERIAL = 20, 21, 30
NAMES = {1: 'HELLO', 2: 'SNAP_BEGIN', 3: 'SNAP_END', 4: 'TICK', 10: 'OBJECT', 11: 'DELETE',
         12: 'TRANSFORM', 13: 'PROPERTY', 20: 'MESH', 21: 'MESH_DELTA', 30: 'MATERIAL'}
VERSION = 1


def cstr(b):
    return b.split(b'\0', 1)[0].decode('utf-8', 'replace')


class Reader:
    def __init__(self, address, role=1, name='reader', rcvbuf=0):
        if address.startswith('unix:'):
            self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            if rcvbuf:
                self.s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
            self.s.connect(address[5:])
        else:
            host, port = address.rsplit(':', 1)
            self.s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if rcvbuf:                  # (before connecting: the window)
                self.s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, rcvbuf)
            self.s.connect((host, int(port)))
            self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b''
        self.objects, self.meshes, self.materials = {}, {}, {}
        self.peer = None
        self.synced = False
        self.log = []                   # (type, uid or None, local time ns, server tick ns)
        self.tick = None
        self.bytes = 0
        body = struct.pack('<B4sHHI32s', HELLO, b'BEEL', VERSION, role, 0, name.encode()[:31])
        self.s.sendall(struct.pack('<I', len(body)) + body)

    def poll(self, seconds=0.0):
        """Read for up to that long (0: what is there); apply whole messages."""
        end = time.time() + seconds
        self.s.setblocking(False)
        while True:
            try:
                chunk = self.s.recv(1 << 20)
                if not chunk:
                    raise ConnectionError('the session ended')
                self.buf += chunk
                self.bytes += len(chunk)
            except BlockingIOError:
                if time.time() >= end:
                    break
                time.sleep(0.0005)
            self._apply()
        self._apply()

    def until(self, pred, seconds=5.0):
        end = time.time() + seconds
        while time.time() < end:
            self.poll(0.002)
            if pred():
                return True
        return False

    def _apply(self):
        while len(self.buf) >= 4:
            n = struct.unpack_from('<I', self.buf)[0]
            if len(self.buf) < 4 + n:
                return
            msg = self.buf[4:4 + n]
            self.buf = self.buf[4 + n:]
            self._one(msg[0], msg[1:])

    def _one(self, t, p):
        now = time.monotonic_ns()
        uid = None
        if t == HELLO:
            magic, ver, role, peer = struct.unpack_from('<4sHHI', p)
            assert magic == b'BEEL' and ver == VERSION, 'not a BeeModel live link'
            self.peer = (peer, cstr(p[12:44]))
        elif t == SNAP_BEGIN:
            self.objects, self.meshes, self.materials = {}, {}, {}
            self.synced = False
        elif t == SNAP_END:
            self.synced = True
        elif t == TICK:
            self.tick = struct.unpack_from('<Q', p)[0]
        elif t == OBJECT:
            uid, typ, flags, colour, mat, mesh = struct.unpack_from('<IIIIiI', p)
            xf = struct.unpack_from('<9f', p, 56)
            self.objects[uid] = {'type': typ, 'flags': flags, 'colour': colour, 'material': mat,
                                 'mesh': mesh, 'name': cstr(p[24:56]), 'loc': xf[0:3], 'rot': xf[3:6],
                                 'scale': xf[6:9]}
        elif t == DELETE:
            uid = struct.unpack_from('<I', p)[0]
            self.objects.pop(uid, None)
            self.meshes.pop(uid, None)
        elif t == TRANSFORM:
            uid = struct.unpack_from('<I', p)[0]
            xf = struct.unpack_from('<9f', p, 4)
            if uid in self.objects:
                o = self.objects[uid]
                o['loc'], o['rot'], o['scale'] = xf[0:3], xf[3:6], xf[6:9]
        elif t == PROPERTY:
            uid, key = struct.unpack_from('<II', p)
            o = self.objects.get(uid)
            if o is not None:
                if key == 1:
                    o['name'] = cstr(p[8:40])
                elif key == 2:
                    o['material'] = struct.unpack_from('<i', p, 8)[0]
                elif key == 3:
                    o['flags'] = struct.unpack_from('<I', p, 8)[0]
                elif key == 4:
                    o['colour'] = struct.unpack_from('<I', p, 8)[0]
        elif t == MESH:
            uid, nv, npo, nl, uv = struct.unpack_from('<5I', p)
            off = 20
            pos = list(struct.unpack_from('<%df' % (nv * 3), p, off)); off += nv * 12
            starts = struct.unpack_from('<%dI' % (npo + 1), p, off); off += (npo + 1) * 4
            loops = struct.unpack_from('<%dI' % nl, p, off); off += nl * 4
            uvs = struct.unpack_from('<%df' % (nl * 2), p, off) if uv else None
            polys = [loops[starts[i]:starts[i + 1]] for i in range(npo)]
            self.meshes[uid] = {'pos': pos, 'polys': polys, 'uv': uvs}
        elif t == MESH_DELTA:
            uid, nr = struct.unpack_from('<II', p)
            off = 8
            m = self.meshes.get(uid)
            for _ in range(nr):
                first, count = struct.unpack_from('<II', p, off); off += 8
                vals = struct.unpack_from('<%df' % (count * 3), p, off); off += count * 12
                if m is not None:
                    m['pos'][first * 3:(first + count) * 3] = vals
        elif t == MATERIAL:
            idx = struct.unpack_from('<I', p)[0]
            v = struct.unpack_from('<15f', p, 36)
            self.materials[idx] = {'name': cstr(p[4:36]), 'base': v[0:3], 'metallic': v[3], 'roughness': v[4],
                                   'specular': v[5], 'ior': v[6], 'transmission': v[7], 'emission': v[8:11],
                                   'strength': v[11], 'clearcoat': v[12], 'coat_roughness': v[13], 'alpha': v[14]}
        if uid is None and t in (OBJECT, TRANSFORM, PROPERTY, MESH, MESH_DELTA):
            uid = struct.unpack_from('<I', p)[0]
        self.log.append((t, uid, now, self.tick))

    def by_name(self, name):
        for uid, o in self.objects.items():
            if o['name'] == name:
                return uid, o
        return None, None

    def close(self):
        self.s.close()


def main():
    r = Reader(sys.argv[1] if len(sys.argv) > 1 else 'localhost:7461')
    seen = 0
    while True:
        r.poll(0.05)
        for t, uid, _, _ in r.log[seen:]:
            o = r.objects.get(uid, {}) if uid else {}
            print(NAMES.get(t, t), uid or '', o.get('name', ''), o.get('loc', ''))
        seen = len(r.log)


if __name__ == '__main__':
    main()
