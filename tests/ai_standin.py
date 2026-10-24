#!/usr/bin/env python3
"""A stand-in for the claude and grok programs (tests/ai.py puts it on PATH
under both names). It reads its arguments as the real ones do, starts the
MCP server its configuration names (BeeModel's --mcp-bridge, for the
instance that started it), builds in the scene through it and prints the
real stream format (stream-json / streaming-messages-json: system,
assistant, user, result lines). Every run's arguments are kept in
$HOME/<name>.runs.json for the test to look at.

Prompts: "slow" waits (for Stop), "fail" ends with an error, "add a title
'Hello'" adds 3D text above the cube and "change the title to 'Bye'" finds
it in scene_summary and changes it (tests/text.py), AI > Line Up References
looks at reference images and pins one (tests/refs.py), anything else builds
a little tower of cubes (Tower0.. for claude, Grok0.. for grok).
"""
import json, os, re, subprocess, sys, time

NAME = os.path.basename(sys.argv[0])
ARGS = sys.argv[1:]


def opt(flag, default=None):
    return ARGS[ARGS.index(flag) + 1] if flag in ARGS else default


def say(obj):
    print(json.dumps(obj), flush=True)


def server():
    """The MCP server (command, args, env) from the configuration."""
    if NAME == 'claude':
        cfg = json.load(open(opt('--mcp-config')))['mcpServers']['beemodel']
        return cfg['command'], cfg['args'], cfg.get('env', {})
    import tomllib
    cfg = tomllib.load(open(os.path.join(opt('--cwd', '.'), '.grok', 'config.toml'), 'rb'))
    s = cfg['mcp_servers']['beemodel']
    return s['command'], s['args'], s.get('env', {})


class Mcp:
    def __init__(self):
        cmd, args, env = server()
        self.p = subprocess.Popen([cmd, *args], env=dict(os.environ, **env), text=True,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.n = 0
        self.call('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                 'clientInfo': {'name': NAME, 'version': '9'}})

    def call(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.n, 'method': method,
                                       'params': params}) + '\n')
        self.p.stdin.flush()
        while True:
            r = json.loads(self.p.stdout.readline())
            if r.get('id') == self.n:
                return r

    def tool(self, name, args):
        r = self.call('tools/call', {'name': name, 'arguments': args})['result']
        return r['content'][0]['text'], r.get('isError', False)


def main():
    home = os.environ.get('HOME', '.')
    log = os.path.join(home, NAME + '.runs.json')
    runs = json.load(open(log)) if os.path.exists(log) else []
    runs.append({'args': ARGS, 'cwd': os.getcwd()})
    json.dump(runs, open(log, 'w'))
    if '--version' in ARGS:
        print('9.9.9 (Claude Code)' if NAME == 'claude' else 'grok 9.9.9')
        return 0
    prompt = opt('-p', '')
    sid = opt('--resume') or opt('-r') or 'sess-%d' % len(runs)
    say({'type': 'system', 'subtype': 'init', 'session_id': sid, 'model': 'stand-in',
         'tools': ['mcp__beemodel__scene_summary']})
    if '--- The reference drawings' in prompt:  # (tests/refs.py)
        return refs(prompt, sid)
    if 'slow' in prompt:
        time.sleep(60)
        return 0
    if 'long job' in prompt:                    # the turn limit reached
        say({'type': 'result', 'subtype': 'error_max_turns', 'is_error': True, 'session_id': sid})
        return 0
    if 'fail' in prompt:
        print('the stand-in failed on purpose', file=sys.stderr, flush=True)
        return 3
    if 'image' in prompt:                       # a viewport capture: one line far
        say({'type': 'user', 'message': {'role': 'user', 'content': [  # longer than the buffer
            {'type': 'tool_result', 'tool_use_id': 't1', 'content': [
                {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png',
                                             'data': 'QkVF' * 150000}}]}]}})
        say({'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': 't2', 'content': 'House1 r 0 0 0\nRoof1 r 0 0 45'}]}})
        say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
            {'type': 'text', 'text': 'Seen the image.'}]}})
        say({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'Seen the image.',
             'session_id': sid})
        return 0
    if '--- What this request is about' in prompt:
        return ask(prompt, sid)
    if 'title' in prompt:
        return title(prompt, sid)
    m = Mcp()
    pre = 'mcp__beemodel__'
    say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'text', 'text': 'Looking at the scene first.'},
        {'type': 'tool_use', 'id': 't1', 'name': pre + 'scene_summary', 'input': {}}]},
        'session_id': sid})
    text, err = m.tool('scene_summary', {})
    say({'type': 'user', 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 't1', 'content': text[:300], 'is_error': err}]}})
    base = 'Tower' if NAME == 'claude' else 'Grok'
    code = 'for i in 0..3 { add("cube", "%s" + str(i), 0, 0.5 + i, 0) }\nprint("built", count())' % base
    say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'tool_use', 'id': 't2', 'name': pre + 'script_eval', 'input': {'code': code}}]}})
    text, err = m.tool('script_eval', {'code': code})
    say({'type': 'user', 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 't2', 'content': [{'type': 'text', 'text': text}],
         'is_error': err}]}})
    say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'text', 'text': 'Built a tower of 3 cubes.\nAsk for a roof next.'}]}})
    say({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'Built a tower of 3 cubes.',
         'session_id': sid})
    m.p.stdin.close()
    m.p.wait(5)
    return 0



def refs(prompt, sid):
    """AI > Line Up References: look at the first reference, re-sort a
    section taken for an elevation, pin the front elevation's corner to the
    origin."""
    m = Mcp()
    names = [ln[2:].split(':')[0] for ln in prompt.split('\n') if ln.startswith('- ')]
    calls = []
    r = m.call('tools/call', {'name': 'reference_view', 'arguments': {'name': names[0]}})['result']
    kinds = [c['type'] for c in r['content']]
    calls.append(('reference_view', names[0], kinds, r['content'][0]['text'][:200]))
    r = m.call('tools/call', {'name': 'reference_view', 'arguments': {'name': names[0], 'x0': 10, 'y0': 20, 'x1': 110, 'y1': 70}})['result']
    calls.append(('reference_view', 'crop', [c['type'] for c in r['content']], r['content'][0]['text'][:200]))
    for arg in ('Ref voorgevel 100 700 0 0 0', 'Ref doorsnede a-a left'):
        t, err = m.tool('run_operator', {'id': 'object.reference_pin' if arg[-1] == '0' else 'object.reference_kind', 'arg': arg})
        calls.append(('run_operator', arg, err, t))
    json.dump({'names': names, 'calls': calls}, open(os.path.join(os.environ.get('HOME', '.'), 'refs.ai.json'), 'w'))
    say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text':
        'Looked at %d references; pinned the front elevation, made doorsnede a-a a left elevation.' % len(names)}]}})
    say({'type': 'result', 'subtype': 'success', 'session_id': sid, 'is_error': False})
    m.p.stdin.close()
    m.p.wait(5)
    return 0


def title(prompt, sid):
    """Text (tests/text.py): "add a title 'X'" (text.add, then moved above the
    cube), "change the title to 'Y'" (the text object found in scene_summary,
    text_set)."""
    words = (re.findall(r"'([^']*)'", prompt) or ['Title'])[-1]
    m = Mcp()
    pre = 'mcp__beemodel__'
    calls = []
    if 'change' in prompt:
        summary, _ = m.tool('scene_summary', {})
        calls.append(('scene_summary', {}, summary))
        texts = [o['name'] for o in json.loads(summary)['objects'] if 'text' in o]
        code = 'text_set("%s", "%s")\nprint(text("%s"))' % (texts[0], words, texts[0]) if texts else 'print("no text")'
        r, _ = m.tool('script_eval', {'code': code})
        calls.append(('script_eval', {'code': code}, r))
    else:
        arg = "'%s' size 0.5 depth 0.1" % words
        r, _ = m.tool('op_text_add', {'arg': arg})
        calls.append(('op_text_add', {'arg': arg}, r))
        code = 't = active()\nmove(t, 0, 2.6, 0)\nprint(t, text(t))'
        r, _ = m.tool('script_eval', {'code': code})
        calls.append(('script_eval', {'code': code}, r))
    for i, (name, args, result) in enumerate(calls):
        say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
            {'type': 'tool_use', 'id': 't%d' % i, 'name': pre + name, 'input': args}]}, 'session_id': sid})
        say({'type': 'user', 'message': {'role': 'user', 'content': [
            {'type': 'tool_result', 'tool_use_id': 't%d' % i, 'content': result[:300], 'is_error': False}]}})
    say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'text', 'text': 'The title reads %s.' % words}]}})
    say({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'Done.', 'session_id': sid})
    m.p.stdin.close()
    m.p.wait(5)
    return 0


def ask(prompt, sid):
    """Ask AI (tests/askai.py): the request, then what was selected. "bigger"
    doubles the selected objects, "stray" moves the Light too, "delete the
    light" deletes it, "extrude" extrudes the selected faces 20 cm."""
    req = prompt.split('\n\n--- What')[0].strip()
    low = req.lower()
    names = [json.loads(ln[ln.index('{"name":'):])['name'] for ln in prompt.split('\n') if '{"name":' in ln]
    if 'extrude' in low:
        code = 'op("mesh.extrude", 0.2)\nprint(verts("%s"))' % names[0]
    elif 'delete the light' in low:
        code = 'delete("Light")\nprint(count())'
    elif 'bigger' in low or 'stray' in low:
        code = ''.join('scale("%s", get("%s", "sx") * 2, get("%s", "sy") * 2, get("%s", "sz") * 2)\n'
                       % (n, n, n, n) for n in names)
        if 'stray' in low:
            code += 'move("Light", 9, 9, 9)\n'
        code += 'print("done")'
    else:
        code = 'print("nothing to do")'
    m = Mcp()
    pre = 'mcp__beemodel__'
    say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'tool_use', 'id': 't1', 'name': pre + 'script_eval', 'input': {'code': code}}]},
        'session_id': sid})
    text, err = m.tool('script_eval', {'code': code})
    say({'type': 'user', 'message': {'role': 'user', 'content': [
        {'type': 'tool_result', 'tool_use_id': 't1', 'content': text, 'is_error': err}]}})
    say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'text', 'text': 'Done: %s (%s).\nAnything else?' % (req, ', '.join(names))}]}})
    say({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'Done.', 'session_id': sid})
    m.p.stdin.close()
    m.p.wait(5)
    return 0


sys.exit(main())
