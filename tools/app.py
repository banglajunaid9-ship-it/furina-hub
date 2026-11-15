#!/usr/bin/env python3
"""
Furina Hub - Protector app.

A local web app: open it in your browser, drop in a Luau script, pick options,
and download the protected version. Runs entirely on your machine - nothing is
uploaded anywhere.

Usage
  python tools/app.py          # opens http://127.0.0.1:8765 in your browser
  python tools/app.py --port 9000 --no-open
"""

import argparse
import json
import os
import sys
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import obf_engine  # noqa: E402

PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Furina Protector</title>
<style>
  :root{
    --bg:#0b0f17; --panel:#121826; --panel2:#0e1420; --line:#1f2a3d;
    --ink:#e7eefb; --mut:#8aa0c2; --accent:#4cc2ff; --accent2:#7c5cff;
    --ok:#39d98a; --warn:#ffb020; --bad:#ff5d6c;
  }
  *{box-sizing:border-box}
  body{margin:0;font:15px/1.5 -apple-system,Segoe UI,Roboto,Inter,sans-serif;
    background:radial-gradient(1200px 600px at 70% -10%,#16233b 0%,var(--bg) 55%);
    color:var(--ink);min-height:100vh}
  .wrap{max-width:860px;margin:0 auto;padding:40px 20px 80px}
  h1{font-size:26px;margin:0 0 2px;letter-spacing:.3px}
  h1 span{background:linear-gradient(90deg,var(--accent),var(--accent2));
    -webkit-background-clip:text;background-clip:text;color:transparent}
  .sub{color:var(--mut);margin:0 0 26px}
  .card{background:linear-gradient(180deg,var(--panel),var(--panel2));
    border:1px solid var(--line);border-radius:16px;padding:22px;margin-bottom:18px}
  .drop{border:2px dashed #2b3a56;border-radius:14px;padding:38px;text-align:center;
    cursor:pointer;transition:.15s;background:#0d1320}
  .drop.hot{border-color:var(--accent);background:#0f1b2c}
  .drop b{color:var(--ink)} .drop small{color:var(--mut)}
  .file{display:flex;align-items:center;gap:10px;margin-top:14px;color:var(--mut);
    font-size:13px}
  .file.on{color:var(--ok)}
  .row{display:flex;gap:18px;flex-wrap:wrap;margin-top:8px}
  .opt{flex:1;min-width:200px}
  label{display:block;color:var(--mut);font-size:13px;margin:12px 0 6px}
  input[type=text],input[type=number]{width:100%;background:#0c1322;
    border:1px solid var(--line);color:var(--ink);border-radius:10px;padding:10px 12px;
    font:inherit}
  .chk{display:flex;align-items:center;gap:10px;margin:10px 0;cursor:pointer;
    color:var(--ink)}
  .chk input{width:18px;height:18px;accent-color:var(--accent)}
  .chk small{color:var(--mut)}
  .btn{display:inline-flex;align-items:center;gap:8px;border:0;cursor:pointer;
    background:linear-gradient(90deg,var(--accent),var(--accent2));color:#071018;
    font-weight:700;border-radius:12px;padding:13px 20px;font-size:15px;
    transition:.15s;box-shadow:0 8px 30px -10px var(--accent)}
  .btn:disabled{opacity:.5;cursor:not-allowed;box-shadow:none}
  .btn.ghost{background:#17213400;border:1px solid var(--line);color:var(--ink);
    box-shadow:none;font-weight:600}
  .bar{display:flex;gap:12px;align-items:center;margin-top:18px;flex-wrap:wrap}
  .stat{margin-left:auto;color:var(--mut);font-size:13px}
  .note{font-size:12.5px;color:var(--mut);background:#0d1626;border:1px solid var(--line);
    border-left:3px solid var(--warn);border-radius:10px;padding:12px 14px;margin-top:16px}
  .out{display:none;margin-top:18px}
  pre{background:#070b12;border:1px solid var(--line);border-radius:12px;max-height:280px;
    overflow:auto;padding:14px;font:12px/1.5 ui-monospace,Consolas,monospace;
    color:#9fd0ff;white-space:pre-wrap;word-break:break-all}
  .pill{display:inline-block;font-size:11px;padding:3px 9px;border-radius:999px;
    background:#13243a;color:var(--accent);border:1px solid #244469;margin-right:6px}
  .err{border-left-color:var(--bad);color:#ffc7cd}
</style>
</head>
<body>
<div class="wrap">
  <h1><span>Furina</span> Protector</h1>
  <p class="sub">Local Luau obfuscator &middot; runs on your machine, nothing is uploaded</p>

  <div class="card">
    <div id="drop" class="drop">
      <b>Drop a .luau / .lua script here</b><br>
      <small>or click to choose a file &middot; or paste below</small>
      <input id="file" type="file" accept=".lua,.luau,.txt" hidden>
    </div>
    <div id="fileinfo" class="file">No file selected</div>
    <label>…or paste your script</label>
    <textarea id="paste" rows="5" style="width:100%;background:#0c1322;border:1px solid var(--line);
      color:#cfe0f7;border-radius:10px;padding:10px 12px;font:12px/1.5 ui-monospace,Consolas,monospace"
      placeholder="-- paste Luau source here"></textarea>

    <div class="row">
      <div class="opt">
        <label>Layers (more = stronger &amp; larger)</label>
        <input id="layers" type="number" min="1" max="6" value="3">
      </div>
      <div class="opt">
        <label>Header comment (optional)</label>
        <input id="name" type="text" placeholder="e.g. Furina Hub">
      </div>
    </div>

    <label class="chk"><input id="tamper" type="checkbox" checked>
      <span>Anti-tamper <small>&mdash; refuses to run if the payload is edited</small></span></label>
    <label class="chk"><input id="hook" type="checkbox">
      <span>Anti-hook <small>&mdash; removes the easiest dump path (safe on all executors)</small></span></label>

    <div class="bar">
      <button id="go" class="btn" disabled>Protect script</button>
      <button id="dl" class="btn ghost" style="display:none">Download .lua</button>
      <button id="copy" class="btn ghost" style="display:none">Copy</button>
      <span id="stat" class="stat"></span>
    </div>

    <div id="note" class="note">
      No obfuscator is unbreakable. This defeats every format-specific deobfuscator and
      casual reversing; it does not stop a determined attacker who hooks loadstring in an
      executor. Protection, not a vault.
    </div>
  </div>

  <div id="out" class="card out">
    <div id="pills"></div>
    <pre id="code"></pre>
  </div>
</div>

<script>
let source="", srcName="script.luau", result="";
const $=id=>document.getElementById(id);
const drop=$("drop"), file=$("file"), paste=$("paste");

function setSource(text,name){
  source=text||""; if(name) srcName=name;
  const kb=(new Blob([source]).size/1024).toFixed(1);
  $("fileinfo").textContent = source ? `${srcName} - ${kb} KB` : "No file selected";
  $("fileinfo").className = "file" + (source ? " on" : "");
  $("go").disabled = !source.trim();
}
drop.onclick=()=>file.click();
file.onchange=e=>{const f=e.target.files[0]; if(!f)return;
  const r=new FileReader(); r.onload=()=>setSource(r.result,f.name); r.readAsText(f);};
["dragenter","dragover"].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.add("hot");}));
["dragleave","drop"].forEach(ev=>drop.addEventListener(ev,e=>{e.preventDefault();drop.classList.remove("hot");}));
drop.addEventListener("drop",e=>{const f=e.dataTransfer.files[0]; if(!f)return;
  const r=new FileReader(); r.onload=()=>setSource(r.result,f.name); r.readAsText(f);});
paste.addEventListener("input",()=>setSource(paste.value, srcName));

$("go").onclick=async()=>{
  const btn=$("go"); btn.disabled=true; const t0=performance.now();
  $("stat").textContent="protecting…";
  try{
    const res=await fetch("/obfuscate",{method:"POST",headers:{"Content-Type":"application/json"},
      body:JSON.stringify({
        source, name:$("name").value, layers:+$("layers").value,
        antiTamper:$("tamper").checked, antiHook:$("hook").checked
      })});
    const j=await res.json();
    if(!j.ok){ throw new Error(j.error||"failed"); }
    result=j.result;
    const dt=((performance.now()-t0)/1000).toFixed(2);
    const inkb=(new Blob([source]).size/1024).toFixed(1);
    const outkb=(new Blob([result]).size/1024).toFixed(1);
    $("stat").textContent=`done in ${dt}s`;
    $("pills").innerHTML=
      `<span class="pill">${inkb} KB in</span>`+
      `<span class="pill">${outkb} KB out</span>`+
      `<span class="pill">${$("layers").value} layers</span>`+
      ($("tamper").checked?`<span class="pill">anti-tamper</span>`:"")+
      ($("hook").checked?`<span class="pill">anti-hook</span>`:"");
    $("code").textContent = result.length>4000 ? result.slice(0,4000)+"\n… (truncated preview)" : result;
    $("out").style.display="block"; $("dl").style.display="inline-flex"; $("copy").style.display="inline-flex";
    $("note").classList.remove("err"); $("note").firstChild.textContent &&
      ($("note").innerHTML=$("note").innerHTML);
  }catch(err){
    $("stat").textContent="error";
    $("note").classList.add("err"); $("note").textContent="Error: "+err.message;
  }finally{ btn.disabled=false; }
};
$("dl").onclick=()=>{
  const base=srcName.replace(/\.(lua|luau|txt)$/i,"");
  const blob=new Blob([result],{type:"text/plain"});
  const a=document.createElement("a"); a.href=URL.createObjectURL(blob);
  a.download=base+".obf.lua"; a.click();
};
$("copy").onclick=async()=>{ await navigator.clipboard.writeText(result);
  $("copy").textContent="Copied!"; setTimeout(()=>$("copy").textContent="Copy",1200); };
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, PAGE)
        else:
            self._send(404, "not found", "text/plain")

    def do_POST(self):
        if self.path != "/obfuscate":
            self._send(404, "not found", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            source = payload.get("source", "")
            if not source.strip():
                raise ValueError("empty script")
            result = obf_engine.obfuscate(
                source,
                layers=max(1, min(int(payload.get("layers", 3)), 6)),
                anti_tamper=bool(payload.get("antiTamper", True)),
                anti_hook=bool(payload.get("antiHook", False)),
                header=(payload.get("name") or None),
            )
            self._send(200, json.dumps({"ok": True, "result": result}),
                       "application/json")
        except Exception as e:  # noqa: BLE001
            self._send(200, json.dumps({"ok": False, "error": str(e)}),
                       "application/json")


def main() -> int:
    ap = argparse.ArgumentParser(description="Local Luau protector web app.")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--no-open", action="store_true", help="do not open a browser")
    args = ap.parse_args()

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}"
    print(f"Furina Protector running at {url}  (Ctrl+C to stop)")
    if not args.no_open:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
