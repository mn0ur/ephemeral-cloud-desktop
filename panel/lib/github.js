// GitHub Actions dispatch and run inspection.
//
// The token lives ONLY in this function's environment - never sent to the
// browser. A page that called the GitHub API directly would have to embed it
// in JavaScript, handing it to anyone who opened devtools.

import { runBelongsTo } from "./desktops.js";

const REPO = process.env.GH_REPO || "mn0ur/ephemeral-cloud-desktop";
const TOKEN = process.env.GH_TOKEN || "";

export const tokenConfigured = Boolean(TOKEN);

// Fixed allow-list. The workflow filename is never built from request input,
// so a crafted request cannot trigger an arbitrary workflow.
export const WORKFLOWS = {
  start: "desktop-up.yml",
  destroy: "desktop-down.yml",
  // Deletes a user's saved data volume. Separate from destroy on purpose:
  // destroy ends a session and KEEPS the data, this throws the data away.
  wipe: "desktop-wipe.yml",
  // Stops a machine without destroying it (Plan B). Its opposite is wake.
  sleep: "desktop-sleep.yml",
  wake: "desktop-wake.yml",
};

// Every api/*.js function has a 10s hard limit (vercel.json maxDuration). A
// GitHub call that hangs past that gets hard-killed by the platform BEFORE
// any catch block runs - which, for a caller holding a claim, means the
// claim is stuck for its full TTL with nothing in the logs explaining why.
// Aborting at 8s makes the hang fail INSIDE this function instead, with a
// clear error, leaving headroom for the caller's own cleanup to run.
const GITHUB_TIMEOUT_MS = 8000;

async function gh(path, options = {}) {
  if (!TOKEN) throw new Error("no GitHub token configured");
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GITHUB_TIMEOUT_MS);
  let r;
  try {
    r = await fetch(`https://api.github.com${path}`, {
      ...options,
      signal: controller.signal,
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
        "User-Agent": "desktop-control-panel",
        ...(options.headers || {}),
      },
    });
  } catch (e) {
    if (e.name === "AbortError") {
      throw new Error(`GitHub API call to ${path} timed out after ${GITHUB_TIMEOUT_MS}ms`);
    }
    throw e;
  } finally {
    clearTimeout(timer);
  }
  if (!r.ok) {
    const body = await r.text();
    const err = new Error(body.slice(0, 400) || `GitHub returned ${r.status}`);
    err.status = r.status;
    throw err;
  }
  return r.status === 204 ? {} : r.json();
}

export async function dispatch(workflowFile, inputs) {
  await gh(`/repos/${REPO}/actions/workflows/${workflowFile}/dispatches`, {
    method: "POST",
    body: JSON.stringify({ ref: "main", inputs }),
  });
}

// Live step-by-step state of the most recent desktop run, so a start that takes
// minutes is followable instead of a spinner indistinguishable from a hang, and
// a failure names the step that failed.
// Only the caller's own run for the action in flight (see runBelongsTo):
// showing the newest desktop run of anyone made a new user's Start look like
// an already-finished machine. 20, not 5: with several users active the
// caller's run is not guaranteed to be among the newest five.
export async function runProgress(username, sinceTs, verb) {
  try {
    const runs = (await gh(`/repos/${REPO}/actions/runs?per_page=20`)).workflow_runs || [];
    const run = runs.find((r) => runBelongsTo(r, username, sinceTs, verb));
    if (!run) return null;
    const jobs = (await gh(`/repos/${REPO}/actions/runs/${run.id}/jobs`)).jobs || [];
    const steps = [];
    for (const j of jobs) {
      for (const s of j.steps || []) {
        const name = s.name || "";
        // Runner bookkeeping is noise to somebody watching their desktop boot.
        if (
          name.startsWith("Set up job") ||
          name.startsWith("Post ") ||
          name.startsWith("Complete job") ||
          name.startsWith("Run actions/") ||
          name.startsWith("Run hashicorp/")
        ) {
          continue;
        }
        steps.push({ name, state: s.conclusion || s.status });
      }
    }
    return {
      name: run.display_title || run.name,
      status: run.status,
      conclusion: run.conclusion,
      url: run.html_url,
      steps,
    };
  } catch {
    return null;
  }
}
