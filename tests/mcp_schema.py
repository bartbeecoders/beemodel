#!/usr/bin/env python3
"""The published MCP tool schema (D3): docs/mcp-tools.json must be what the
running server answers to tools/list.

BeeModel runs in the fake compositor; an MCP client asks for its tools and
compares them, tool by tool, with docs/mcp-tools.json (names, descriptions
and input schemas), and the file's version with VERSION. A tool that is
gone from the server fails even with --update: in 1.x the tools change
only by adding.

    python3 tests/mcp_schema.py build/beemodel            # check
    python3 tests/mcp_schema.py build/beemodel --update   # rewrite the file
"""
import json, os, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else 'build/beemodel')
UPDATE = '--update' in sys.argv
DOC = os.path.join(ROOT, 'docs', 'mcp-tools.json')
PROTOCOL = '2025-06-18'
FAILS = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg)
    if not cond:
        FAILS.append(msg)


def server_tools():
    argv = sys.argv
    sys.argv = [argv[0], tempfile.mkdtemp(prefix='bee-mcp-shots-')]
    sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import fakewl
    sys.argv = argv
    fakewl.BIN = BIN
    f = fakewl.Fake()
    try:
        f.pump(1.0, until_frame=True)
        m = fakewl.Mcp(f)
        init = m.call('initialize', {'protocolVersion': PROTOCOL, 'capabilities': {},
                                     'clientInfo': {'name': 'mcp_schema', 'version': '1'}})
        tools = m.call('tools/list', {}, timeout=30)
    finally:
        f.proc.kill()
    return init['result'], tools['result']['tools']


def main():
    version = open(os.path.join(ROOT, 'VERSION')).read().strip()
    info, tools = server_tools()
    check(info['serverInfo']['version'] == version, f'the server is version {version}')
    old = json.load(open(DOC)) if os.path.exists(DOC) else {'tools': []}
    have = {t['name'] for t in tools}
    gone = [t['name'] for t in old['tools'] if t['name'] not in have]
    check(not gone, f'no published tool is gone ({len(old["tools"])} published, {len(tools)} served)' +
          (f': {", ".join(gone[:8])}' if gone else ''))
    doc = {
        '$schema': 'https://json-schema.org/draft/2020-12/schema',
        'title': 'BeeModel MCP tools',
        'description': 'The tools BeeModel\'s MCP server offers (tools/list), each with its JSON Schema input. '
                       'Published with every release; in 1.x tools are only added. See docs/MCP.md.',
        'version': version,
        'protocolVersion': PROTOCOL,
        'tools': tools,
    }
    if UPDATE:
        with open(DOC, 'w') as fh:
            json.dump(doc, fh, indent=1, ensure_ascii=False)
            fh.write('\n')
        print(f'  wrote docs/mcp-tools.json: {len(tools)} tools')
    else:
        check(old.get('version') == version, f'docs/mcp-tools.json is for version {version} (it says {old.get("version")})')
        byname = {t['name']: t for t in old['tools']}
        new = [t['name'] for t in tools if t['name'] not in byname]
        changed = [t['name'] for t in tools if t['name'] in byname and byname[t['name']] != t]
        check(not new and not changed,
              'every served tool is published as it is' +
              (f' (new: {", ".join(new[:8])}; changed: {", ".join(changed[:8])})' if new or changed else '') +
              ('' if not new and not changed else ' - run tests/mcp_schema.py --update'))
        for t in tools:
            s = t.get('inputSchema', {})
            if s.get('type') != 'object' or not isinstance(s.get('properties'), dict):
                check(False, f'{t["name"]}: its input schema is an object with properties')
                break
        else:
            check(True, 'every input schema is a JSON Schema object')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
