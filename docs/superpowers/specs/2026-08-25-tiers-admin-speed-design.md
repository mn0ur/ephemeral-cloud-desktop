# Access tiers, an admin console, and faster boot/destroy

## Why

Today every signed-in Google account is treated identically: anyone can
start a desktop, anyone can choose to keep their files, and nothing ever
force-stops a session except the person who started it (or the owner,
by hand). That doesn't scale past "just me testing it" - there's no way
to let other people use this without either trusting them with
unlimited AWS spend or babysitting every session.

Separately, boot time is bad. A fresh guest session (no persistent
volume) takes roughly four minutes from `terraform apply` finishing to
the desktop actually answering HTTP - almost entirely because the
~2GB container image gets pulled from Docker Hub from scratch every
single time, and because the full network stack (VPC, subnet, IGW,
route table, security group) gets created and destroyed on every
session instead of once. If guests are going to get a hard 15-20
minute session limit, losing four of those minutes to boot is not
acceptable.

## Goals

- Three tiers: **admin**, **permanent user**, **guest** (default).
- Admins manage everything from a *separate* page,
  `admin.desktop.mnour.dev`: see every running session across all
  tiers, destroy any of them, add/remove other admins, add/remove
  permanent users, and set the guest session time limit (minutes).
- Guests (anyone who signs in and isn't an admin or permanent user):
  no "keep my files" option, session auto-destroyed after the
  admin-configured limit. A few minutes of drift on the cutoff is
  acceptable.
- Permanent users: same as today's guest flow, but with the persist
  checkbox available, and no forced expiry.
- The main page (`desktop.mnour.dev`) looks identical for every tier.
  No "you are a guest" messaging anywhere - only the presence/absence
  of the persist checkbox and, for guests, a countdown differ.
- Boot and destroy should be as fast as possible for everyone, not
  just guests - this is a systemic fix, not a guest-only patch.

## Non-goals

- No self-service signup or invite flow. Admins add people by typing
  an email into the admin page; that's it.
- No per-user AWS cost caps, budgets, or billing alerts. Out of scope
  for this pass.
- No change to how the owner's own desktop (`desk.mnour.dev`,
  `guest_username` empty) works - it keeps behaving exactly as it does
  today.
- Not attempting exact-to-the-second guest cutoff enforcement. A
  LaunchTime-based reaper with a few minutes of scheduling drift is
  the agreed bar.

## Data model (Vercel KV / Upstash Redis - same store already used for sessions)

Three new keys, alongside the existing per-username session hashes:

- `admins` - a Redis set of emails. Seeded with `mnuowr@gmail.com` on
  first read if the key doesn't exist yet (so there's never a
  zero-admin state).
- `permanent_users` - a Redis set of emails.
- `guest_limit_minutes` - a single integer, default `20` if unset.

A signed-in user's tier is computed at request time from their
session's email against these two sets - not stored on the session
itself, so changing someone's tier takes effect on their very next
poll, not just their next login.

## Auth changes (`lib/auth.js`)

`ADMIN_GOOGLE_SUB` (a single env var, checked against the Google
`sub`) is replaced by a KV-backed check against the `admins` set,
keyed by **email** rather than `sub` - email is what an admin actually
types in on the admin page, and `sub` is not something anyone can look
up or enter by hand. `verifySession` gains an `is_admin` computed the
same way it does today, just backed by the set instead of one env var.
Existing sessions are unaffected structurally; only the source of
truth for "is this an admin" moves.

`ADMIN_GOOGLE_SUB` env var is removed once the KV set is seeded and
verified working (see rollout).

## `admin.desktop.mnour.dev`

Same Vercel project, added as a second domain alias, same Google
Sign-In client (already authorizes the parent domain's family). New
static page (`admin.html` + `admin.js`) and new API routes:

- `GET /api/admin/state` - requires `is_admin`; returns every active
  session (any tier, all fields - unlike the guest-facing
  `/api/status`, which already redacts other users' data), the
  current `guest_limit_minutes`, and the `admins`/`permanent_users`
  lists.
- `POST /api/admin/destroy` - `{ username }`, requires `is_admin`.
  Thin wrapper around the same dispatch path `/api/dispatch` already
  uses for a self-destroy, just permitted against any username instead
  of only your own (the admin card on the *existing* page already has
  this exact capability today - it moves here, unchanged).
- `POST /api/admin/config` - `{ guest_limit_minutes }`, requires
  `is_admin`.
- `POST /api/admin/users` - `{ list: "admins" | "permanent_users",
  action: "add" | "remove", email }`, requires `is_admin`. Removing
  the last remaining admin is rejected server-side - there must always
  be at least one.

The existing admin card and history table on `desktop.mnour.dev`
(`renderAdmin` in `app.js`) are removed from that page entirely - all
admin capability lives on the new page only. The regular page stops
asking "is this session an admin" at all; it only needs "is this a
permanent user" (for the checkbox) and "is this a guest with a
countdown."

## Guest experience on the existing page

`renderMine` gains one more piece of state per session: for a guest,
`my_session` includes `expires_at` (computed as `started_at +
guest_limit_minutes * 60` at session-ready time). The Running card
shows a countdown next to the existing duration/cost line instead of
just duration - `Running · 12m (8m left) · ~$0.01`. No other visual
difference from a permanent user's or admin's own card. The persist
checkbox itself is simply absent from the DOM for a guest, not present
and disabled - so there's nothing in the page's HTML that reveals tier
by inspecting it either.

## Guest expiry enforcement (`desktop-reaper.yml`)

The existing reaper already discovers every running guest desktop by
AWS tag (`Role=guest-desktop`), independent of any hardcoded username
list - that part is reused as-is. Two changes:

1. Replace the activity-tracker check (`/last-activity`, explicitly
   never verified against real traffic per the workflow's own
   comments) with `LaunchTime` from the EC2 API compared against
   `guest_limit_minutes` fetched from a new read-only endpoint,
   `GET /api/admin/config`, authenticated the same way the existing
   START/DESTROY callbacks already are - a `Bearer $HUB_CALLBACK_SECRET`
   header, no new secret introduced. This is exactly the fallback the
   workflow's own comments already recommend, for the same reason: it
   depends on nothing running inside the instance, so it can't fail
   the way an in-guest tracker can.
2. Turn the schedule back on: `on: schedule: cron: '*/5 * * * *'`
   alongside the existing `workflow_dispatch`. Five-minute cadence,
   accepted drift per your answer.

Permanent users and the owner's own desktop are never touched by this
workflow - selection is still by the `guest-desktop` tag, and neither
of those carries it.

## Speed: split Terraform into network + instance stacks

Today `terraform/main.tf` creates and destroys the VPC, subnet,
internet gateway, route table, security group, key pair, *and* the
instance on every single session. Measured on a real run: VPC ~14s,
subnet ~12s, instance itself ~15s, plus IGW/route table/SG rules - the
network resources are the majority of both `apply` and `destroy` time,
and they're identical every time regardless of who's starting a
desktop.

Split into:

- **`terraform/network/`** - VPC, subnet, IGW, route table, security
  group, key pair. Applied once (a one-time `terraform apply` in this
  new directory, not run by any per-session workflow), left standing
  permanently. Nothing here is billable while idle - no NAT Gateway,
  no Elastic IP, security group rules cost nothing unattached.
- **`terraform/` (unchanged location, trimmed contents)** - just the
  instance, its DNS record, and the guest volume attachment where
  applicable. References the network stack's resources via a
  `terraform_remote_state` data source instead of creating them.

`desktop-up.yml` / `desktop-down.yml` are unaffected structurally -
same `-chdir=terraform`, same per-username state key - they just
apply/destroy far fewer resources per run now.

## Speed: a baked AMI instead of a shared cache volume

A shared EBS volume for the Docker layer cache (my first instinct)
does not work here: a volume attaches to one instance at a time, and
this system already supports multiple concurrent sessions
(`MAX_CONCURRENT`, currently 5) - two guests booting at once would
contend for the same volume.

Instead: a **custom AMI**, built once (a new manual workflow,
`bake-ami.yml`, run on demand - not on every push) that launches a
throwaway instance from the current base Ubuntu AMI, runs the exact
same first-boot steps `user-data.sh.tpl` already runs (pull the
`linuxserver/webtop` image, let Docker/containerd settle), then
creates an AMI from it and terminates the throwaway instance.
`terraform/variables.tf`'s `image` / AMI lookup switches from the
Ubuntu base AMI to this baked one. Every future launch - any tier, any
concurrency level - starts with the desktop image already present
locally; no shared resource, no attach conflict, scales to any number
of concurrent sessions.

Trade-off accepted: the AMI goes stale if the desktop image
(`linuxserver/webtop`) or base OS packages change. `bake-ami.yml` is
the fix when that happens - re-run it, `terraform/variables.tf` picks
up the new AMI ID (via an `aws_ami` data source filtered on a
`Name`/`Project` tag and `most_recent = true`, so no manual ID to
paste in after each bake).

## Rollout order

1. Data model + auth (KV-backed admin/permanent-user sets), seeded
   with the current single admin - deployed and verified before
   anything else depends on it.
2. Admin page, built and verified against the seeded data from step 1.
3. Guest countdown UI + reaper rewrite - verified with a short guest
   limit (e.g. 2 minutes) before defaulting to something realistic.
4. Terraform network/instance split - one-time apply of the network
   stack, then cut the per-session workflows over.
5. AMI bake - built and swapped in last, since it's the change with
   the least interaction with everything else and the easiest to
   verify in isolation (boot time before/after, same desktop
   otherwise).

Each step is independently revertable without touching the others -
deliberate, since this is a lot of surface area to land at once.

## Testing

- Admin auth: a non-admin, non-permanent email gets the guest
  experience end-to-end (no persist option, countdown present,
  destroyed by the reaper on a short test limit); a promoted permanent
  user gets the persist checkbox; an admin sees the admin page and can
  destroy someone else's session.
- Reaper: launch a guest desktop, set a 2-minute limit, confirm the
  scheduled run destroys it and the panel reflects that without a
  manual poke.
- Network split: confirm a `terraform apply`/`destroy` cycle on the
  instance stack alone no longer touches the VPC/subnet/SG (via
  `terraform plan` showing zero changes to those resources).
- AMI: time a boot from the baked AMI against the current ~4 minute
  baseline; confirm the desktop answers `/healthz` in well under a
  minute.
