#!/usr/bin/env python3
"""Reference images from a folder of drawings (object.add_references).

A plan set is made here, as an architect's office sends it: one PDF per
drawing, named with the Belgian / Dutch codes (G_N_01_voorgevel: an
elevation, new; P_N_00: a plan, ground floor; _B_: the existing state), a
legend, a PDF of several pages whose title blocks carry the codes, one page
without a scale, a photo and a text file. Then, in the fake compositor:

  - every page is sorted out (kind, level, existing or new) and its scale
    read from its text; a page without one takes its PDF's;
  - the references come in at their true size (an A4 sheet at 1:50 is
    14.85 m wide), turned for their kind (elevations stood up facing their
    side, plans flat at 3 m a level), in a folder of their own: the new
    elevations and the ground floor shown, the rest in hidden folders;
  - the pages are drawn once (poppler), into ~/BeeModel/References/<set>;
    a second import uses them as they are;
  - one undo step takes it all back;
  - AI > Line Up References with AI hands the set to the AI Assistant (a
    stand-in Claude Code): it sees each page (reference_view, a PNG, zoomed
    in on a part), re-sorts one (object.reference_kind) and pins a corner
    to the origin (object.reference_pin);
  - without poppler, the PDFs are left out with a note; images still come.

    python3 tests/refs.py build/beemodel [outdir]
"""
import json, os, sys, tempfile, time, zlib, struct

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


# ---- a small PDF writer: pages of text (Helvetica) and lines ----------------
def pdf(path, pages):
    """pages: [(width pt, height pt, [(x, y, size, text)], [(x0, y0, x1, y1)])]"""
    objs = [b'<< /Type /Catalog /Pages 2 0 R >>', None,
            b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>']
    kids = []
    for w, h, texts, lines in pages:
        ops = [b'0.6 w']
        for x0, y0, x1, y1 in lines:
            ops.append(b'%g %g m %g %g l S' % (x0, y0, x1, y1))
        for x, y, size, t in texts:
            t = t.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
            ops.append(b'BT /F1 %g Tf %g %g Td (' % (size, x, y) + t.encode('cp1252') + b') Tj ET')
        body = b'\n'.join(ops)
        objs.append(b'<< /Length %d >>\nstream\n' % len(body) + body + b'\nendstream')
        content = len(objs)
        objs.append(b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %g %g] /Contents %d 0 R '
                    b'/Resources << /Font << /F1 3 0 R >> >> >>' % (w, h, content))
        kids.append(len(objs))
    objs[1] = b'<< /Type /Pages /Kids [%s] /Count %d >>' % (
        b' '.join(b'%d 0 R' % k for k in kids), len(kids))
    out = bytearray(b'%PDF-1.4\n')
    offs = []
    for i, o in enumerate(objs):
        offs.append(len(out))
        out += b'%d 0 obj\n' % (i + 1) + o + b'\nendobj\n'
    x = len(out)
    out += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    for o in offs:
        out += b'%010d 00000 n \n' % o
    out += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, x)
    open(path, 'wb').write(out)


A4L = (842, 595)


def sheet(title, scale, extra=()):
    """An A4 landscape drawing: a building outline, a title block."""
    texts = [(30, 40, 9, 'Bouwheer: Peeters'), (30, 28, 9, title)]
    if scale:
        texts.append((400, 28, 9, 'schaal: ' + scale))
    texts += list(extra)
    lines = [(100, 120, 700, 120), (150, 120, 150, 400), (650, 120, 650, 400), (150, 400, 650, 400)]
    return (A4L[0], A4L[1], texts, lines)


def png(path, w, h):
    raw = b''.join(b'\0' + bytes([200, 120, 60]) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                           + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def make_set(d):
    os.makedirs(d)
    pdf(os.path.join(d, 'Huis_G_N_01_voorgevel.pdf'), [sheet('G_N Voorgevel', '1:50')])
    pdf(os.path.join(d, 'Huis_G_B_01_voorgevel.pdf'), [sheet('G_B Voorgevel', '1:50')])
    pdf(os.path.join(d, 'Huis_G_N_02_gevel rechts.pdf'), [sheet('G_N Gevel rechts', '1:50')])
    pdf(os.path.join(d, 'Huis_P_N_00_plan gelijkvloers.pdf'), [sheet('P_N Plan gelijkvloers', '1:50')])
    pdf(os.path.join(d, 'Huis_P_N_01_plan verdieping.pdf'), [sheet('P_N Plan verdieping', '1:50')])
    pdf(os.path.join(d, 'Huis_P_N_-1_plan kelder.pdf'), [sheet('P_N Plan kelder', '1:50')])
    pdf(os.path.join(d, 'Huis_L_legende.pdf'), [sheet('Legende', None)])
    pdf(os.path.join(d, 'Dossier.pdf'), [sheet('S_N Doorsnede A-A', '1:100'),
                                         sheet('G_N Achtergevel', '1:100'),
                                         sheet('I_N Inplantingsplan', None)])
    png(os.path.join(d, 'foto straatzijde.png'), 400, 300)
    open(os.path.join(d, 'notes.txt'), 'w').write('not a drawing\n')


def main():
    home = tempfile.mkdtemp(prefix='bee-refs-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    src = os.path.join(home, 'Plannen', 'Woning Peeters')
    make_set(src)
    bindir = os.path.join(home, 'bin')              # the stand-in Claude Code
    os.makedirs(bindir)
    os.symlink(os.path.join(HERE, 'ai_standin.py'), os.path.join(bindir, 'claude'))
    os.environ['PATH'] = bindir + ':' + os.environ['PATH']
    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-refs-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    fakewl.BIN = BIN

    def start():
        f = fakewl.Fake(home=home)
        f.pump(1.0, until_frame=True)
        f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
        f.enter(600, 300)
        f.move(600, 300)
        f.key(28); f.type('agent.permission_files'); f.key(28); f.key(1)   # (the test is the agent)
        f.pump(0.2)
        return f, fakewl.Mcp(f)

    print('  -- a folder of drawings --')
    f, m = start()
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    num = lambda name, prop: float(q('print(get("%s", "%s"))' % (name, prop)) or 'nan')
    t0 = time.time()
    rep, _ = m.tool('run_operator', {'id': 'object.add_references', 'arg': src})
    took = time.time() - t0
    rep = rep or ''
    print('\n'.join('     | ' + ln for ln in rep.split('\n') if ln.startswith('    ')))
    check('references: 10 pages from 9 files into the folder Refs Woning Peeters' in rep,
          f'10 pages from the 8 PDFs and the photo, the text file left out ({took:.1f} s)')
    want = ['front      voorgevel 1:50, shown',
            'front      voorgevel 1:50, existing, hidden',
            'right      gevel rechts 1:50, shown',
            'plan       plan gelijkvloers level 0 1:50, shown',
            'plan       plan verdieping level 1 1:50, hidden',
            'plan       plan kelder level -1 1:50, hidden',
            'legend     legende (a legend: left out)',
            'section    doorsnede a-a p1 1:100, hidden',
            'back       achtergevel p2 1:100, shown',
            'site       inplantingsplan p3 1:100 (from other pages), hidden',
            'other      foto straatzijde no scale: 10 m wide, hidden']
    missing = [w for w in want if w not in rep]
    check(not missing, 'each page sorted out by its name or its title block, its scale from its text '
          '(a page without one: its PDF\'s), existing ones and the legend apart' + (f' (missing {missing})' if missing else ''))

    sx, sz = num('Ref voorgevel', 'sx'), num('Ref voorgevel', 'sz')
    check(abs(sx * 2 - 14.85) < 0.05 and abs(sz * 2 - 10.49) < 0.05,
          f'true size: an A4 sheet at 1:50 is 14.85 x 10.49 m ({sx * 2:.2f} x {sz * 2:.2f})')
    sx2 = num('Ref achtergevel', 'sx')
    check(abs(sx2 * 2 - 29.7) < 0.1, f'and at 1:100 twice that ({sx2 * 2:.2f} m)')
    import math
    rx, ry = num('Ref voorgevel', 'rx'), num('Ref achtergevel', 'ry')
    rr, rl = num('Ref gevel rechts', 'ry'), num('Ref plan gelijkvloers', 'rx')
    deg = (lambda a: a) if abs(rx) > 7 else math.degrees
    check(abs(deg(rx) - 90) < 0.5 and abs(abs(deg(ry)) - 180) < 0.5 and abs(deg(rr) - 90) < 0.5 and abs(rl) < 1e-4,
          f'elevations stood up facing their side (front {deg(rx):.0f}, back {deg(ry):.0f}, right {deg(rr):.0f}), plans flat')
    y0, y1, ym = num('Ref plan gelijkvloers', 'y'), num('Ref plan verdieping', 'y'), num('Ref plan kelder', 'y')
    ye = num('Ref voorgevel', 'y')
    check(abs(y0) < 1e-4 and abs(y1 - 3) < 1e-4 and abs(ym + 3) < 1e-4 and abs(ye - 10.49 / 2) < 0.05,
          f'plans at 3 m a level ({ym:g}, {y0:g}, {y1:g}), an elevation on the ground ({ye:.2f})')
    fold = q('print(infolder("Ref voorgevel"), infolder("Ref voorgevel B"), infolder("Ref plan verdieping"), '
             'infolder("Ref doorsnede a-a"), infolder("Ref foto straatzijde"))')
    hid = q('print(get("Ref voorgevel", "hidden"), get("Ref voorgevel B", "hidden"), get("Ref plan gelijkvloers", "hidden"), '
            'get("Ref plan verdieping", "hidden"), get("Ref doorsnede a-a", "hidden"), get("Ref achtergevel", "hidden"))')
    check(fold == 'Elevations Existing Plans Sections Other drawings' and hid == '0 1 0 1 1 0',
          f'in folders: the new elevations and the ground floor shown, the rest hidden ({fold}; {hid})')
    d = os.path.join(home, 'BeeModel', 'References', 'Woning Peeters')
    pngs = sorted(n for n in os.listdir(d) if n.endswith('.png')) if os.path.isdir(d) else []
    check('Huis_G_N_01_voorgevel.png' in pngs and 'Dossier-p3.png' in pngs and len(pngs) == 10,
          f'the pages drawn into ~/BeeModel/References/Woning Peeters ({len(pngs)} PNGs)')
    if OUT:
        f.key(79); f.pump(0.4)                      # Numpad 1: the front
        f.shot('150_refs_front.png')
        f.key(71); f.pump(0.4)                      # Numpad 7: the top
        f.shot('151_refs_top.png')

    t = os.path.getmtime(os.path.join(d, 'Huis_G_N_01_voorgevel.png'))
    rep2, _ = m.tool('run_operator', {'id': 'object.add_references', 'arg': src})
    t2 = os.path.getmtime(os.path.join(d, 'Huis_G_N_01_voorgevel.png'))
    check(t2 == t and 'into the folder Refs Woning Peeters.001' in (rep2 or ''),
          'a second import uses the pages drawn before, into a folder of its own')
    n = q('print(count())')
    f.move(400, 300)
    f.mods(4); f.key(44); f.mods(0); f.pump(0.3)     # Ctrl+Z
    n2 = q('print(count())')
    check(n == '23' and n2 == '13', f'one undo step takes an import back ({n} objects, then {n2})')

    # the dialog: Add > Reference Images from Folder..., the folder typed,
    # OK with nothing picked takes the folder shown
    fakewl.menu_pick(f, m, 'Add', 'Reference Images from Folder...')
    f.pump(0.3)
    x, y = fakewl.widget_xy(m, 'files.path')
    f.click(x, y); f.pump(0.1)
    f.mods(4); f.key(30); f.mods(0)                 # Ctrl+A: the path typed over
    f.type(src); f.key(28); f.pump(0.3)
    x, y = fakewl.widget_xy(m, 'files.ok')
    f.click(x, y); f.pump(0.5)
    n3 = q('print(count())')
    fold = q('print(infolder("Ref plan gelijkvloers"))')
    check(n3 == '23' and fold == 'Plans', f'from the menu: the file dialog takes the folder shown ({n3} objects)')

    # the AI: AI > Line Up References with AI (the last import's set)
    print('  -- with the AI --')
    fakewl.menu_pick(f, m, 'AI', 'Line Up References with AI')
    end = time.time() + 20
    while time.time() < end:
        t = [ln for ln in m.tool('op_ai_transcript')[0].split('\n') if ln.startswith('$ ')]
        if t and 'idle' in t[0] and len(t) > 2:
            break
        f.pump(0.2)
    log = os.path.join(home, 'refs.ai.json')
    got = json.load(open(log)) if os.path.exists(log) else {'names': [], 'calls': []}
    args = json.load(open(os.path.join(home, 'claude.runs.json')))[-1]['args']
    sent = args[1] if len(args) > 1 else ''
    tx = '\n'.join(t)
    if os.environ.get('REFS_DEBUG'):
        print(tx); print(sent[-1500:]); print(json.dumps(got['calls'], indent=1)[:2000])
    check('Y > Line up the reference drawings in Refs Woning Peeters.001' in tx and len(got['names']) == 10
          and '- Ref voorgevel.001: stands facing +Z (the front' in sent and 'reference_pin' in sent
          and '- Ref plan verdieping.001: lies flat' in sent and '; hidden, 14.859 x 10.503 m, 1170 x 827 px' in sent,
          f'the AI is asked to line up the set: the rules and each reference, how it stands ({len(got["names"])} of them)')
    c = got['calls']
    check(len(c) == 4 and c[0][2] == ['text', 'image'] and '1170 x 827 px; 1 px = 0.025400 m' in c[0][3]
          and 'x 10..110, y 20..70 at 1/1' in c[1][3],
          'reference_view shows it the page (a PNG) and its size, and a part of it closer')
    x, y, z = num('Ref voorgevel', 'x'), num('Ref voorgevel', 'y'), num('Ref voorgevel', 'z')
    u, v = 100 / 1170 * 2 - 1, 700 / 827 * 2 - 1                  # where that pixel is now
    w, h = num('Ref voorgevel', 'sx') * 2, num('Ref voorgevel', 'sz') * 2
    pin = (x + u * w / 2, y - v * h / 2, z)
    rk = q('print(infolder("Ref doorsnede a-a"), get("Ref doorsnede a-a", "hidden"))')
    check(len(c) == 4 and not c[2][2] and max(abs(p) for p in pin) < 0.001 and rk == 'Elevations 0',
          f'it pins the front elevation\'s pixel to the origin ({pin[0]:.3f} {pin[1]:.3f} {pin[2]:.3f}) '
          f'and makes the section a left elevation ({rk})')
    # one PDF of a section alone: shown (nothing else would be)
    one = os.path.join(home, 'Plannen', 'Huis_S_N_04_snede DD.pdf')
    pdf(one, [sheet('S_N Snede DD', '1:50')])
    rep3, _ = m.tool('run_operator', {'id': 'object.add_references', 'arg': one})
    hid = q('print(get("Ref snede dd", "hidden"), infolder("Ref snede dd"))')
    check('section    snede dd 1:50, shown' in (rep3 or '') and hid.startswith('0 Sections'),
          f'one section on its own comes in shown ({hid})')

    f.proc.kill()

    print('  -- without poppler --')
    path = os.environ['PATH']
    os.environ['PATH'] = tempfile.mkdtemp(prefix='bee-nopath-')
    try:
        f, m = start()
    finally:
        os.environ['PATH'] = path
    rep, _ = m.tool('run_operator', {'id': 'object.add_references', 'arg': src})
    rep = rep or ''
    print('\n'.join('     | ' + ln for ln in rep.split('\n') if 'references' in ln))
    check('PDFs left out: 8 (they need poppler-utils' in rep and 'references: 1 pages from 9 files' in rep,
          'without poppler: the 8 PDFs left out, saying what to install; the photo still comes in')
    f.proc.kill()
    print('refs: ' + ('all passed' if not FAILS else '%d failed' % len(FAILS)))
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
