#!/usr/bin/env python3
"""Rendering an animation into a video (stage C).

C1: Render > Render Animation... opens the save dialog (animation.mp4),
the render runs as a long job, Esc stops it and keeps the frames done; a
folder and a .png name (shot.png: shot/0001.png ...) still get PNGs.

C2: .mp4 .mkv .webm .gif through ffmpeg: as many frames as rendered, the
size (odd sizes cropped to even for H.264 / VP9), the frame rate, the
pictures the PNGs have; a stand-in ffmpeg that fails is reported with
what it said, and stops the render; no ffmpeg at all says what works
without it.

C3: .apng written by BeeModel: acTL, fcTL and fdAT in order, sequence
numbers counting up, every CRC right, the frame delay from the frame rate;
the frames decode to the PNGs' pictures.

    python3 tests/video.py build/beemodel [shots dir]
"""
import os, shutil, struct, subprocess, sys, tempfile, time, zlib

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []
FFMPEG = shutil.which('ffmpeg') and shutil.which('ffprobe')

SCENE = '''n = count()
for i in 0..n { delete(name(0)) }
add("cube", "C", 0, 0.5, 0)
m = material("Red"); matset(m, "base", 0.9, 0.1, 0.05); assign("C", "Red")
add("plane", "Floor", 0, 0, 0); scale("Floor", 8)
key("C:x", 1, -1.5); key("C:x", 12, 1.5)
op("anim.range", "1 12 12")
op("render.settings", "161 91 8")
'''


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def probe(path):
    """(codec, width, height, frames, rate) by ffprobe."""
    p = subprocess.run(['ffprobe', '-v', 'error', '-count_frames', '-select_streams', 'v:0', '-show_entries',
                        'stream=codec_name,width,height,nb_read_frames,r_frame_rate', '-of', 'csv=p=0', path],
                       capture_output=True, text=True)
    r = p.stdout.strip().split(',')
    return (r[0], int(r[1]), int(r[2]), int(r[4]), r[3]) if len(r) == 5 else None


def frame_of(path, n, out):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', path, '-vf', f'select=eq(n\\,{n})', '-frames:v', '1', out],
                   check=False)
    return out


def mean_diff(a, b):
    """The mean difference of two pictures (0..255), over their shared size."""
    from PIL import Image, ImageChops
    x, y = Image.open(a).convert('RGB'), Image.open(b).convert('RGB')
    w, h = min(x.width, y.width), min(x.height, y.height)
    d = ImageChops.difference(x.crop((0, 0, w, h)), y.crop((0, 0, w, h))).convert('L')
    return sum(d.histogram()[i] * i for i in range(256)) / (w * h)


def apng_chunks(path):
    """[(type, data)], every CRC checked (None when one is wrong)."""
    d = open(path, 'rb').read()
    if d[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    i, out = 8, []
    while i + 12 <= len(d):
        n, t = struct.unpack('>I4s', d[i:i + 8])
        body = d[i + 8:i + 8 + n]
        if struct.unpack('>I', d[i + 8 + n:i + 12 + n])[0] != zlib.crc32(t + body):
            return None
        out.append((t.decode(), body))
        i += 12 + n
    return out


def main():
    home = tempfile.mkdtemp(prefix='bee-video-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    work = os.path.join(home, 'out')
    os.makedirs(work)
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-video-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    fakewl.BIN = BIN
    f = start_with(fakewl, home)
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    names = lambda: {w['name'] for w in fakewl.ui_tree(m)}

    def anim(arg, timeout=120):
        r = m.call('tools/call', {'name': 'op_render_animation', 'arguments': {'arg': arg}}, timeout=timeout)
        return ((r or {}).get('result', {}).get('content', [{}])[0].get('text', '') or '').strip()

    def at(*p):
        return os.path.join(work, *p)

    q(SCENE)
    # ---- folders: as before, and a .png name ------------------------------------------
    r = anim(at('frames'))
    got = sorted(os.listdir(at('frames'))) if os.path.isdir(at('frames')) else []
    check(got == ['%04d.png' % i for i in range(1, 13)], f'a folder: 0001.png .. 0012.png ({len(got)} files; {r!r})')
    anim(at('shot.png') + ' 3 5')
    got = sorted(os.listdir(at('shot'))) if os.path.isdir(at('shot')) else []
    check(got == ['0003.png', '0004.png', '0005.png'] and not os.path.exists(at('shot.png')),
          f'shot.png 3 5: a folder shot with frames 3 to 5 ({got})')
    # ---- C3: the animated PNG ------------------------------------------------------------
    r = anim(at('clip.apng'))
    ch = apng_chunks(at('clip.apng')) if os.path.exists(at('clip.apng')) else None
    check(ch is not None, f'clip.apng: a PNG with every CRC right ({r!r})')
    if ch:
        kinds = [t for t, _ in ch]
        actl = [struct.unpack('>II', b) for t, b in ch if t == 'acTL']
        fctl = [struct.unpack('>IIIIIHHBB', b) for t, b in ch if t == 'fcTL']
        seqs = [struct.unpack('>I', b[:4])[0] for t, b in ch if t in ('fcTL', 'fdAT')]
        check(kinds[0] == 'IHDR' and kinds[1] == 'acTL' and kinds[2] == 'fcTL' and kinds[-1] == 'IEND'
              and 'IDAT' in kinds and 'fdAT' in kinds, f'IHDR, acTL, fcTL, IDAT ... fdAT ..., IEND ({kinds[:5]} ...)')
        check(actl == [(12, 0)] and len(fctl) == 12, f'acTL: 12 frames, playing for ever; 12 fcTL ({actl}, {len(fctl)})')
        check(seqs == list(range(len(seqs))), f'sequence numbers 0, 1, 2 ... ({seqs[:6]} ...)')
        check(all(c[1:3] == (161, 91) and c[5:7] == (100, 1200) for c in fctl),
              f'each frame 161 x 91, lasting 100/1200 s (12 fps) ({fctl[0][1:7]})')
    try:
        from PIL import Image
        im = Image.open(at('clip.apng'))
        n = im.n_frames
        im.seek(5)
        im.convert('RGB').save(at('apng6.png'))
        d = mean_diff(at('apng6.png'), at('frames', '0006.png'))
        check(n == 12 and d < 1.0, f'Pillow plays 12 frames; the 6th is the 6th PNG (mean difference {d:.2f})')
    except ImportError:
        print('  skip the APNG pictures (no Pillow)')
    # ---- C2: ffmpeg ------------------------------------------------------------------------
    if FFMPEG:
        for ext, codec, size in (('mp4', 'h264', (160, 90)), ('mkv', 'h264', (160, 90)),
                                 ('webm', 'vp9', (160, 90)), ('gif', 'gif', (161, 91))):
            r = anim(at('clip.' + ext))
            p = probe(at('clip.' + ext)) if os.path.exists(at('clip.' + ext)) else None
            ok = p is not None and p[0] == codec and p[1:3] == size and p[3] == 12
            check(ok and ('clip.' + ext) in r, f'.{ext}: {codec}, {size[0]} x {size[1]}, 12 frames ({p}; {r!r})')
        p = probe(at('clip.mp4'))
        check(p is not None and p[4] == '12/1', f'the animation\'s 12 fps ({p and p[4]})')
        d = mean_diff(frame_of(at('clip.mkv'), 5, at('mkv6.png')), at('frames', '0006.png'))
        check(d < 4.0, f'the 6th frame of the video is the 6th PNG (mean difference {d:.2f})')
        r = anim(at('part.mp4') + ' 4 7')
        p = probe(at('part.mp4'))
        check(p is not None and p[3] == 4, f'part.mp4 4 7: 4 frames ({p})')
    else:
        print('  skip ffmpeg (not installed)')
    # ---- an ffmpeg that fails, none at all ---------------------------------------------------
    fake = os.path.join(home, 'ffmpeg-fails')
    open(fake, 'w').write('#!/bin/sh\necho "Unknown encoder \'libx264\'" >&2\nexit 1\n')
    os.chmod(fake, 0o755)
    f.proc.kill()                                       # (its environment: a new one)
    f = start_with(fakewl, home, BEEMODEL_FFMPEG=fake)
    m = fakewl.Mcp(f)
    q(SCENE)
    t = time.time()
    r = anim(at('bad.mp4'))
    check('ffmpeg could not make the video' in r and 'Unknown encoder' in r and 'rendered frames' not in r,
          f'a failing ffmpeg: what it said, no "rendered" ({r!r}, {time.time() - t:.1f} s)')
    f.proc.kill()
    f = start_with(fakewl, home, BEEMODEL_FFMPEG=os.path.join(home, 'no-such-ffmpeg'))
    m = fakewl.Mcp(f)
    q(SCENE)
    r = anim(at('none.mp4'))
    check('ffmpeg was not found' in r and '.apng' in r and not os.path.exists(at('none.mp4')),
          f'no ffmpeg: says so, and what works without it ({r!r})')
    f.proc.kill()
    # ---- C1: the menu, the dialog, Esc -----------------------------------------------------
    f = start_with(fakewl, home)
    m = fakewl.Mcp(f)
    q(SCENE)
    q('op("render.settings", "64 36 4")')
    fakewl.menu_pick(f, m, 'Render', 'Render Animation...')
    f.pump(0.3)
    nm = (fakewl.widget(m, 'files.name') or {}).get('value', '')
    check({'files.path', 'files.name', 'files.ok'} <= names() and nm == 'animation.mp4',
          f'Render > Render Animation... opens the save dialog with animation.mp4 ({nm!r})')
    ext = 'mp4' if FFMPEG else 'apng'
    want = os.path.join(home, 'BeeModel', 'menu.' + ext)

    def save_as(name):
        x, y = fakewl.widget_xy(m, 'files.name')
        f.click(x, y); f.pump(0.2)
        f.mods(4); f.key(30); f.mods(0)
        f.type(name); f.key(28); f.pump(0.2)
        x, y = fakewl.widget_xy(m, 'files.ok')
        f.click(x, y)

    save_as('menu.' + ext)
    q('print(1)')                                      # (answered once the job is done)
    ok = os.path.exists(want) and (probe(want)[3] == 12 if FFMPEG else True)
    check(ok, f'Save: the animation rendered into ~/BeeModel/menu.{ext}')
    q('op("anim.range", "1 600 24")')
    q('op("render.settings", "200 112 64")')
    fakewl.menu_pick(f, m, 'Render', 'Render Animation...')
    f.pump(0.3)
    save_as('long.' + ext)
    f.pump(1.5)
    f.shot('video_job.png')
    f.key(1)                                           # Esc
    t = time.time()
    q('print(1)')
    took = time.time() - t
    long_ = os.path.join(home, 'BeeModel', 'long.' + ext)
    n = (probe(long_) or (0, 0, 0, 0))[3] if FFMPEG and os.path.exists(long_) else \
        (len([c for c in apng_chunks(long_) or [] if c[0] == 'fcTL']) if os.path.exists(long_) else 0)
    check(0 < n < 600 and took < 30, f'Esc stops the render; the video has the frames done ({n} of 600, {took:.1f} s)')
    f.proc.kill()
    shutil.rmtree(home, ignore_errors=True)
    print('video: ' + ('all green' if not FAILS else f'{len(FAILS)} failed'))
    sys.exit(1 if FAILS else 0)


def start_with(fakewl, home, **env):
    """A new BeeModel in the fake compositor, with these in its environment."""
    old = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        f = fakewl.Fake(home=home)
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    f.enter(600, 300)
    return f


if __name__ == '__main__':
    main()
