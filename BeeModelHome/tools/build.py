#!/usr/bin/env python3
"""Builds the static website into BeeModelHome/site/.

  - pages from src/ (index.html, releases.html) with the shared header and
    footer and the release facts filled in;
  - the releases page and an Atom feed from the repository's CHANGELOG.md,
    with each release's downloads from GitHub (gh or the public API; offline:
    the usual asset names);
  - media/ (screenshots, renders, screencasts) and the demo films
    (Vibecoding/demos/out) made web-sized: WebP images at two sizes, H.264
    MP4s with WebP posters. Missing media keep what site/ already has.

  python3 BeeModelHome/tools/build.py [--offline] [--no-media]
"""
import datetime as dt
import glob
import html
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.abspath(os.path.join(HERE, '..'))
ROOT = os.path.abspath(os.path.join(HOME, '..'))
SRC = os.path.join(HOME, 'src')
SITE = os.path.join(HOME, 'site')
MEDIA = os.path.join(HOME, 'media')
REPO = 'bartbeecoders/beemodel'
GH = 'https://github.com/' + REPO
OFFLINE = '--offline' in sys.argv
NO_MEDIA = '--no-media' in sys.argv

# media name -> where it comes from (relative to media/), or a demo film
IMAGES = {
    'studio': 'renders/studio.png', 'sculpt-render': 'renders/sculpt.png', 'valley': 'renders/valley.png',
    'gallery': 'renders/gallery.png', 'modeling': 'shots/modeling.png', 'nodes': 'shots/nodes.png',
    'cad': 'shots/cad.png', 'animation': 'shots/animation.png', 'physics': 'shots/physics.png',
    'fields': 'shots/fields.png', 'landscape': 'shots/landscape.png', 'procedural': 'shots/procedural.png',
    'sculpt': 'shots/sculpt.png',
}
VIDEOS = {
    'wrecking-ball': os.path.join(ROOT, 'Vibecoding', 'demos', 'out', 'wrecking-ball.mp4'),
    'rockfall-island': os.path.join(ROOT, 'Vibecoding', 'demos', 'out', 'rockfall-island.mp4'),
    'gallery-smash': os.path.join(ROOT, 'Vibecoding', 'demos', 'out', 'gallery-smash.mp4'),
    'tornado': os.path.join(MEDIA, 'video', 'tornado.mp4'),
    'orbits': os.path.join(MEDIA, 'video', 'orbits.mp4'),
}


# ---- the changelog --------------------------------------------------------------
def inline(text):
    """Markdown inline -> HTML: code, bold, italics, links (repo-relative ones to GitHub)."""
    out, parts = [], re.split(r'(`[^`]+`)', text)
    for p in parts:
        if p.startswith('`') and p.endswith('`') and len(p) > 1:
            out.append('<code>%s</code>' % html.escape(p[1:-1]))
            continue
        p = html.escape(p, quote=False)
        p = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', p)
        p = re.sub(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', r'<i>\1</i>', p)

        def link(m):
            label, url = m.group(1), m.group(2)
            if not re.match(r'[a-z]+:', url):
                url = '%s/blob/main/%s' % (GH, url.lstrip('./'))
            return '<a href="%s">%s</a>' % (html.escape(url), label)
        p = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', link, p)
        out.append(p)
    return ''.join(out)


def changelog():
    text = open(os.path.join(ROOT, 'CHANGELOG.md')).read()
    rel = []
    for m in re.finditer(r'^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})\n(.*?)(?=^## \[|\Z)', text, re.S | re.M):
        ver, date, body = m.group(1), m.group(2), m.group(3)
        body = re.split(r'^\[[^\]]+\]: http', body, flags=re.M)[0]    # (the compare links)
        rel.append({'version': ver, 'date': date, 'body': body.strip()})
    return rel


def render_body(body):
    """-> (summary html, sections html, plain text summary)."""
    lines = body.splitlines()
    summary, html_out, items, para = [], [], [], []
    seen_heading = False

    def flush_items():
        if items:
            html_out.append('<ul>' + ''.join('<li>%s</li>' % inline(i) for i in items) + '</ul>')
            items.clear()

    def flush_para():
        if para:
            t = ' '.join(para).strip()
            if not seen_heading and not html_out:
                summary.append(t)
            else:
                html_out.append('<p>%s</p>' % inline(t))
            para.clear()

    for line in lines:
        if line.startswith('### '):
            flush_para(); flush_items()
            seen_heading = True
            html_out.append('<h4>%s</h4>' % html.escape(line[4:].strip()))
        elif re.match(r'^\s*[-*] ', line) and not line.startswith('    '):
            flush_para()
            if line.startswith('  ') and items:                       # (a nested item: kept inline)
                items[-1] += ' — ' + re.sub(r'^\s*[-*] ', '', line)
            else:
                items.append(re.sub(r'^\s*[-*] ', '', line))
        elif line.strip() == '':
            flush_para()
            if items and not seen_heading:
                flush_items()
        elif items and line.startswith(' '):
            items[-1] += ' ' + line.strip()
        else:
            flush_items()
            para.append(line.strip())
    flush_para(); flush_items()
    s = ' '.join(summary)
    if not s:                                                        # (no lead paragraph: the first item)
        first = re.search(r'^\s*[-*] (.+)$', body, re.M)
        s = first.group(1) if first else ''
    plain = re.sub(r'[`*]|\[([^\]]+)\]\([^)]+\)', lambda m: m.group(1) or '', s)
    return inline(s), ''.join(html_out), plain


# ---- GitHub releases ---------------------------------------------------------------------
def github_releases():
    if OFFLINE:
        return {}
    data = None
    try:
        r = subprocess.run(['gh', 'api', '--paginate', 'repos/%s/releases?per_page=100' % REPO],
                           capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            data = json.loads(r.stdout.replace('][', ','))
    except (OSError, subprocess.TimeoutExpired, ValueError):
        data = None
    if data is None:
        try:
            with urllib.request.urlopen('https://api.github.com/repos/%s/releases?per_page=100' % REPO, timeout=30) as f:
                data = json.load(f)
        except OSError:
            return {}
    out = {}
    for r in data:
        out[r['tag_name'].lstrip('v')] = {
            'url': r['html_url'], 'published': r.get('published_at', ''),
            'assets': {a['name']: (a['browser_download_url'], a['size']) for a in r.get('assets', [])},
        }
    return out


def human(n):
    if n < 4096:
        return '%d bytes' % n
    return '%.1f MB' % (n / 1048576) if n > 1048576 else '%d KB' % round(n / 1024)


def downloads(ver, gh):
    """The release's files: bin, tar, gpu, sums -> (url, name, size text)."""
    base = '%s/releases/download/v%s/' % (GH, ver)
    names = {'bin': 'beemodel-%s-linux-x86_64.bin' % ver, 'tar': 'beemodel-%s-linux-x86_64.tar.gz' % ver,
             'gpu': 'beemodel-gpu-%s-linux-x86_64.tar.gz' % ver, 'sums': 'SHA256SUMS'}
    assets = (gh.get(ver) or {}).get('assets', {})
    out = {}
    for k, name in names.items():
        if name in assets:
            url, size = assets[name]
            out[k] = (url, name, human(size), size)
        else:
            out[k] = (base + name, name, '', 0)
    return out


# ---- pages ----------------------------------------------------------------------------------------
def page(name, tokens):
    text = open(os.path.join(SRC, name)).read()
    header = open(os.path.join(SRC, 'partials', 'header.html')).read()
    footer = open(os.path.join(SRC, 'partials', 'footer.html')).read()
    nav = {'NAV_FEATURES': '', 'NAV_RELEASES': ' aria-current="page"' if name == 'releases.html' else ''}
    text = text.replace('{{HEADER}}', header).replace('{{FOOTER}}', footer)
    for k, v in {**tokens, **nav}.items():
        text = text.replace('{{%s}}' % k, str(v))
    left = re.findall(r'\{\{[A-Z_]+\}\}', text)
    if left:
        sys.exit('%s: tokens not filled: %s' % (name, sorted(set(left))))
    with open(os.path.join(SITE, name), 'w') as f:
        f.write(text)


def release_cards(rels, gh, latest):
    cards = []
    for i, r in enumerate(rels):
        v = r['version']
        summ, body, _ = render_body(r['body'])
        d = downloads(v, gh)
        info = gh.get(v) or {}
        has_bin = bool(info.get('assets'))
        links = ['<a href="%s">Release page</a>' % html.escape(info.get('url', '%s/releases/tag/v%s' % (GH, v)))]
        if has_bin:
            links.insert(0, '<a href="%s">Download%s</a>' % (html.escape(d['bin'][0]), (' · ' + d['bin'][2]) if d['bin'][2] else ''))
        links.append('<a href="%s/tree/v%s">Source</a>' % (GH, v))
        date = dt.date.fromisoformat(r['date']).strftime('%-d %B %Y')
        pill = '<span class="rel-pill">LATEST</span>' if v == latest else ''
        title = ''
        m = re.match(r'^(Stage [A-Z][^.(]*|"[^"]+")', r['body'])
        cards.append('''    <article class="release%s" id="v%s">
      <div class="rel-card">
        <div class="rel-head"><h3><span class="rel-ver">v%s</span></h3>%s<span class="rel-date">%s</span>
          <div class="rel-links">%s</div></div>
        <div class="rel-sum">%s</div>
        <details%s><summary>Everything in this release</summary><div class="rel-body">%s</div></details>
      </div>
    </article>''' % (' latest' if v == latest else '', v, v, pill, date, ''.join(links), summ,
                     ' open' if i == 0 else '', body))
    return '\n'.join(cards)


def atom(rels, gh):
    now = dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    entries = []
    for r in rels[:30]:
        v = r['version']
        _, body, plain = render_body(r['body'])
        url = (gh.get(v) or {}).get('url', '%s/releases/tag/v%s' % (GH, v))
        entries.append('''  <entry>
    <title>BeeModel %s</title>
    <id>tag:beemodel.hideterms.com,2026:v%s</id>
    <link href="%s"/>
    <updated>%sT12:00:00Z</updated>
    <summary>%s</summary>
    <content type="html">%s</content>
  </entry>''' % (v, v, html.escape(url), r['date'], html.escape(plain), html.escape(body)))
    return '''<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>BeeModel releases</title>
  <id>https://beemodel.hideterms.com/releases.xml</id>
  <link href="https://beemodel.hideterms.com/releases.html"/>
  <link rel="self" href="https://beemodel.hideterms.com/releases.xml"/>
  <updated>%s</updated>
%s
</feed>
''' % (now, '\n'.join(entries))


# ---- media ---------------------------------------------------------------------------------------------
def build_media():
    from PIL import Image
    img_dir = os.path.join(SITE, 'assets', 'img')
    vid_dir = os.path.join(SITE, 'assets', 'video')
    os.makedirs(img_dir, exist_ok=True)
    os.makedirs(vid_dir, exist_ok=True)
    for name, rel in IMAGES.items():
        src = os.path.join(MEDIA, rel)
        if not os.path.exists(src):
            print('  (no %s: kept what site/ has)' % rel)
            continue
        im = Image.open(src).convert('RGB')
        for suffix, width, q in (('', 1600, 84), ('-sm', 800, 80)):
            out = im.copy()
            if out.width > width:
                out = out.resize((width, round(out.height * width / out.width)), Image.LANCZOS)
            out.save(os.path.join(img_dir, name + suffix + '.webp'), 'WEBP', quality=q, method=6)
    for name, src in VIDEOS.items():
        if not os.path.exists(src):
            print('  (no %s: kept what site/ has)' % src)
            continue
        out = os.path.join(vid_dir, name + '.mp4')
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', src, '-an', '-vf', 'scale=1280:-2',
                        '-c:v', 'libx264', '-preset', 'slow', '-crf', '27', '-pix_fmt', 'yuv420p',
                        '-movflags', '+faststart', out], check=True)
        poster = os.path.join(vid_dir, name + '.png')
        subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-ss', '2.5', '-i', out, '-frames:v', '1', poster],
                       check=True)
        Image.open(poster).convert('RGB').save(poster[:-4] + '.webp', 'WEBP', quality=80)
        os.remove(poster)
        print('  video', name, human(os.path.getsize(out)))


def main():
    os.makedirs(SITE, exist_ok=True)
    for sub in ('css', 'js', 'img'):
        d = os.path.join(SRC, 'assets', sub)
        if os.path.isdir(d):
            shutil.copytree(d, os.path.join(SITE, 'assets', sub), dirs_exist_ok=True)
    shutil.copy(os.path.join(SRC, 'favicon.svg'), SITE)
    if not NO_MEDIA:
        build_media()

    rels = changelog()
    gh = github_releases()
    # the download: the newest release whose files are published (a fresh tag's
    # release workflow takes a while); the page asks GitHub again when it loads
    published = [r['version'] for r in rels if (gh.get(r['version']) or {}).get('assets')]
    latest = published[0] if published else rels[0]['version']
    d = downloads(latest, gh)
    date = rels[[r['version'] for r in rels].index(latest)]['date']
    bin_bytes = d['bin'][3] or os.path.getsize(os.path.join(ROOT, 'build', 'beemodel')) \
        if os.path.exists(os.path.join(ROOT, 'build', 'beemodel')) else d['bin'][3]
    tokens = {
        'VERSION': latest,
        'DATE': dt.date.fromisoformat(date).strftime('%-d %B %Y'),
        'BIN_URL': d['bin'][0], 'BIN_NAME': d['bin'][1], 'BIN_SIZE': d['bin'][2] or human(bin_bytes or 1400000),
        'TAR_URL': d['tar'][0], 'TAR_NAME': d['tar'][1], 'TAR_SIZE': d['tar'][2] or '',
        'GPU_URL': d['gpu'][0], 'GPU_NAME': d['gpu'][1], 'GPU_SIZE': d['gpu'][2] or '',
        'SUMS_URL': d['sums'][0],
        'RELEASE_URL': (gh.get(latest) or {}).get('url', '%s/releases/tag/v%s' % (GH, latest)),
        'N_RELEASES': len(rels),
        'FIRST_DATE': dt.date.fromisoformat(rels[-1]['date']).strftime('%-d %B %Y'),
        'N_FILES': len(glob.glob(os.path.join(ROOT, 'src', '*.s'))),
        'BIN_MB': '%.1f' % ((bin_bytes or 1400000) / 1048576),
        'YEAR': dt.date.today().year,
        'STAMP': dt.datetime.now().strftime('%Y%m%d%H%M'),
        'RELEASES': release_cards(rels, gh, latest),
    }
    page('index.html', tokens)
    page('releases.html', tokens)
    with open(os.path.join(SITE, 'releases.xml'), 'w') as f:
        f.write(atom(rels, gh))
    with open(os.path.join(SITE, 'robots.txt'), 'w') as f:
        f.write('User-agent: *\nAllow: /\nSitemap: https://beemodel.hideterms.com/sitemap.xml\n')
    with open(os.path.join(SITE, 'sitemap.xml'), 'w') as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                '  <url><loc>https://beemodel.hideterms.com/</loc></url>\n'
                '  <url><loc>https://beemodel.hideterms.com/releases.html</loc></url>\n</urlset>\n')
    print('site/: v%s (%d releases%s), %d files' % (
        latest, len(rels), '' if gh else ', offline', sum(len(f) for _, _, f in os.walk(SITE))))


if __name__ == '__main__':
    main()
