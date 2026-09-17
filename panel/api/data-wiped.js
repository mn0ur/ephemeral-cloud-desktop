import { bearerOk, HUB_CALLBACK_SECRET } from "../lib/auth.js";
import { setHasData, logEvent, loadMachines, putMachine } from "../lib/state.js";
import { MACHINE_OSES, machineKey } from "../lib/machines.js";

export default async function handler(req, res) {
  if (req.method !== "POST") return res.status(405).json({ error: "POST only" });
  if (!bearerOk(req, HUB_CALLBACK_SECRET)) {
    return res.status(403).json({ error: "bad callback secret" });
  }
  const username = req.body?.username;
  if (!username) return res.status(400).json({ error: "bad username" });
  await setHasData(username, false);
  const os = req.body?.os;

  // A wipe of a SLEEPING machine detaches and deletes its data volume
  // (desktop-wipe.yml), and a wake runs no Terraform - so that machine would
  // boot expecting a volume that no longer exists (the Linux bind-mount, the
  // Windows D: drive) while the panel happily showed it Running. The wipe
  // workflow sets this flag exactly when it had to detach from a stopped
  // instance; the record is tombstoned so the next Start builds a whole
  // machine instead of waking a broken one.
  let tombstoned = false;
  if (req.body?.tombstone_machine && MACHINE_OSES.includes(os)) {
    const machines = await loadMachines();
    const prior = machines[machineKey(username, os)];
    if (prior && prior.state !== "deleted") {
      await putMachine(username, os, {
        os, state: "deleted", deleted_at: Date.now() / 1000, deleted_reason: "data_wiped",
      });
      tombstoned = true;
    }
  }

  await logEvent("data_wiped", { username, os: os || null, tombstoned });
  return res.status(200).json({ ok: true, tombstoned });
}
