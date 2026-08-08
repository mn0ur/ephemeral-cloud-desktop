#!/usr/bin/env python3
"""
Hub control panel: start and destroy the desktop without leaving the dashboard.

Design notes worth keeping:

* The GitHub token lives HERE, server-side, and is never sent to the browser.
  A page that called the GitHub API directly would have to embed the token in
  JavaScript, handing it to anyone who opened devtools.

* Completion is judged by GET /healthz on the desktop returning 200 - NOT by
  the workflow finishing. Terraform exits well before the container has
  pulled, started and negotiated TLS, so redirecting on workflow-complete
  would land the user on a connection error.

* Only two workflow files can ever be dispatched. The action name is mapped
  through a fixed dict rather than interpolated from user input, so a crafted
  request cannot trigger arbitrary workflows.

Stdlib only - no pip install on a box that is meant to stay boring.
"""

import json
import os
import ssl
import subprocess
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.environ.get("GH_REPO", "mn0ur/ephemeral-cloud-desktop")
TOKEN_FILE = os.environ.get("GH_TOKEN_FILE", "/etc/hub/github-token")
DESKTOP_URL = os.environ.get("DESKTOP_URL", "https://desktop.mnour.sd")
LISTEN = ("127.0.0.1", 8000)

# Fixed allow-list. Never build a workflow filename from request input.
WORKFLOWS = {
    "start": "desktop-up.yml",
    "destroy": "desktop-down.yml",
}


def token():
    try:
        with open(TOKEN_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return ""


def gh(method, path, payload=None):
    tok = token()
    if not tok:
        raise RuntimeError("no GitHub token configured on the hub")
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        method=method,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={
            "Authorization": f"Bearer {tok}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
            "User-Agent": "hub-control",
        },
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = resp.read()
        return json.loads(body) if body else {}


def desktop_up():
    """200 from /healthz means running. Anything else means not ready."""
    ctx = ssl.create_default_context()
    try:
        req = urllib.request.Request(f"{DESKTOP_URL}/healthz", method="GET")
        with urllib.request.urlopen(req, timeout=6, context=ctx) as r:
            return r.status == 200
    except Exception:
        return False


def latest_run():
    try:
        data = gh("GET", f"/repos/{REPO}/actions/runs?per_page=5")
    except Exception as exc:
        return {"error": str(exc)}
    runs = data.get("workflow_runs") or []
    if not runs:
        return {}
    r = runs[0]
    return {
        "name": r.get("name"),
        "status": r.get("status"),          # queued | in_progress | completed
        "conclusion": r.get("conclusion"),  # success | failure | cancelled
        "url": r.get("html_url"),
        "started": r.get("run_started_at"),
    }


PAGE = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<!-- Without this, visiting /control (no trailing slash) makes every
     relative fetch resolve to /api/... instead of /control/api/...,
     which 404s silently and freezes the UI mid-action. -->
<base href="/control/">
<title>Desktop Control</title>
<style>
 :root{color-scheme:dark}
 body{margin:0;font:15px/1.5 system-ui,sans-serif;background:#0f1420;color:#e6edf7;
      display:flex;align-items:center;justify-content:center;min-height:100vh;padding:1rem}
 .card{width:100%;max-width:620px;background:#161c2b;border:1px solid #263048;
       border-radius:14px;padding:1.6rem}
 h1{margin:0 0 .3rem;font-size:1.25rem}
 .sub{color:#8fa0bd;font-size:.85rem;margin-bottom:1.3rem}
 .state{display:flex;align-items:center;gap:.6rem;padding:.85rem 1rem;border-radius:10px;
        background:#0f1626;border:1px solid #263048;margin-bottom:1.1rem}
 .dot{width:11px;height:11px;border-radius:50%;background:#64748b;flex:none}
 .dot.up{background:#22c55e;box-shadow:0 0 10px #22c55e}
 .dot.down{background:#ef4444}
 .dot.work{background:#f59e0b;animation:p 1s infinite}
 @keyframes p{50%{opacity:.3}}
 .bar{height:7px;background:#0b1120;border-radius:99px;overflow:hidden;margin:.9rem 0 .4rem;display:none}
 .bar.on{display:block}
 .fill{height:100%;width:0;background:linear-gradient(90deg,#3b82f6,#22c55e);
       transition:width .6s ease}
 .note{font-size:.8rem;color:#8fa0bd;min-height:1.2em}
 .row{display:flex;gap:.6rem;flex-wrap:wrap;margin-top:1.1rem}
 button{flex:1;min-width:150px;padding:.75rem 1rem;border-radius:9px;border:1px solid transparent;
        font-weight:600;font-size:.92rem;cursor:pointer}
 .go{background:#16a34a;color:#fff}
 .stop{background:#b91c1c;color:#fff}
 .open{background:#1d4ed8;color:#fff;text-decoration:none;text-align:center;
       padding:.75rem 1rem;border-radius:9px;font-weight:600;display:none}
 .open.on{display:block}
 button:disabled{opacity:.45;cursor:not-allowed}
 fieldset{border:1px solid #263048;border-radius:10px;padding:.9rem;margin:1.1rem 0 0}
 legend{color:#8fa0bd;font-size:.78rem;padding:0 .4rem}
 label{display:block;font-size:.78rem;color:#8fa0bd;margin:.5rem 0 .25rem}
 input[type=text],input[type=password]{width:100%;box-sizing:border-box;padding:.55rem .7rem;
   border-radius:7px;border:1px solid #263048;background:#0f1626;color:#e6edf7}
 .err{color:#fca5a5;font-size:.8rem;margin-top:.7rem;white-space:pre-wrap}
</style>
<div class="card">
  <h1>Cloud Desktop</h1>
  <div class="sub">desktop.mnour.sd &middot; ~$0.10/hour while running &middot; data persists</div>

  <div class="state"><span id="dot" class="dot"></span><span id="txt">checking&hellip;</span></div>
  <div id="bar" class="bar"><div id="fill" class="fill"></div></div>
  <div id="note" class="note"></div>

  <a id="open" class="open" href="https://desktop.mnour.sd">Open desktop &rarr;</a>

  <div class="row">
    <button id="start" class="go">Start desktop</button>
    <button id="destroy" class="stop">Destroy</button>
  </div>

  <fieldset>
    <legend>options for start</legend>
    <label>Username</label>
    <input id="u" type="text" value="mnour" autocomplete="off">
    <label>Password &mdash; leave blank to generate a strong one</label>
    <input id="p" type="password" placeholder="(generated)" autocomplete="new-password">
    <label><input id="fresh" type="checkbox"> Fresh start (discards installed apps)</label>
  </fieldset>

  <div id="err" class="err"></div>
</div>
<script>
const $=i=>document.getElementById(i);
let busy=null, t0=0;
// Measured on a real cycle: workflow completes at ~60s but the desktop only
// answers at ~195s - the image pull and TLS happen after Terraform exits.
const EXPECT={start:210,destroy:100}; // measured: start 195s (workflow 60s + image pull and TLS), destroy 90s

function render(s){
  const up=s.desktop_up, run=s.run||{};
  const active=run.status==='queued'||run.status==='in_progress';
  if(busy||active){
    $('dot').className='dot work';
    $('txt').textContent=(busy==='destroy'||/DESTROY/i.test(run.name||''))?'Destroying…':'Starting…';
    $('bar').classList.add('on');
    const pct=Math.min(95,((Date.now()-t0)/1000)/EXPECT[busy||'start']*100);
    $('fill').style.width=pct+'%';
    $('note').textContent=run.status?('workflow: '+run.status):'dispatching…';
    $('start').disabled=$('destroy').disabled=true;
    $('open').classList.remove('on');
  } else {
    $('dot').className='dot '+(up?'up':'down');
    $('txt').textContent=up?'Running':'Destroyed — costing nothing';
    $('start').disabled=up; $('destroy').disabled=!up;
    $('bar').classList.remove('on'); $('fill').style.width='0';
    $('note').textContent=run.conclusion?('last run: '+run.name+' → '+run.conclusion):'';
    $('open').classList.toggle('on',up);
  }
}

async function poll(){
  try{
    const s=await (await fetch('api/status',{cache:'no-store'})).json();
    if(s.error){$('err').textContent=s.error}
    // Completion is judged by the desktop actually answering, not by the
    // workflow finishing - Terraform exits before TLS is ready.
    if(busy==='start'&&s.desktop_up){busy=null;location.href='https://desktop.mnour.sd'}
    if(busy==='destroy'&&!s.desktop_up&&s.run&&s.run.status==='completed'){busy=null}
    render(s);
  }catch(e){
    // A poll that dies must not leave the UI stuck mid-action.
    busy=null;
    $('err').textContent='status unreachable: '+e.message;
    $('dot').className='dot'; $('txt').textContent='status unknown';
    $('start').disabled=$('destroy').disabled=false;
    $('bar').classList.remove('on');
  }
}

async function go(action){
  $('err').textContent='';
  const body={action};
  if(action==='start'){body.username=$('u').value||'mnour';body.password=$('p').value;body.fresh=$('fresh').checked}
  if(action==='destroy'&&!confirm('Destroy the desktop? Your data survives.'))return;
  busy=action;t0=Date.now();render({desktop_up:action==='destroy'});
  try{
    const r=await fetch('api/dispatch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
    if(!r.ok){busy=null;$('err').textContent='dispatch failed: '+(await r.text())}
  }catch(e){busy=null;$('err').textContent=e.message}
}
$('start').onclick=()=>go('start');
$('destroy').onclick=()=>go('destroy');
poll();setInterval(poll,5000);
</script>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("", "/index.html"):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if path == "/api/status":
            out = {"desktop_up": desktop_up(), "run": latest_run()}
            if not token():
                out["error"] = ("No GitHub token on the hub. Buttons are inert until "
                                "/etc/hub/github-token contains a fine-grained PAT with "
                                "Actions: read and write on this repo.")
            return self._send(200, json.dumps(out))
        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if self.path.split("?")[0].rstrip("/") != "/api/dispatch":
            return self._send(404, json.dumps({"error": "not found"}))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception as exc:
            return self._send(400, json.dumps({"error": f"bad json: {exc}"}))

        wf = WORKFLOWS.get(req.get("action"))
        if not wf:
            return self._send(400, json.dumps({"error": "unknown action"}))

        if req["action"] == "start":
            inputs = {
                "username": str(req.get("username") or "mnour"),
                "password": str(req.get("password") or ""),
                "fresh": "true" if req.get("fresh") else "false",
            }
        else:
            inputs = {"confirm": "DESTROY"}

        try:
            gh("POST", f"/repos/{REPO}/actions/workflows/{wf}/dispatches",
               {"ref": "main", "inputs": inputs})
        except urllib.error.HTTPError as exc:
            return self._send(exc.code, json.dumps({"error": exc.read().decode()[:400]}))
        except Exception as exc:
            return self._send(500, json.dumps({"error": str(exc)}))
        return self._send(202, json.dumps({"ok": True}))

    def log_message(self, *_):
        pass  # keep journald readable


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
