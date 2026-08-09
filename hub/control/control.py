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

* This panel holds NO AWS or Terraform credentials, on purpose - only a
  GitHub PAT. It cannot read `terraform output` itself, so a guest's URL and
  password have to be handed to it by the workflow, via a callback endpoint
  authenticated with a separate shared secret (HUB_CALLBACK_SECRET). A
  compromised panel therefore can never touch AWS directly, only trigger the
  same two fixed workflows a human already could.

* Only two guest slots exist, ever ("a" and "b"). That is what makes "at
  most 2 concurrent desktops" true without a counter anywhere that could get
  out of sync - there is structurally nowhere for a third one to run.

* Google sign-in is verified via Google's own tokeninfo endpoint rather than
  a JWT library, to keep this stdlib-only. Google validates the signature and
  expiry server-side; this code only has to check the audience and email
  verification on the response. Sessions are a home-rolled HMAC-signed
  cookie (stdlib hmac + hashlib), not a session store - there is nothing here
  worth the operational cost of a database for two concurrent slots.

Stdlib only - no pip install on a box that is meant to stay boring.
"""

import base64
import hashlib
import hmac
import http.cookies
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.environ.get("GH_REPO", "mn0ur/ephemeral-cloud-desktop")
TOKEN_FILE = os.environ.get("GH_TOKEN_FILE", "/etc/hub/github-token")
DESKTOP_URL = os.environ.get("DESKTOP_URL", "https://desk.mnour.sd")
LISTEN = ("127.0.0.1", 8000)

# Where guest slot state persists across a hub restart. On the hub's own
# EBS volume, same reasoning as Uptime Kuma's data: a service restart must
# not make the control panel forget who owns a currently-running slot.
SLOTS_FILE = os.environ.get("SLOTS_FILE", "/mnt/hubdata/control/slots.json")
SLOTS = ("a", "b")

# Measured spot price for c7i.xlarge in eu-central-1. Used only to show a
# running estimate - the authoritative number is always the AWS bill.
HOURLY_USD = float(os.environ.get("HOURLY_USD", "0.104"))

# Guest sign-in. Empty GOOGLE_CLIENT_ID is a valid, safe state - see below.
GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")
ADMIN_GOOGLE_SUB = os.environ.get("ADMIN_GOOGLE_SUB", "")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "")
HUB_CALLBACK_SECRET = os.environ.get("HUB_CALLBACK_SECRET", "")
SESSION_MAX_AGE = 12 * 3600  # sign back in daily; nothing here needs longer

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


def url_up(url, timeout=6):
    """200 from <url>/healthz means running. Anything else means not ready."""
    ctx = ssl.create_default_context()
    try:
        req = urllib.request.Request(f"{url}/healthz", method="GET")
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            return r.status == 200
    except Exception:
        return False


def desktop_up():
    return url_up(DESKTOP_URL)


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


# ---------------------------------------------------------------------------
# Guest slot state. A flat JSON file, not a database - two slots do not
# justify one, and the file lives on the hub's persistent volume so a
# service restart mid-session does not forget who owns what.
# ---------------------------------------------------------------------------

def _load_slots():
    try:
        with open(SLOTS_FILE) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    for s in SLOTS:
        data.setdefault(s, {"status": "idle"})
    return data


def _save_slots(data):
    os.makedirs(os.path.dirname(SLOTS_FILE), exist_ok=True)
    tmp = SLOTS_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, SLOTS_FILE)  # atomic - a crash mid-write cannot corrupt it


def free_slot(slots):
    for s in SLOTS:
        if slots.get(s, {}).get("status") in ("idle", "error"):
            return s
    return None


PENDING_TIMEOUT_S = 10 * 60  # a workflow that fails to reach "ready" this long is stuck, not slow


def refresh_slots(slots):
    """Two things nothing else in this file does on its own:

    ready -> active, once the guest's own /healthz actually answers. Without
    this a slot sits at "Booting..." forever even after the desktop is up,
    because the session-ready callback fires right after `terraform apply`
    returns - well before the container has pulled and TLS has settled.

    pending -> error, if session-ready never arrives within 10 minutes. A
    failed workflow run (bad AMI, spot capacity, a Terraform error) would
    otherwise hold a slot "in use" forever - one of only two that exist.
    """
    changed = False
    now = time.time()
    for name in SLOTS:
        s = slots.get(name, {"status": "idle"})
        if s.get("status") == "ready" and url_up(s.get("url") or ""):
            s["status"] = "active"
            changed = True
        elif s.get("status") == "pending" and now - s.get("dispatched_at", now) > PENDING_TIMEOUT_S:
            slots[name] = {"status": "error"}
            changed = True
    if changed:
        _save_slots(slots)
    return slots


# ---------------------------------------------------------------------------
# Sessions. HMAC-signed, not encrypted - the payload (email, a slugified user
# id, expiry) is not secret, only tamper-evidence matters. base64url so it
# survives as a cookie value with no escaping headaches.
# ---------------------------------------------------------------------------

def _b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _unb64(s):
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def sign_session(payload: dict) -> str:
    body = _b64(json.dumps(payload).encode())
    sig = hmac.new(SESSION_SECRET.encode(), body.encode(), hashlib.sha256).hexdigest()
    return f"{body}.{sig}"


def verify_session(cookie_value: str):
    if not cookie_value or not SESSION_SECRET:
        return None
    try:
        body, sig = cookie_value.split(".", 1)
    except ValueError:
        return None
    expected = hmac.new(SESSION_SECRET.encode(), body.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        return None  # tampered or signed with an old/different secret
    try:
        payload = json.loads(_unb64(body))
    except Exception:
        return None
    if payload.get("exp", 0) < time.time():
        return None
    return payload


USERS_FILE = os.environ.get("USERS_FILE", "/mnt/hubdata/control/users.json")
HISTORY_FILE = os.environ.get("HISTORY_FILE", "/mnt/hubdata/control/history.jsonl")


def _load_users():
    try:
        with open(USERS_FILE) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    data.setdefault("by_sub", {})
    data.setdefault("by_username", {})
    return data


def _save_users(data):
    os.makedirs(os.path.dirname(USERS_FILE), exist_ok=True)
    tmp = USERS_FILE + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, USERS_FILE)


def log_event(event: str, **fields):
    """Append-only, one JSON object per line. Never read-modify-write - two
    concurrent events can never corrupt each other, which a single JSON
    document could. This is the "who logged in when, how long they used it"
    record the admin can see; it is never used to make access decisions,
    only to report on what already happened.
    """
    try:
        os.makedirs(os.path.dirname(HISTORY_FILE), exist_ok=True)
        with open(HISTORY_FILE, "a") as fh:
            fh.write(json.dumps({"ts": time.time(), "event": event, **fields}) + "\n")
    except OSError:
        pass  # history is a record, not a control path - never block on it


def user_id_from(email: str, sub: str) -> str:
    """The desktop username: plain email local part - "alice", not
    "alice-1d91fb" - for exactly as long as no other Google account has
    ever claimed it.

    The username also decides which persistent volume a "keep my data"
    session reuses, so a collision is not cosmetic: it would hand one
    person's files to whoever signs in second with a same-looking local
    part (alice@gmail.com and alice@yahoo.com are different people). A
    stable sub -> username mapping is kept on the persistent volume so
    the same Google account always gets the same username back, and a
    second, different account with the same local part is disambiguated
    ("alice-2") rather than silently colliding.
    """
    users = _load_users()

    existing = users["by_sub"].get(sub)
    if existing:
        return existing  # same Google account as before - same username, always

    local = (email.split("@")[0] if "@" in email else email).lower()
    local = re.sub(r"[^a-z0-9-]+", "-", local).strip("-")[:20] or "guest"

    candidate = local
    n = 2
    while candidate in users["by_username"]:
        candidate = f"{local}-{n}"
        n += 1

    users["by_sub"][sub] = candidate
    users["by_username"][candidate] = sub
    _save_users(users)
    log_event("first_login", username=candidate, email=email)
    return candidate


def verify_google_token(credential: str):
    """Ask Google to verify the ID token, rather than checking the RS256
    signature locally - that would need a JWT/crypto library, which is
    exactly what "stdlib only" rules out. Google validates signature and
    expiry; this only has to check audience and that the email is verified.
    """
    ctx = ssl.create_default_context()
    q = urllib.parse.urlencode({"id_token": credential})
    req = urllib.request.Request(f"https://oauth2.googleapis.com/tokeninfo?{q}")
    try:
        with urllib.request.urlopen(req, timeout=8, context=ctx) as r:
            claims = json.loads(r.read())
    except urllib.error.HTTPError:
        return None  # Google rejected it outright - expired, malformed, forged
    except Exception:
        return None

    if not GOOGLE_CLIENT_ID or claims.get("aud") != GOOGLE_CLIENT_ID:
        return None  # not a token issued for THIS app
    if claims.get("email_verified") not in ("true", True):
        return None
    return claims


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
      display:flex;flex-direction:column;align-items:center;min-height:100vh;padding:1.5rem 1rem;gap:1.2rem;
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
 h2{margin:0 0 .8rem;font-size:.85rem;color:var(--cyan);font-weight:600}
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
 .slots{display:grid;grid-template-columns:1fr 1fr;gap:.9rem}
 @media (max-width:520px){.slots{grid-template-columns:1fr}}
 .slot-card{background:var(--bg2);border:1px solid var(--border);border-radius:8px;padding:.9rem;font-size:.82rem}
 .slot-card h3{margin:0 0 .5rem;font-size:.8rem;color:var(--dim);font-weight:600;letter-spacing:.5px}
 .who{font-size:.72rem;color:var(--mute);margin-top:.3rem;word-break:break-all}
 .cred{font-size:.72rem;color:var(--amber);margin-top:.4rem;word-break:break-all}
 .g-signin{display:flex;justify-content:center;margin-bottom:.6rem}
 .signed-in{display:flex;justify-content:space-between;align-items:center;font-size:.78rem;color:var(--dim);margin-bottom:.6rem}
 .signed-in button{flex:none;min-width:auto;padding:.35rem .7rem;font-size:.72rem}
 .disabled-note{font-size:.76rem;color:var(--mute);text-align:center;padding:1rem 0}
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

<div class="card">
  <h2>Guest desktops</h2>
  <div class="sub">Sign in with Google, get your own desktop. Two can run at once; each session auto-ends after its time limit.</div>

  <div id="g-anon" class="g-signin"></div>
  <div id="g-signed" class="signed-in" style="display:none">
    <span id="g-email"></span>
    <button id="g-signout">Sign out</button>
  </div>
  <div id="g-disabled" class="disabled-note" style="display:none">Sign-in is not configured yet.</div>

  <div id="g-slots" class="slots"></div>
  <div id="g-err" class="err"></div>
</div>

<script src="https://accounts.google.com/gsi/client" async defer></script>
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
    renderGuest(s);
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

// ---------------- guest section ----------------
let session=null, guestBusy={};

function renderGuest(s){
  if(s.google_client_id && !window.__gRendered){
    window.__gRendered=true;
    google.accounts.id.initialize({client_id:s.google_client_id, callback:onGoogleCredential});
    google.accounts.id.renderButton($('g-anon'), {theme:'filled_black', size:'large'});
  }
  $('g-disabled').style.display = s.google_client_id ? 'none' : 'block';

  session = s.session || null;
  $('g-anon').style.display = session ? 'none' : (s.google_client_id ? 'flex' : 'none');
  $('g-signed').style.display = session ? 'flex' : 'none';
  if(session) $('g-email').textContent = session.email;

  const grid=$('g-slots'); grid.innerHTML='';
  for(const name of ['a','b']){
    const slot=(s.slots||{})[name]||{status:'idle'};
    const mine = session && slot.user_id===session.user_id;
    const div=document.createElement('div'); div.className='slot-card';
    let body=`<h3>SLOT ${name.toUpperCase()}</h3>`;
    if(slot.status==='idle'||slot.status==='error'){
      body+=`<div>Free</div>`;
      body+=`<div class="row" style="margin-top:.6rem">
        <button class="go" ${session?'':'disabled'} onclick="guestStart('${name}')">Start here</button>
      </div>
      <label style="margin-top:.5rem"><input type="checkbox" id="persist-${name}"> Keep my data after destroy</label>`;
    } else if(slot.status==='pending'){
      body+=`<div class="dot work" style="display:inline-block;margin-right:.4rem"></div>Starting…`;
    } else if(slot.status==='ready'||slot.status==='active'){
      body+=`<div>${slot.status==='active'?'Running':'Booting…'}</div>`;
      body+=`<div class="who">${slot.email||''}</div>`;
      if(mine && slot.password) body+=`<div class="cred">pass: ${slot.password}</div>`;
      if(slot.url) body+=`<a class="open on" href="${slot.url}" target="_blank">Open →</a>`;
      if(mine || (session&&session.is_admin)){
        body+=`<div class="row" style="margin-top:.6rem"><button class="stop" onclick="guestDestroy('${name}')">Destroy</button></div>`;
      }
    }
    div.innerHTML=body; grid.appendChild(div);
  }
}

function onGoogleCredential(resp){
  fetch('api/google-login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({credential:resp.credential})})
    .then(r=>{ if(!r.ok) throw new Error('sign-in rejected'); return r.json() })
    .catch(e=>{$('g-err').textContent=e.message});
}
$('g-signout').onclick=()=>fetch('api/google-logout',{method:'POST'});

window.guestStart=(slot)=>{
  $('g-err').textContent='';
  const persist=$('persist-'+slot)?.checked||false;
  fetch('api/dispatch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'start',slot,persist})})
    .then(async r=>{ if(!r.ok) $('g-err').textContent=await r.text() });
};
window.guestDestroy=(slot)=>{
  if(!confirm('Destroy this desktop?'))return;
  $('g-err').textContent='';
  fetch('api/dispatch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'destroy',slot})})
    .then(async r=>{ if(!r.ok) $('g-err').textContent=await r.text() });
};

poll();setInterval(poll,5000);
</script>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json", set_cookie=None):
        raw = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        if set_cookie is not None:
            self.send_header("Set-Cookie", set_cookie)
        self.end_headers()
        self.wfile.write(raw)

    def _session(self):
        raw = self.headers.get("Cookie", "")
        jar = http.cookies.SimpleCookie()
        try:
            jar.load(raw)
        except Exception:
            return None
        morsel = jar.get("session")
        if not morsel:
            return None
        payload = verify_session(morsel.value)
        if payload:
            payload["is_admin"] = bool(ADMIN_GOOGLE_SUB) and payload.get("sub") == ADMIN_GOOGLE_SUB
        return payload

    def _bearer_ok(self, expected):
        auth = self.headers.get("Authorization", "")
        if not expected:
            return False
        return hmac.compare_digest(auth, f"Bearer {expected}")

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("", "/index.html"):
            return self._send(200, PAGE, "text/html; charset=utf-8")

        if path == "/api/status":
            session = self._session()
            slots = refresh_slots(_load_slots())
            public_slots = {}
            for name, s in slots.items():
                entry = {"status": s.get("status", "idle")}
                if s.get("status") in ("pending", "ready", "active"):
                    entry["user_id"] = s.get("user_id")
                    entry["email"] = s.get("email")
                    entry["url"] = s.get("url")
                    entry["status"] = s.get("status")
                    # Password only ever goes to the owning session, or the
                    # admin - never broadcast to every visitor polling status.
                    if session and (session.get("user_id") == s.get("user_id") or session.get("is_admin")):
                        entry["password"] = s.get("password")
                public_slots[name] = entry

            out = {
                "desktop_up": desktop_up(),
                "run": latest_run(),
                "desktop_url": DESKTOP_URL,
                "hourly_usd": HOURLY_USD,
                "google_client_id": GOOGLE_CLIENT_ID,
                "session": session,
                "slots": public_slots,
            }
            if not token():
                out["error"] = ("No GitHub token on the hub. Buttons are inert until "
                                "/etc/hub/github-token contains a fine-grained PAT with "
                                "Actions: read and write on this repo.")
            return self._send(200, json.dumps(out))

        if path == "/api/history":
            session = self._session()
            if not (session and session.get("is_admin")):
                return self._send(403, json.dumps({"error": "admin only"}))
            events = []
            try:
                with open(HISTORY_FILE) as fh:
                    for line in fh:
                        line = line.strip()
                        if line:
                            events.append(json.loads(line))
            except OSError:
                pass
            events.sort(key=lambda e: e.get("ts", 0), reverse=True)
            return self._send(200, json.dumps({"events": events[:500]}))

        return self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")

        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception as exc:
            return self._send(400, json.dumps({"error": f"bad json: {exc}"}))

        if path == "/api/google-login":
            return self._google_login(req)
        if path == "/api/google-logout":
            return self._send(200, json.dumps({"ok": True}),
                               set_cookie="session=; Path=/control; Max-Age=0")
        if path == "/api/session-ready":
            return self._session_ready(req)
        if path == "/api/session-ended":
            return self._session_ended(req)
        if path == "/api/dispatch":
            return self._dispatch(req)

        return self._send(404, json.dumps({"error": "not found"}))

    # -- Google sign-in ----------------------------------------------------

    def _google_login(self, req):
        if not GOOGLE_CLIENT_ID or not SESSION_SECRET:
            return self._send(400, json.dumps({"error": "sign-in is not configured on this hub"}))
        claims = verify_google_token(req.get("credential", ""))
        if not claims:
            return self._send(401, json.dumps({"error": "google rejected that token"}))

        email = claims.get("email", "")
        sub = claims.get("sub", "")
        uid = user_id_from(email, sub)
        log_event("login", username=uid, email=email)
        payload = {
            "sub": sub,
            "email": email,
            "user_id": uid,
            "exp": time.time() + SESSION_MAX_AGE,
        }
        cookie = sign_session(payload)
        return self._send(
            200, json.dumps({"user_id": uid, "email": email}),
            set_cookie=f"session={cookie}; Path=/control; HttpOnly; Secure; SameSite=Lax; Max-Age={SESSION_MAX_AGE}",
        )

    # -- Callbacks from GitHub Actions (shared secret, not a session) ------

    def _session_ready(self, req):
        if not self._bearer_ok(HUB_CALLBACK_SECRET):
            return self._send(403, json.dumps({"error": "bad callback secret"}))
        slot = req.get("slot")
        if slot not in SLOTS:
            return self._send(400, json.dumps({"error": "bad slot"}))
        slots = _load_slots()
        prior = slots.get(slot, {})
        started_at = time.time()
        slots[slot] = {
            "status": "ready",  # control panel still polls healthz before "active"
            "user_id": prior.get("user_id"),
            "email": prior.get("email"),
            "url": req.get("url"),
            "password": req.get("password"),
            "kill_at": req.get("kill_at"),
            "started_at": started_at,
        }
        _save_slots(slots)
        log_event("start", username=prior.get("user_id"), email=prior.get("email"),
                   slot=slot, url=req.get("url"))
        return self._send(200, json.dumps({"ok": True}))

    def _session_ended(self, req):
        if not self._bearer_ok(HUB_CALLBACK_SECRET):
            return self._send(403, json.dumps({"error": "bad callback secret"}))
        slot = req.get("slot")
        if slot not in SLOTS:
            return self._send(400, json.dumps({"error": "bad slot"}))
        slots = _load_slots()
        prior = slots.get(slot, {})
        duration_s = None
        if prior.get("started_at"):
            duration_s = round(time.time() - prior["started_at"])
        slots[slot] = {"status": "idle"}
        _save_slots(slots)
        log_event("destroy", username=prior.get("user_id"), email=prior.get("email"),
                   slot=slot, duration_s=duration_s, reason=req.get("reason", "manual"))
        return self._send(200, json.dumps({"ok": True}))

    # -- Start / destroy -----------------------------------------------------

    def _dispatch(self, req):
        action = req.get("action")
        wf = WORKFLOWS.get(action)
        if not wf:
            return self._send(400, json.dumps({"error": "unknown action"}))

        slot = req.get("slot")
        if slot is None:
            # The owner's original, unchanged path - no slot, no session
            # required. Basic auth in front of the whole hub is the gate.
            if action == "start":
                inputs = {
                    "username": str(req.get("username") or "mnour"),
                    "fresh": "true" if req.get("fresh") else "false",
                }
            else:
                inputs = {"confirm": "DESTROY"}
            return self._trigger(wf, inputs)

        # Guest path - requires a real session from here on.
        if slot not in SLOTS:
            return self._send(400, json.dumps({"error": "bad slot"}))
        session = self._session()
        if not session:
            return self._send(401, json.dumps({"error": "sign in first"}))

        slots = _load_slots()
        current = slots.get(slot, {"status": "idle"})

        if action == "start":
            if current.get("status") not in ("idle", "error"):
                return self._send(409, json.dumps({"error": "that slot is in use"}))
            # One running slot per guest - stops a single sign-in from
            # occupying both, which would otherwise defeat the 2-slot cap.
            for name, s in slots.items():
                if s.get("user_id") == session["user_id"] and s.get("status") in ("pending", "ready", "active"):
                    return self._send(409, json.dumps({"error": "you already have a desktop running"}))

            slots[slot] = {
                "status": "pending",
                "user_id": session["user_id"],
                "email": session["email"],
                "dispatched_at": time.time(),
            }
            _save_slots(slots)
            inputs = {
                "username": session["user_id"],
                "fresh": "false",
                "slot": slot,
                "user_id": session["user_id"],
                "owner_email": session["email"],
                "persist": "true" if req.get("persist") else "false",
                "session_hours": "4",
            }
            return self._trigger(wf, inputs)

        if action == "destroy":
            owns_it = current.get("user_id") == session["user_id"]
            if not (owns_it or session.get("is_admin")):
                return self._send(403, json.dumps({"error": "not your session"}))
            return self._trigger(wf, {"confirm": "DESTROY", "slot": slot})

        return self._send(400, json.dumps({"error": "unknown action"}))

    def _trigger(self, workflow_file, inputs):
        try:
            gh("POST", f"/repos/{REPO}/actions/workflows/{workflow_file}/dispatches",
               {"ref": "main", "inputs": inputs})
        except urllib.error.HTTPError as exc:
            return self._send(exc.code, json.dumps({"error": exc.read().decode()[:400]}))
        except Exception as exc:
            return self._send(500, json.dumps({"error": str(exc)}))
        return self._send(202, json.dumps({"ok": True}))

    def log_message(self, *_):
        pass  # keep journald readable


if __name__ == "__main__":
    if not SESSION_SECRET:
        print("WARNING: SESSION_SECRET is not set - guest sign-in will fail closed (no crash, just rejected).")
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
