// Persistent state, in Redis rather than on a disk.
//
// The hub kept four files on an EBS volume: sessions.json, users.json,
// history.jsonl and data_flags.json. Serverless functions have no durable
// filesystem, so each becomes a Redis key. That is not a downgrade - losing
// hub state to an instance replacement bit this project three separate times
// (the GitHub token, the admin sub, then the data flags), and this removes the
// entire class of problem along with the instance.

import { Redis } from "@upstash/redis";

// Vercel injects these when a KV/Upstash store is attached to the project.
// Both naming schemes are accepted because the marketplace integration and the
// older Vercel KV integration use different prefixes, and getting this wrong
// fails at runtime rather than at deploy time.
const url =
  process.env.KV_REST_API_URL ||
  process.env.UPSTASH_REDIS_REST_URL ||
  process.env.REDIS_URL;
const token =
  process.env.KV_REST_API_TOKEN ||
  process.env.UPSTASH_REDIS_REST_TOKEN ||
  process.env.REDIS_TOKEN;

export const stateConfigured = Boolean(url && token);

const redis = stateConfigured ? new Redis({ url, token }) : null;

function requireRedis() {
  if (!redis) {
    throw new Error(
      "No KV store attached. Create one in Vercel > Storage and connect it to this project."
    );
  }
  return redis;
}

const K = {
  sessions: "sessions",   // hash: username -> session JSON
  users: "users",         // hash: google sub -> username
  usernames: "usernames", // hash: username -> google sub  (reverse, for collisions)
  history: "history",     // list: newest first
  dataFlags: "dataflags", // hash: username -> "1" when they have a saved volume
};

// -- sessions ---------------------------------------------------------------

export async function loadSessions() {
  const raw = (await requireRedis().hgetall(K.sessions)) || {};
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    out[k] = typeof v === "string" ? JSON.parse(v) : v;
  }
  return out;
}

export async function putSession(username, session) {
  await requireRedis().hset(K.sessions, { [username]: JSON.stringify(session) });
}

export async function dropSession(username) {
  await requireRedis().hdel(K.sessions, username);
}

// -- users ------------------------------------------------------------------

// The desktop username is the email's local part - "alice", not a hashed slug -
// for as long as no other Google account has claimed it. The username also
// decides which EBS volume a "keep my data" session reuses, so a collision
// would hand one person's files to whoever signed in second. A stable
// sub -> username mapping prevents that, and a second account with the same
// local part is disambiguated rather than colliding.
export async function usernameFor(sub, email) {
  const r = requireRedis();
  const existing = await r.hget(K.users, sub);
  if (existing) return existing;

  const local = (email.includes("@") ? email.split("@")[0] : email).toLowerCase();
  const base =
    local.replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 20) || "guest";

  let candidate = base;
  let n = 2;
  // hsetnx is atomic: it only claims the name if nobody else holds it, so two
  // simultaneous first-time sign-ins cannot both take the same username.
  while (!(await r.hsetnx(K.usernames, candidate, sub))) {
    const owner = await r.hget(K.usernames, candidate);
    if (owner === sub) break; // already ours
    candidate = `${base}-${n++}`;
  }

  await r.hset(K.users, { [sub]: candidate });
  await logEvent("first_login", { username: candidate, email });
  return candidate;
}

export async function allUsernames() {
  const raw = (await requireRedis().hgetall(K.users)) || {};
  return Object.values(raw);
}

// -- history ----------------------------------------------------------------

export async function logEvent(event, fields = {}) {
  try {
    const r = requireRedis();
    await r.lpush(K.history, JSON.stringify({ ts: Date.now() / 1000, event, ...fields }));
    // Keep the log bounded. Unbounded growth on a free tier eventually costs
    // either money or writes; 2000 events is far more than anyone reads.
    await r.ltrim(K.history, 0, 1999);
  } catch {
    // History is a record, not a control path - never fail a request over it.
  }
}

export async function readHistory(limit = 500) {
  const rows = (await requireRedis().lrange(K.history, 0, limit - 1)) || [];
  return rows.map((r) => (typeof r === "string" ? JSON.parse(r) : r));
}

// -- saved-data flags -------------------------------------------------------

export async function setHasData(username, value) {
  const r = requireRedis();
  if (value) await r.hset(K.dataFlags, { [username]: "1" });
  else await r.hdel(K.dataFlags, username);
}

export async function hasSavedData(username) {
  return Boolean(await requireRedis().hget(K.dataFlags, username));
}
