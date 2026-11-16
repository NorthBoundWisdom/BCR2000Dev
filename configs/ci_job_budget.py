#!/usr/bin/env python3
"""Report actual GitHub job/step wall times; enforce 300s only with a restored build cache."""

from __future__ import annotations

import argparse
import json
import os
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


def instant(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def report(job, cache_key, now):
    elapsed = (now - instant(job["started_at"])).total_seconds()
    warm = bool(cache_key)
    lines = [
        "## Job wall time and warm-cache budget",
        "",
        f"Job: `{job['name']}` · {'warm build cache' if warm else 'cold-cache bootstrap'} · **{elapsed:.1f}s**",
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
        "Scope: job start through this final check, including setup/cache operations; post-job cleanup is not yet complete.",
    ]
    failed = warm and elapsed > 300
    lines.append(
        "**Warm-cache 300s budget exceeded.**"
        if failed
        else (
            "Cold bootstrap is measured but exempt from the warm-cache budget."
            if not warm
            else "Warm-cache 300s budget met."
        )
    )
    return "\n".join(lines) + "\n", failed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-key", default="")
    args = parser.parse_args()
    env = os.environ
    url = (
        f"{env.get('GITHUB_API_URL', 'https://api.github.com')}/repos/{env['GITHUB_REPOSITORY']}/actions/runs/"
        f"{env['GITHUB_RUN_ID']}/attempts/{env['GITHUB_RUN_ATTEMPT']}/jobs?per_page=100"
    )
    request = urllib.request.Request(
        url, headers={"Authorization": "Bearer " + env["GH_TOKEN"], "Accept": "application/vnd.github+json"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        jobs = json.load(response)["jobs"]
    matches = [job for job in jobs if job["name"] == env["GITHUB_JOB"]]
    if len(matches) != 1:
        raise SystemExit("Cannot identify exactly one current job for timing")
    body, failed = report(matches[0], args.cache_key, datetime.now(timezone.utc))
    with Path(env["GITHUB_STEP_SUMMARY"]).open("a") as summary:
        summary.write(body)
    print(body)
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
