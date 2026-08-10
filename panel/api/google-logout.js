import { sessionCookie } from "../lib/auth.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  res.setHeader("Set-Cookie", sessionCookie("", 0));
  return res.status(200).json({ ok: true });
}
