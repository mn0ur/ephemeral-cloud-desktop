# Control panel (Vercel)

Replaces the always-on `mnour-hub` EC2 instance, which cost **$11.40/month**
(t4g.micro + a public IPv4 + a 12GB root disk + a 5GB data volume) to run a
~48MB Python app, a dashboard of links, and an Uptime Kuma with zero monitors.

Serverless is a genuine fit here, not just cheaper: this thing only serves one
page and makes API calls. It has no long-lived process, and the last three
outages in this project were all hub *boot* failures - a class of problem that
disappears along with the instance.

## Deploy

1. **Attach a KV store.** Vercel dashboard -> Storage -> create an Upstash for
   Redis / KV database -> connect it to this project. Vercel injects
   `KV_REST_API_URL` and `KV_REST_API_TOKEN`; `lib/state.js` also accepts the
   `UPSTASH_REDIS_REST_*` names, because the two integrations differ and getting
   it wrong fails at runtime rather than at deploy time.

2. **Set environment variables** (Settings -> Environment Variables):

   | Name | Value |
   |---|---|
   | `GH_TOKEN` | fine-grained PAT, `Actions: read and write` on this repo only |
   | `GH_REPO` | `mn0ur/ephemeral-cloud-desktop` |
   | `GOOGLE_CLIENT_ID` | the OAuth client ID (already authorises `desktop.mnour.dev`) |
   | `ADMIN_GOOGLE_SUB` | the owner's Google `sub` - grants the admin view |
   | `SESSION_SECRET` | any long random string; signs session cookies |
   | `HUB_CALLBACK_SECRET` | must MATCH the GitHub secret of the same name |

3. **Deploy**, then point `desktop.mnour.dev` at Vercel. Do this last: the
   hostname is live, and the GitHub workflows POST their callbacks to it.

## Why state lives in Redis

The hub kept `sessions.json`, `users.json`, `history.jsonl` and
`data_flags.json` on an EBS volume. Serverless has no durable filesystem, so
each became a Redis key - and that removes a bug class rather than working
around one. Hub state was lost to instance replacement three separate times in
this project: the GitHub token, then the admin sub, then the data flags.

## What did NOT move, and why

- **Uptime Kuma** - needs a long-lived process and its own database. Its actual
  job (noticing the Pi is down) is better served by Healthchecks.io, which is
  free and push-based, so it alerts when the Pi is *off* - something Kuma
  running on the Pi structurally cannot do.
- **The reaper cron** - the free plan allows one cron run per day, useless for a
  15-minute check. It stays on GitHub Actions, which is free and already works.
- **The desktop and the VPN** - both need real VMs.

## Deliberate carry-overs

Behaviour learned the hard way on the hub, preserved here on purpose:

- Session cookie is `Path=/`. Scoped to a subpath it simply is not sent, which
  made sign-in silently do nothing.
- Both start and destroy set a busy state that the poll loop respects, or the
  next poll draws over it and every action looks ignored.
- Auto-open only fires for a start we dispatched, so a destroy cannot redirect
  the user into the desktop they just tore down.
- A failed dispatch rolls the session back, instead of wedging it in `pending`
  and holding a concurrency slot.
- `/api/status` only fetches workflow progress when something is mid-flight.
- The front end is a real `.js` file. On the hub it lived inside a Python
  string, where one `\n` meant for JavaScript was eaten by Python, split a
  string literal across lines, and took the whole page's script down.
