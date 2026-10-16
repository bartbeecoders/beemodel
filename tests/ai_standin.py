#!/usr/bin/env python3
"""A stand-in for the claude and grok programs (tests/ai.py puts it on PATH
under both names). It reads its arguments as the real ones do, starts the
MCP server its configuration names (BeeModel's --mcp-bridge, for the
instance that started it), builds in the scene through it and prints the
real stream format (stream-json / streaming-messages-json: system,
assistant, user, result lines). Every run's arguments are kept in
$HOME/<name>.runs.json for the test to look at.

Prompts: "slow" waits (for Stop), "fail" ends with an error, anything else
builds a little tower of cubes (Tower0.. for claude, Grok0.. for grok).
"""
import json, os, subprocess, sys, time

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
    if 'slow' in prompt:
        time.sleep(60)
        return 0
    if 'fail' in prompt:
        print('the stand-in failed on purpose', file=sys.stderr, flush=True)
        return 3
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


sys.exit(main())
