#!/usr/bin/env python3
"""The v0.14 AI Assistant walkthrough, with no network and no account.

Stand-ins for the claude and grok programs (tests/ai_standin.py, on PATH in
the test's HOME) talk to BeeModel through the MCP bridge as the real ones
do and print the real stream formats; OpenRouter is a localhost server that
answers with scripted tool calls and checks what it is sent. In a window
(the fake compositor):

  - Ctrl+Shift+Space makes the AI workspace and puts the caret in the
    prompt; a prompt typed and sent with Enter is built by the stand-in
    claude: its text, tool calls and results show in the transcript, the
    scene has the tower, and Revert takes it all back in one step;
  - a follow-up resumes the session; Stop ends a slow request at once
    (and frames keep coming while it runs); a failing CLI says so;
  - the Grok CLI: its own agent directory and MCP configuration;
  - OpenRouter: the tool loop runs in-process (curated tools only, the key
    in a header file only the user can read) until the model answers, or
    the step limit; the world recipe of the system prompt builds terrain,
    a house, materials, a light and a camera;
  - Preferences > AI: the Test buttons; MCP's build_world prompt;
  - Ollama (local): OpenRouter's tool loop against a local server, with no
    key and with thinking off; its Test says whether it has the model.

    python3 tests/ai.py build/beemodel [outdir]
"""
import http.server, json, os, stat, sys, tempfile, threading, time

BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else 'build/beemodel')
OUT = sys.argv[2] if len(sys.argv) > 2 else None
HERE = os.path.dirname(os.path.abspath(__file__))
FAILS = []
KEY = 'sk-or-test-0123456789'


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


# ---- a stand-in OpenRouter ---------------------------------------------------
WORLD = '''t = gtree("Land")
n = gnode(t, "terrain", 40, 64, 4, 7)
o = gnode(t, "output")
glink(t, n, o, 1)
g = add("plane", "Ground")
k = modifier(g, "geometry")
modset(g, k, "tree", t)
h = add("cube", "House", 0, 1, 0)
scale(h, 2, 1, 1.5)
r = add("cone", "Roof", 0, 2.6, 0)
scale(r, 2.6, 0.8, 2.2)
m = material("Stone")
matset(m, "base", 0.5, 0.5, 0.48)
assign(h, m)
p = material("Planks")
op("material.preset", "wood Planks")
assign(r, p)
s = add("light", "Sun", 4, 8, 3)
op("light.set", "power 3")
c = add("camera", "Shot", 0, 2, 12)
rotate(c, -10deg, 0, 0)
op("camera.set", "active")
print("world", count())'''

SEEN = []
LOCAL = []                                          # what the stand-in Ollama was sent


def call(i, name, args):
    return {'id': 'call_%d' % i, 'type': 'function',
            'function': {'name': name, 'arguments': json.dumps(args)}}


class OpenRouter(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def authorized(self):
        return self.headers.get('Authorization') == 'Bearer ' + KEY

    def do_GET(self):
        if self.path.startswith('/ollama/'):            # a stand-in Ollama: no key
            if self.path.endswith('/models'):
                return self.reply(200, {'object': 'list', 'data': [{'id': 'other:7b'}, {'id': 'test-local:1b'}]})
            return self.reply(404, {'error': {'message': 'not found'}})
        if self.path.endswith('/key') and self.authorized():
            self.reply(200, {'data': {'label': 'test', 'usage': 0}})
        else:
            self.reply(401, {'error': {'message': 'No auth credentials found', 'code': 401}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        local = self.path.startswith('/ollama/')
        (LOCAL if local else SEEN).append({'auth': self.headers.get('Authorization'), 'body': body, 'path': self.path})
        if not local and not self.authorized():
            return self.reply(401, {'error': {'message': 'No auth credentials found', 'code': 401}})
        msgs = body['messages']
        user = [m['content'] for m in msgs if m['role'] == 'user'][-1]
        done = 0                                    # tool results since that prompt
        for m in reversed(msgs):
            if m['role'] == 'user':
                break
            done += m['role'] == 'tool'
        msg = {'role': 'assistant', 'content': None}
        if 'loop' in user:                          # never done: the step limit
            msg['tool_calls'] = [call(done, 'scene_summary', {})]
        elif 'world' in user:
            if done == 0:
                msg['tool_calls'] = [call(0, 'scene_summary', {})]
            elif done == 1:
                msg['tool_calls'] = [call(1, 'script_eval', {'code': WORLD})]
            else:
                msg['content'] = 'A valley with a stone house, a wooden roof, the sun and a camera.'
        elif done == 0:
            msg['content'] = 'Let me look first.'
            msg['tool_calls'] = [call(0, 'scene_summary', {})]
        elif done == 1:
            code = 'for i in 0..4 { add("sphere", "Ring" + str(i), cos(i * 1.5708) * 3, 1, sin(i * 1.5708) * 3) }'
            msg['tool_calls'] = [call(1, 'script_eval', {'code': code}),
                                 call(2, 'select', {'names': ['Ring0']})]
        else:
            msg['content'] = 'Made a ring of 4 spheres.'
        self.reply(200, {'id': 'gen-1', 'model': body.get('model'),
                         'choices': [{'index': 0, 'finish_reason': 'stop', 'message': msg}]})


# ---- the walkthrough -----------------------------------------------------------
def main():
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), OpenRouter)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    home = tempfile.mkdtemp(prefix='bee-ai-')
    os.makedirs(os.path.join(home, 'BeeModel'))
    cfg = os.path.join(home, '.config', 'beemodel')
    os.makedirs(cfg)
    with open(os.path.join(cfg, 'prefs'), 'w') as fp:
        fp.write('openrouter_url http://127.0.0.1:%d/api/v1\nopenrouter_steps 4\n'
                 'openrouter_model test/model\n' % srv.server_port)
        fp.write('ollama_url http://127.0.0.1:%d/ollama/v1/\nollama_model test-local:1b\n' % srv.server_port)
    bindir = os.path.join(home, 'bin')
    os.makedirs(bindir)
    for n in ('claude', 'grok'):
        os.symlink(os.path.join(HERE, 'ai_standin.py'), os.path.join(bindir, n))
    os.environ['PATH'] = bindir + ':' + os.environ['PATH']
    os.environ.pop('OPENROUTER_API_KEY', None)

    argv = sys.argv
    sys.argv = [argv[0], OUT or tempfile.mkdtemp(prefix='bee-ai-shots-')]
    sys.path.insert(0, os.path.join(HERE, '..', 'tools'))
    import fakewl
    sys.argv = argv
    f = fakewl.Fake(home=home)
    f.pump(1.0, until_frame=True)
    f.keymap(os.path.join(HERE, 'keymaps', 'us.xkb'))
    m = fakewl.Mcp(f)
    q = lambda code: (m.tool('script_eval', {'code': code})[0] or '').strip()
    f.enter(600, 300)
    f.move(600, 300)

    def transcript():                               # "$ ai: idle|busy n", "$ <kind> <text>"
        return [ln for ln in m.tool('op_ai_transcript')[0].split('\n') if ln.startswith('$ ')]

    def wait_idle(secs=20):
        end = time.time() + secs
        t = transcript()
        while time.time() < end:
            if t and 'idle' in t[0]:
                break
            f.pump(0.1)
            t = transcript()
        return t

    def send(text):
        x, y = fakewl.widget_xy(m, 'ai.prompt')
        f.click(x, y)
        f.pump(0.1)
        f.type(text)
        f.key(28)                                   # Enter
        f.pump(0.2)

    def connection(row):                            # 0 Claude Code, 1 Grok, 2 OpenRouter, 3 Ollama
        fakewl.pick_enum(f, m, 'ai.connection', 0, row)
        return (fakewl.widget(m, 'ai.connection') or {}).get('value')

    # -- AI mode: the workspace, the caret in the prompt
    print('  -- the AI Assistant: Claude Code --')
    f.mods(5); f.key(57); f.mods(0)                 # Ctrl+Shift+Space
    f.pump(0.4)
    names = {w['name'] for w in fakewl.ui_tree(m)}
    check({'ai.prompt', 'ai.send', 'ai.connection', 'ai.new'} <= names,
          'Ctrl+Shift+Space makes the AI workspace: the connection, New, the transcript, the prompt and Send')
    f.type('build a tower')
    f.key(28)
    t = wait_idle()
    check('$ Y > build a tower' in '\n'.join(t) and q('print(exists("Tower2"))') == '1',
          'the caret was in the prompt: typed and sent with Enter, the stand-in claude built the tower')
    tx = '\n'.join(t)
    check('A Looking at the scene first.' in tx and 'T   scene_summary {}' in tx
          and 'T   script_eval {"code":' in tx and 'R   = built 6' in tx
          and 'A Built a tower of 3 cubes.' in tx and 'A Ask for a roof next.' in tx,
          'the transcript: the model\'s text (a line each), its tool calls (no mcp__beemodel__) and results')
    runs = json.load(open(os.path.join(home, 'claude.runs.json')))
    a = runs[-1]['args']
    mcpcfg = json.load(open(a[a.index('--mcp-config') + 1]))['mcpServers']['beemodel']
    check(a[:2] == ['-p', 'build a tower'] and 'stream-json' in a and '--verbose' in a
          and '--strict-mcp-config' in a and a[a.index('--allowedTools') + 1] == 'mcp__beemodel'
          and a[a.index('--max-turns') + 1] == '100' and '--resume' not in a,
          'claude -p ... --output-format stream-json --strict-mcp-config --allowedTools mcp__beemodel --max-turns 100')
    sysprompt = a[a.index('--append-system-prompt') + 1]
    check('scene_summary' in sysprompt and 'script_eval' in sysprompt and 'Y is up' in sysprompt,
          'the world-building instructions go with it (--append-system-prompt)')
    check(mcpcfg['args'] == ['--mcp-bridge'] and os.path.samefile(mcpcfg['command'], BIN)
          and mcpcfg['env']['BEEMODEL_SOCKET'].startswith(home) and 'beemodel-' in mcpcfg['env']['BEEMODEL_SOCKET'],
          'its MCP configuration: this program as the bridge, for this instance\'s socket')
    if OUT:
        f.shot('140_ai_assistant.png')
    w = fakewl.wait_widget(f, m, 'ai.copy')
    clip = ''
    if w:
        f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
        f.pump(0.3)
        clip = f.clipboard() or ''
    check(clip.startswith('> build a tower\n') and 'Looking at the scene first.\n' in clip
          and '  scene_summary {}\n' in clip and 'Ask for a roof next.\n' in clip,
          'Copy puts the whole conversation on the clipboard, a line an entry')
    full = clip
    p = fakewl.widget(m, 'ai.text')                         # selecting a part of it
    sel = dbl = ''
    if p:
        y = p['y'] + 8                                      # (the first line)
        f.drag(p['x'] + 12, y, p['x'] + 90, y, steps=4)
        f.pump(0.2)
        f.move(p['x'] + 40, y)
        f.mods(4); f.key(46); f.mods(0); f.pump(0.3)        # Ctrl+C
        sel = f.clipboard() or ''
        f.click(p['x'] + 40, y); f.click(p['x'] + 40, y); f.pump(0.2)   # a double-click
        f.mods(4); f.key(46); f.mods(0); f.pump(0.3)
        dbl = f.clipboard() or ''
    check(0 < len(sel) < 20 and sel in full and '\n' not in sel,
          f'a drag over the text selects part of a line; Ctrl+C copies just that ({sel!r})')
    check(len(dbl) > len(sel) and dbl.strip() in full and '\n' not in dbl.strip(),
          f'a double-click selects a whole message ({dbl!r})')
    w = fakewl.wait_widget(f, m, 'ai.revert')
    check(w is not None, 'Revert shows once the AI changed the scene')
    if w:
        f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
        f.pump(0.3)
    check(q('print(exists("Tower0"), exists("Tower2"), exists("Cube"))') == '0 0 1',
          'Revert: the whole request (three cubes from two tool calls) undone in one step')

    send('build again')
    t = wait_idle()
    runs = json.load(open(os.path.join(home, 'claude.runs.json')))
    a = runs[-1]['args']
    check('--resume' in a and a[a.index('--resume') + 1] == 'sess-1' and q('print(exists("Tower2"))') == '1',
          'a follow-up resumes the conversation (--resume <the session id>)')

    send('a slow one')
    f.pump(0.5)
    busy = transcript()[0]
    n0, t0 = f.frames, time.time()
    f.drag(300, 400, 420, 380, steps=12)            # orbiting: frames keep coming
    f.pump(0.05)
    fps = (f.frames - n0) / (time.time() - t0)
    w = fakewl.widget(m, 'ai.stop')
    check('busy' in busy and w is not None and fps > 10,
          f'while it works: Stop instead of Send, and the window keeps drawing ({fps:.0f} frames a second)')
    if OUT:
        f.shot('141_ai_working.png')
    t0 = time.time()
    if w:
        f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
    t = wait_idle(5)
    took = time.time() - t0
    check('idle' in t[0] and t[-1] == '$ N Stopped.' and took < 1.0,
          f'Stop ends the child at once ({took * 1000:.0f} ms, with the MCP round trips of the check)')

    send('please fail')
    t = wait_idle()
    tx = '\n'.join(t)
    check('N the stand-in failed on purpose' in tx and 'E Claude Code ended with exit code 3' in tx,
          'a CLI that fails: what it printed and its exit code')

    send('show an image')
    t = wait_idle()
    tx = '\n'.join(t)
    check('QkVFQkVF' not in tx and 'N   (a message too long to show, such as an image, was left out)' in tx
          and 'A Seen the image.' in tx,
          'a line longer than the buffer (an image) is left out whole, with a note; the stream goes on')
    check('R   = House1 r 0 0 0' in tx and 'R     Roof1 r 0 0 45' in tx,
          'a result\'s later lines are indented under its first')

    # -- a prompt of several lines: pasted, Shift+Enter, Up / Home
    x, y = fakewl.widget_xy(m, 'ai.prompt')
    f.click(x, y); f.pump(0.1)
    f.set_clipboard('Model the house on the plan at:\n'
                    '/home/user/Plans/PlanTestOct2026/BA_ééngezinswoning_I_N_inplantingsplan.pdf\n')
    f.mods(4); f.key(47); f.mods(0); f.pump(0.2)    # Ctrl+V
    h1 = (fakewl.widget(m, 'ai.prompt') or {}).get('h', 0)
    f.type('two floors')
    f.mods(1); f.key(28); f.mods(0)                 # Shift+Enter: a new line
    f.type('and a flat roof'); f.pump(0.2)
    h2 = (fakewl.widget(m, 'ai.prompt') or {}).get('h', 0)
    f.key(103); f.key(102); f.type('With '); f.pump(0.1)   # Up, Home: that line's start
    if OUT:
        f.shot('142_ai_prompt_lines.png')
    f.key(28)                                       # Enter sends
    wait_idle()
    a = json.load(open(os.path.join(home, 'claude.runs.json')))[-1]['args']
    check(a[1] == 'Model the house on the plan at:\n/home/user/Plans/PlanTestOct2026/'
          'BA_ééngezinswoning_I_N_inplantingsplan.pdf\nWith two floors\nand a flat roof',
          f'a pasted prompt keeps its line breaks; Shift+Enter adds one, Up / Home go by line ({a[1]!r})')
    h3 = (fakewl.widget(m, 'ai.prompt') or {}).get('h', 0)
    check(22 < h1 < h2 and h3 == 22,
          f'the prompt grows with its lines, the long path wrapped (heights {h1}, {h2}), and is one line again once sent ({h3})')

    # -- Grok
    print('  -- Grok --')
    v = connection(1)
    send('build with grok')
    t = wait_idle()
    runs = json.load(open(os.path.join(home, 'grok.runs.json')))
    a = runs[-1]['args']
    gdir = a[a.index('--cwd') + 1]
    toml = open(os.path.join(gdir, '.grok', 'config.toml')).read()
    check(v == 1 and q('print(exists("Grok2"))') == '1' and 'A Built a tower of 3 cubes.' in '\n'.join(t),
          f'the connection picker ({v}): the stand-in grok built through the same tools')
    check('streaming-messages-json' in a and '--always-approve' in a and '--disable-web-search' in a
          and '--trust' in a and {'run_terminal_command', 'write', 'read_file'} <= set(a[a.index('--disallowed-tools') + 1].split(',')) and '--rules' in a
          and runs[-1]['cwd'] == gdir and 'BEEMODEL_SOCKET = "' in toml and '--mcp-bridge' in toml,
          'grok --cwd <its own directory> --trust -p ... streaming-messages-json, no shell or files, its .grok/config.toml')
    rules = a[a.index('--rules') + 1]
    check('beemodel__scene_summary' in rules and 'beemodel__script_eval' in rules and 'disconnected' in rules,
          'Grok\'s rules name its tools in full (beemodel__...) and say a failed call is not a lost connection')
    send('again with grok')
    wait_idle()
    a = json.load(open(os.path.join(home, 'grok.runs.json')))[-1]['args']
    check('-r' in a and a[a.index('-r') + 1].startswith('sess-'), 'a Grok follow-up resumes (-r <session>)')
    send('a long job')
    t = '\n'.join(wait_idle())
    check('Stopped after 100 turns' in t and 'Type continue' in t and 'error_max_turns' not in t,
          f'the turn limit reached: a note saying so and how to go on, not a bare error ({t[-160:]!r})')

    # -- OpenRouter
    print('  -- OpenRouter --')
    v = connection(2)
    send('make a ring')
    t = wait_idle()
    check(v == 2 and 'E No OpenRouter key: set it in Preferences > AI (or OPENROUTER_API_KEY).' in '\n'.join(t)
          and not SEEN, 'without a key it says where to set one (and sends nothing)')
    m.tool('ui_tree')
    f.mods(4); f.key(51); f.mods(0)                 # Ctrl+, : Preferences
    f.pump(0.3)
    x, y = fakewl.widget_xy(m, 'prefs.category.ai', 7)
    f.click(x, y)
    f.pump(0.3)
    x, y = fakewl.widget_xy(m, 'prefs.openrouter_key')
    f.click(x, y)
    f.pump(0.1)
    f.type(KEY)
    f.key(28)
    f.pump(0.2)
    w = fakewl.widget(m, 'prefs.openrouter_key') or {}
    sec = os.path.join(cfg, 'secrets')
    check(w.get('value') == '(set)' and KEY in open(sec).read()
          and stat.S_IMODE(os.stat(sec).st_mode) == 0o600
          and KEY not in open(os.path.join(cfg, 'prefs')).read(),
          'the key typed in Preferences > AI: masked, kept only in the 0600 secrets file')
    for which, want in (('prefs.claude_test', 'N Claude Code: 9.9.9 (Claude Code)'),
                        ('prefs.grok_test', 'N Grok: grok 9.9.9'),
                        ('prefs.openrouter_test', 'N OpenRouter: the key works')):
        x, y = fakewl.widget_xy(m, which)
        f.click(x, y)
        for _ in range(30):
            f.pump(0.1)
            tx = '\n'.join(transcript())
            if want in tx:
                break
        check(want in tx, f'Test: {want[2:]}')
    if OUT:
        f.shot('142_ai_preferences.png')
    f.key(1)                                        # Esc
    f.pump(0.2)
    n0 = len(SEEN)
    send('make a ring')
    t = wait_idle()
    tx = '\n'.join(t)
    req = [s['body'] for s in SEEN[n0:]]
    check(q('print(exists("Ring3"), active())') == '1 Ring0' and 'A Made a ring of 4 spheres.' in tx
          and len(req) == 3, f'three requests: look, build (two tool calls in one step), answer ({len(req)})')
    tools = [t_['function']['name'] for t_ in req[0]['tools']]
    check(all(s['auth'] for s in SEEN[n0:]) and req[0]['model'] == 'test/model'
          and req[0]['messages'][0]['role'] == 'system' and 'script_eval' in tools
          and 'run_operator' in tools and not any(n.startswith('op_') for n in tools),
          f'each request: the key, the model, the instructions, the curated tools as functions ({len(tools)})')
    last = req[2]['messages']
    roles = [x['role'] for x in last]
    tmsg = [x for x in last if x['role'] == 'tool']
    check(roles == ['system', 'user', 'assistant', 'tool', 'assistant', 'tool', 'tool']
          and tmsg[0]['tool_call_id'] == 'call_0' and '"objects"' in tmsg[0]['content']
          and tmsg[2]['tool_call_id'] == 'call_2',
          'the conversation sent back: each tool call answered with its result (scene_summary\'s JSON)')
    adir = os.path.join(home, '.cache', 'beemodel', 'ai')
    hdr = os.path.join(adir, 'request.headers')
    check(stat.S_IMODE(os.stat(adir).st_mode) == 0o700 and stat.S_IMODE(os.stat(hdr).st_mode) == 0o600
          and KEY in open(hdr).read(),
          'curl gets the key in a header file only the user can read (never on its command line)')
    w = fakewl.wait_widget(f, m, 'ai.revert')
    if w:
        f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
        f.pump(0.3)
    check(q('print(exists("Ring0"))') == '0', 'Revert takes back the OpenRouter request in one step')
    send('loop forever')
    t = wait_idle()
    check(t[-1] == '$ N Stopped after 4 steps (the limit is in Preferences > AI).',
          'a model that never answers stops at the step limit')

    # -- prompt to world
    print('  -- prompt to world --')
    w = fakewl.widget(m, 'ai.new')
    f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
    f.pump(0.2)
    n0 = len(SEEN)
    send('build a little world: a valley with a house')
    t = wait_idle(30)
    sc = json.loads(m.tool('scene_summary')[0])
    objs = {o['name']: o for o in sc['objects']}
    ground = objs.get('Ground', {})
    check(len(SEEN[n0:]) == 3 and SEEN[n0]['body']['messages'][0]['role'] == 'system'
          and len(SEEN[n0]['body']['messages']) == 2,
          'New Conversation: the next request starts from the instructions again')
    check(any('geometry' in str(md).lower() for md in ground.get('modifiers', []))
          and objs.get('House', {}).get('material') == 'Stone' and objs.get('Roof', {}).get('material') == 'Planks'
          and objs.get('Sun', {}).get('type') == 'light' and objs.get('Shot', {}).get('type') == 'camera',
          'the world recipe of the instructions: terrain (geometry nodes), a house with materials, sun, camera')
    cap = m.call('tools/call', {'name': 'viewport_capture', 'arguments': {}}, timeout=10)
    imgs = [c for c in (cap or {}).get('result', {}).get('content', []) if c.get('type') == 'image']
    check(len(imgs) == 1 and len(imgs[0]['data']) > 10000, 'and the viewport shows it')
    if OUT:
        f.shot('143_ai_world.png')

    # -- the MCP prompt
    pl = m.call('prompts/list')['result']['prompts']
    pg = m.call('prompts/get', {'name': 'build_world', 'arguments': {'goal': 'a castle'}})['result']
    text = pg['messages'][0]['content']['text']
    check('build_world' in [p['name'] for p in pl] and 'scene_summary' in text and text.endswith('a castle'),
          'MCP prompts: build_world gives other agents the same instructions')

    # -- Ollama on this machine
    print('  -- Ollama (local) --')
    w = fakewl.widget(m, 'ai.new')
    f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
    f.pump(0.2)
    v = connection(3)
    n0 = len(SEEN)
    send('make a ring')
    t = wait_idle()
    tx = '\n'.join(t)
    req = [x['body'] for x in LOCAL]
    check(v == 3 and q('print(exists("Ring3"))') == '1' and 'A Made a ring of 4 spheres.' in tx
          and len(req) == 3 and len(SEEN) == n0,
          f'Ollama: the same tool loop, sent to the local address only ({len(req)} requests)')
    check(all(x['path'] == '/ollama/v1/chat/completions' and x['auth'] is None for x in LOCAL)
          and all(b['model'] == 'test-local:1b' and b.get('reasoning_effort') == 'none' for b in req)
          and req[0]['messages'][0]['role'] == 'system',
          'each request: the Ollama model, thinking off, no key sent')
    f.mods(4); f.key(51); f.mods(0)                 # Ctrl+, : Preferences
    f.pump(0.3)
    x, y = fakewl.widget_xy(m, 'prefs.category.ai', 7)
    f.click(x, y)
    f.pump(0.3)
    w = fakewl.wait_widget(f, m, 'prefs.ollama_test')
    for d in (10, 10, 10, -10, -10, -10, -10, -10, -10):  # (the last of the page: scrolled into view)
        if not w or w['y'] < 600:
            break
        f.move(w['x'] + w['w'] // 2, 400)
        f.wheel(d)
        f.pump(0.2)
        w = fakewl.widget(m, 'prefs.ollama_test')
    want = 'N Ollama: it answers and has the model'
    if w:
        f.click(w['x'] + w['w'] // 2, w['y'] + w['h'] // 2)
        for _ in range(30):
            f.pump(0.1)
            tx = '\n'.join(transcript())
            if want in tx:
                break
    check(w and want in tx, f'Test: {want[2:]}')
    f.key(1)                                        # Esc
    f.pump(0.2)
    f.proc.kill()
    srv.shutdown()
    print(f'  {len(FAILS)} failed' if FAILS else '  all passed')
    return 1 if FAILS else 0


sys.exit(main())
