import socket, json, sys, os, base64
P = os.environ.get("BEEMODEL_SOCKET", os.path.join(os.environ["XDG_RUNTIME_DIR"], "beemodel.sock"))
s = socket.socket(socket.AF_UNIX); s.connect(P); f = s.makefile("rwb")
n = 0
def rpc(method, params=None):
    global n; n += 1
    f.write((json.dumps({"jsonrpc":"2.0","id":n,"method":method,"params":params or {}})+"\n").encode()); f.flush()
    while True:
        r = json.loads(f.readline())
        if r.get("id") == n: return r
rpc("initialize", {"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-demo","version":"1"}})
f.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); f.flush()
def tool(name, args=None):
    r = rpc("tools/call", {"name":name,"arguments":args or {}})
    res = r.get("result", r)
    out = []
    for c in res.get("content", []):
        if c["type"] == "text": out.append(c["text"])
        elif c["type"] == "image":
            p = os.environ.get("SHOT", "shot.png")
            open(p,"wb").write(base64.b64decode(c["data"])); out.append("[image -> %s]" % p)
    return ("ERROR: " if res.get("isError") else "") + "\n".join(out)
if __name__ == "__main__":
    name = sys.argv[1]
    if name == "script":
        print(tool("script_eval", {"code": open(sys.argv[2]).read()}))
    else:
        print(tool(name, json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}))
