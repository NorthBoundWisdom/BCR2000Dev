#!/usr/bin/env python3
"""Report queue and job time separately; enforce the same 300s job target for cold and warm builds."""

from __future__ import annotations

import argparse
import json
import os
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def report(run, job, cache_key, now):
    elapsed = (now - instant(job["started_at"])).total_seconds()
    whole = (now - instant(run["created_at"])).total_seconds()
    warm = bool(cache_key)
    lines = [
        "## Job wall time and 300s budget",
        "Policy: user clarification after ALIGN3; cold and warm executions share the 300s target. Queue time is diagnostic.",
        "",
        f"Run: `{run['id']}` · job `{job['name']}` · {'warm build cache' if warm else 'cold build cache'} · **{elapsed:.1f}s job wall time** · {whole:.1f}s since run creation",
        f"Restored build key: `{cache_key or 'none'}`",
        "",
        "| Step | Result | Seconds |",
        "| --- | --- | ---: |",
    ]
    for step in job["steps"]:
        duration = "—"
        if step.get("started_at"):
            end = instant(step["completed_at"]) if step.get("completed_at") else now
            duration = f"{max(0, (end - instant(step['started_at'])).total_seconds()):.1f}"
        lines.append(f"| {step['name'].replace('|', '/')} | {step.get('conclusion') or step['status']} | {duration} |")
    lines += [
        "",
        "Scope: this live check, job start through this check; whole-run creation/queue time is reported separately. Other jobs and post-job cleanup may still be running; final completed wall times must also be independently checked after completion.",
    ]
    failed = elapsed > 300
    lines.append("**Job 300s budget exceeded.**" if failed else "Job 300s budget met; no cold-cache exemption.")
    return "\n".join(lines) + "\n", failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-key", default="")
    args = parser.parse_args()
    env = os.environ
    base = f"{env.get('GITHUB_API_URL', 'https://api.github.com')}/repos/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"
    headers = {"Authorization": "Bearer " + env["GH_TOKEN"], "Accept": "application/vnd.github+json"}
    request = urllib.request.Request(base, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        run = json.load(response)
    request = urllib.request.Request(base + f"/attempts/{env['GITHUB_RUN_ATTEMPT']}/jobs?per_page=100", headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        jobs = json.load(response)["jobs"]
    matches = [job for job in jobs if job["name"] == env["GITHUB_JOB"]]
    if len(matches) != 1:
        raise SystemExit("Cannot identify exactly one current job for timing")
    body, failed = report(run, matches[0], args.cache_key, datetime.now(timezone.utc))
    with Path(env["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write(body)
    print(body)
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
