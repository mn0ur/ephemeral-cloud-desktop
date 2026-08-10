// Google sign-in verification and HMAC-signed session cookies.
//
// Sessions are a signed cookie, not a session store: the payload (email,
// username, expiry) is not secret, only tamper-evidence matters. Verification
// of the Google credential is delegated to Google's own tokeninfo endpoint
// rather than validating RS256 locally - the same choice the hub made, and it
// keeps this dependency-light.

import crypto from "node:crypto";

export const GOOGLE_CLIENT_ID = process.env.GOOGLE_CLIENT_ID || "";
export const ADMIN_GOOGLE_SUB = process.env.ADMIN_GOOGLE_SUB || "";
export const SESSION_SECRET = process.env.SESSION_SECRET || "";
export const HUB_CALLBACK_SECRET = process.env.HUB_CALLBACK_SECRET || "";
export const SESSION_MAX_AGE = 12 * 3600;

const b64 = (buf) => Buffer.from(buf).toString("base64url");

export function signSession(payload) {
  const body = b64(JSON.stringify(payload));
  const sig = crypto.createHmac("sha256", SESSION_SECRET).update(body).digest("hex");
  return `${body}.${sig}`;
}

export function verifySession(value) {
  if (!value || !SESSION_SECRET) return null;
  const dot = value.lastIndexOf(".");
  if (dot < 1) return null;
  const body = value.slice(0, dot);
  const sig = value.slice(dot + 1);
  const expected = crypto.createHmac("sha256", SESSION_SECRET).update(body).digest("hex");
  // timingSafeEqual throws on length mismatch, so guard before comparing.
  if (sig.length !== expected.length) return null;
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return null;
  let payload;
  try {
    payload = JSON.parse(Buffer.from(body, "base64url").toString());
  } catch {
    return null;
  }
  if (!payload.exp || payload.exp < Date.now() / 1000) return null;
  payload.is_admin = Boolean(ADMIN_GOOGLE_SUB) && payload.sub === ADMIN_GOOGLE_SUB;
  return payload;
}

export function sessionFromRequest(req) {
  const raw = req.headers.cookie || "";
  const match = raw.split(/;\s*/).find((c) => c.startsWith("session="));
  if (!match) return null;
  return verifySession(decodeURIComponent(match.slice("session=".length)));
}

export function sessionCookie(value, maxAge) {
  // Path=/ matters: this app serves its API at /api/*, and a cookie scoped to
  // a subpath simply is not sent - which is exactly the bug that made sign-in
  // silently do nothing on the hub.
  return `session=${value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`;
}

// Google validates signature and expiry; we still must check the audience is
// THIS app and that the address is verified, or any Google token for any app
// would be accepted.
export async function verifyGoogleToken(credential) {
  if (!credential || !GOOGLE_CLIENT_ID) return null;
  let claims;
  try {
    const r = await fetch(
      `https://oauth2.googleapis.com/tokeninfo?id_token=${encodeURIComponent(credential)}`
    );
    if (!r.ok) return null;
    claims = await r.json();
  } catch {
    return null;
  }
  if (claims.aud !== GOOGLE_CLIENT_ID) return null;
  if (claims.email_verified !== "true" && claims.email_verified !== true) return null;
  if (!claims.email || !claims.sub) return null;
  return claims;
}

export function bearerOk(req, expected) {
  if (!expected) return false;
  const got = req.headers.authorization || "";
  const want = `Bearer ${expected}`;
  if (got.length !== want.length) return false;
  return crypto.timingSafeEqual(Buffer.from(got), Buffer.from(want));
}
