import { verifyGoogleToken, signSession, sessionCookie, SESSION_MAX_AGE,
         GOOGLE_CLIENT_ID, SESSION_SECRET } from "../lib/auth.js";
import { usernameFor, logEvent } from "../lib/state.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!GOOGLE_CLIENT_ID || !SESSION_SECRET) {
    return res.status(400).json({ error: "sign-in is not configured on this deployment" });
  }
  const claims = await verifyGoogleToken(req.body?.credential);
  if (!claims) return res.status(401).json({ error: "google rejected that token" });

  const username = await usernameFor(claims.sub, claims.email);
  await logEvent("login", { username, email: claims.email });

  const cookie = signSession({
    sub: claims.sub,
    email: claims.email,
    user_id: username,
    exp: Date.now() / 1000 + SESSION_MAX_AGE,
  });
  res.setHeader("Set-Cookie", sessionCookie(cookie, SESSION_MAX_AGE));
  return res.status(200).json({ user_id: username, email: claims.email });
}
