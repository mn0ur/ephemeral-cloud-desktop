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
DESKTOP_URL = os.environ.get("DESKTOP_URL", "https://desk.mnour.sd")
LISTEN = ("127.0.0.1", 8000)

# Measured spot price for c7i.xlarge in eu-central-1. Used only to show a
# running estimate - the authoritative number is always the AWS bill.
HOURLY_USD = float(os.environ.get("HOURLY_USD", "0.104"))

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

    # Uptime must be measured from the last START, not from whatever ran most
    # recently. Using runs[0] meant that right after a DESTROY was dispatched
    # the panel read the destroy's timestamp and reported "0m - $0.00" for a
    # desktop that had been billing for hours.
    started_up = None
    for run in runs:
        if "START" in (run.get("name") or "").upper() and run.get("conclusion") == "success":
            started_up = run.get("run_started_at")
            break

    return {
        "name": r.get("name"),
        "status": r.get("status"),          # queued | in_progress | completed
        "conclusion": r.get("conclusion"),  # success | failure | cancelled
        "url": r.get("html_url"),
        "started": r.get("run_started_at"),
        "started_up": started_up,
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
 /* Tokens copied verbatim from mnour.sd (devops-portfolio/css/style.css) so
    the dashboard, the control panel and the portfolio read as one system. */
 :root{
   --bg:#04070c; --bg2:#070d16; --panel:#0a121e; --panel2:#0d1726;
   --border:#16283c; --border-hi:#1f3a55;
   --green:#3dffa2; --green-dim:#17a866; --cyan:#56d4ff; --amber:#ffc46b;
   --red:#ff5f56; --text:#c9d7e6; --dim:#64788f; --mute:#3d4f63;
   --mono:"JetBrains Mono","Fira Code",Consolas,"Courier New",monospace;
   --glow:0 0 12px rgba(61,255,162,.45); --radius:10px;
   color-scheme:dark;
 }
 *{box-sizing:border-box}
 body{margin:0;font:14px/1.6 var(--mono);background:var(--bg);color:var(--text);
      display:flex;align-items:center;justify-content:center;min-height:100vh;padding:1rem;
      background-image:linear-gradient(rgba(22,40,60,.25) 1px,transparent 1px),
                       linear-gradient(90deg,rgba(22,40,60,.25) 1px,transparent 1px);
      background-size:44px 44px}
 .card{width:100%;max-width:640px;background:var(--panel);border:1px solid var(--border);
       border-radius:var(--radius);padding:1.5rem;box-shadow:0 0 0 1px rgba(0,0,0,.4)}
 .bar-top{display:flex;gap:.45rem;margin-bottom:1.1rem}
 .bar-top i{width:11px;height:11px;border-radius:50%;display:block}
 .bar-top i:nth-child(1){background:var(--red)}
 .bar-top i:nth-child(2){background:var(--amber)}
 .bar-top i:nth-child(3){background:var(--green)}
 h1{margin:0 0 .2rem;font-size:1.05rem;color:var(--green);font-weight:600;letter-spacing:.5px}
 h1::before{content:"$ ";color:var(--green-dim)}
 .sub{color:var(--mute);font-size:.76rem;margin-bottom:1.2rem}
 .state{display:flex;align-items:center;gap:.6rem;padding:.8rem .95rem;border-radius:8px;
        background:var(--bg2);border:1px solid var(--border);margin-bottom:1rem;font-size:.85rem}
 .dot{width:10px;height:10px;border-radius:50%;background:var(--mute);flex:none}
 .dot.up{background:var(--green);box-shadow:var(--glow)}
 .dot.down{background:var(--red)}
 .dot.work{background:var(--amber);animation:p 1s infinite}
 @keyframes p{50%{opacity:.25}}
 .bar{height:6px;background:#050b14;border:1px solid var(--border);
      border-radius:99px;overflow:hidden;margin:.8rem 0 .35rem;display:none}
 .bar.on{display:block}
 .fill{height:100%;width:0;background:linear-gradient(90deg,var(--cyan),var(--green));
       transition:width .6s ease;box-shadow:var(--glow)}
 .note{font-size:.74rem;color:var(--mute);min-height:1.1em}
 .row{display:flex;gap:.55rem;flex-wrap:wrap;margin-top:1rem}
 button{flex:1;min-width:150px;padding:.7rem 1rem;border-radius:7px;cursor:pointer;
        font-family:var(--mono);font-weight:600;font-size:.85rem;
        background:var(--panel2);color:var(--text);border:1px solid var(--border-hi);
        transition:border-color .15s,box-shadow .15s,color .15s}
 .go:hover:not(:disabled){border-color:var(--green-dim);color:var(--green);box-shadow:var(--glow)}
 .stop:hover:not(:disabled){border-color:var(--red);color:var(--red);box-shadow:0 0 12px rgba(255,95,86,.4)}
 button:disabled{opacity:.35;cursor:not-allowed}
 .open{display:none;margin-top:.9rem;padding:.7rem 1rem;border-radius:7px;text-align:center;
       text-decoration:none;font-weight:600;font-size:.85rem;
       background:var(--panel2);border:1px solid var(--green-dim);color:var(--green)}
 .open.on{display:block}
 .open:hover{box-shadow:var(--glow)}
 fieldset{border:1px solid var(--border);border-radius:8px;padding:.85rem;margin:1rem 0 0}
 legend{color:var(--mute);font-size:.72rem;padding:0 .4rem;text-transform:lowercase}
 label{display:block;font-size:.74rem;color:var(--dim);margin:.45rem 0 .2rem}
 input[type=text]{width:100%;padding:.5rem .65rem;border-radius:6px;font-family:var(--mono);
   border:1px solid var(--border);background:var(--bg2);color:var(--text);font-size:.82rem}
 input[type=text]:focus{outline:none;border-color:var(--green-dim)}
 input[type=checkbox]{accent-color:var(--green)}
 .err{color:#ff9a94;font-size:.76rem;margin-top:.7rem;white-space:pre-wrap}
</style>
<div class="card">
  <div class="bar-top"><i></i><i></i><i></i></div>
  <h1>cloud-desktop</h1>
  <div class="sub" id="sub">~$0.10/hour while running &middot; data persists</div>

  <div class="state"><span id="dot" class="dot"></span><span id="txt">checking&hellip;</span></div>
  <div id="bar" class="bar"><div id="fill" class="fill"></div></div>
  <div id="note" class="note"></div>

  <a id="open" class="open" href="#">Open desktop &rarr;</a>

  <div class="row">
    <button id="start" class="go">Start desktop</button>
    <button id="destroy" class="stop">Destroy</button>
  </div>

  <fieldset>
    <legend>options for start</legend>
    <label>Username</label>
    <input id="u" type="text" value="mnour" autocomplete="off">
    <div style="font-size:.78rem;color:#8fa0bd;margin:.5rem 0 .25rem">
      Password is generated automatically. It is not settable here: this repo is
      public and workflow inputs are not masked in Actions logs.
    </div>
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

function fmtDur(ms){
  const m=Math.floor(ms/60000), h=Math.floor(m/60);
  return h?`${h}h ${m%60}m`:`${m}m`;
}
function render(s){
  const up=s.desktop_up, run=s.run||{};
  const active=run.status==='queued'||run.status==='in_progress';
  // A completed START with the desktop not yet answering means it is BOOTING,
  // not destroyed. Reporting "Destroyed - costing nothing" while an instance
  // is running and billing is the worst possible thing to get wrong here.
  const booting = !up && !active && /START/i.test(run.name||'') && run.conclusion==='success';
  if(busy||active||booting){
    $('dot').className='dot work';
    const destroying=(busy==='destroy')||(/DESTROY/i.test(run.name||'')&&busy!=='start');
    $('txt').textContent=destroying?'Destroying…':(booting?'Booting — almost there':'Starting…');
    $('bar').classList.add('on');
    const pct=Math.min(95,((Date.now()-t0)/1000)/EXPECT[busy||'start']*100);
    $('fill').style.width=pct+'%';
    $('note').textContent=run.status?('workflow: '+run.status):'dispatching…';
    $('start').disabled=$('destroy').disabled=true;
    $('open').classList.remove('on');
  } else {
    $('dot').className='dot '+(up?'up':'down');
    if(up){
      const started=run.started_up?Date.parse(run.started_up):null;
      if(started){
        const ms=Date.now()-started, cost=(ms/3600000)*(s.hourly_usd||0.104);
        $('txt').textContent=`Running · ${fmtDur(ms)} · ~$${cost.toFixed(2)} this session`;
      } else { $('txt').textContent='Running'; }
    } else {
      $('txt').textContent='Destroyed — costing nothing';
    }
    $('start').disabled=up; $('destroy').disabled=!up;
    $('bar').classList.remove('on'); $('fill').style.width='0';
    $('note').textContent=run.conclusion?('last run: '+run.name+' → '+run.conclusion):'';
    $('open').classList.toggle('on',up); if(s.desktop_url)$('open').href=s.desktop_url;
  }
}

async function poll(){
  try{
    const s=await (await fetch('api/status',{cache:'no-store'})).json();
    if(s.error){$('err').textContent=s.error}
    // Completion is judged by the desktop actually answering, not by the
    // workflow finishing - Terraform exits before TLS is ready.
    if(busy==='start'&&s.desktop_up){busy=null;location.href=s.desktop_url||'/'}
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
  if(action==='start'){body.username=$('u').value||'mnour';body.fresh=$('fresh').checked}
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
            out = {"desktop_up": desktop_up(), "run": latest_run(), "desktop_url": DESKTOP_URL,
                   "hourly_usd": HOURLY_USD}
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
            # No password here on purpose. workflow_dispatch inputs are not
            # masked in job logs, and this repository is public - passing one
            # would publish it. The password is generated by Terraform.
            inputs = {
                "username": str(req.get("username") or "mnour"),
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
