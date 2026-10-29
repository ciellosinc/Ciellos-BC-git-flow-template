#!/usr/bin/env python3
"""
Posts to a Teams channel what is in the Sandbox right now, after a deployment of sandbox/current.
Run by the "Sandbox Deployed" workflow once mark-sandbox-deployed.sh has confirmed that the
"Deploy to Sandbox" job really succeeded - testers learn what they can look at without opening
GitHub.

  notify-teams.py             # post it
  notify-teams.py --dry-run   # print the payload, post nothing

Inputs, from the environment:
  TEAMS_WEBHOOK_URL   the URL of a Teams Workflows webhook ("Send webhook alerts to a channel").
                      Not set: nothing is posted - the notification is optional.
  DEPLOYED_SHA        the manifest commit assemble-sandbox.sh wrote, as deployed
  RUN_URL             the CI/CD run that deployed it
  SANDBOX_URL         optional: the BC Sandbox, for an "Open the Sandbox" button
  GITHUB_REPOSITORY, GITHUB_SERVER_URL - set by GitHub Actions

Office 365 connectors (the old Incoming Webhooks) are retired in Teams. A Workflows webhook takes a
message with an Adaptive Card attachment, which is what this sends.

Nothing here may turn a good deployment red: every outcome exits 0 and says what it did.
"""

import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

MANIFEST_PREFIX = "sandbox/current: assembled from"


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True,
                          encoding="utf-8").stdout


def manifest(sha):
    """The Included and Skipped rows of a manifest commit, or None if sha is not one."""
    try:
        body = git("log", "-1", "--format=%B", sha).replace("\r", "")
    except subprocess.CalledProcessError:
        return None
    if not body.startswith(MANIFEST_PREFIX):
        return None
    header = body.splitlines()[0]
    included, skipped, section = [], [], None
    for line in body.splitlines()[1:]:
        if line.startswith("Included:"):
            section = included
            continue
        if line.startswith("Skipped:"):
            section = skipped
            continue
        # "  #12 feature/x @ abc1234" or, under Skipped, "... @ abc1234 - reason"
        fields = line.split()
        if section is None or len(fields) < 4 or not fields[0].startswith("#") or fields[2] != "@":
            continue
        reason = line.split(" - ", 1)[1] if " - " in line else ""
        section.append({"number": fields[0][1:], "branch": fields[1], "sha": fields[3],
                        "reason": reason})
    return header, included, skipped


def pr_title(number):
    """The title of a pull request, or None - a missing title only costs the line its text."""
    try:
        # shutil.which honours PATHEXT on Windows, where a plain "gh" would only ever find gh.exe.
        out = subprocess.run([shutil.which("gh") or "gh", "pr", "view", number, "--json", "title"],
                             check=True,
                             capture_output=True, text=True, encoding="utf-8",
                             stdin=subprocess.DEVNULL).stdout
        return json.loads(out).get("title")
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None


def md(text):
    # Adaptive Card text is Markdown; a title with brackets or emphasis characters must not turn
    # into a broken link or half the card in italics.
    for ch in "\\[]*_`":
        text = text.replace(ch, "\\" + ch)
    return text


def card(header, included, skipped, repo_url, run_url, sandbox_url):
    def line(pr, with_reason):
        title = pr_title(pr["number"])
        text = f"- [#{pr['number']}]({repo_url}/pull/{pr['number']}) "
        text += md(title) if title else md(pr["branch"])
        text += f" @ `{pr['sha']}`"
        if with_reason and pr["reason"]:
            text += f" - {md(pr['reason'])}"
        return text

    body = [
        {"type": "TextBlock", "text": "Sandbox updated", "weight": "Bolder", "size": "Medium"},
        {"type": "TextBlock", "text": md(header), "isSubtle": True, "spacing": "None", "wrap": True},
        {"type": "TextBlock", "text": f"In the Sandbox now ({len(included)})", "weight": "Bolder",
         "spacing": "Medium"},
        {"type": "TextBlock", "wrap": True, "spacing": "Small",
         "text": "\n".join(line(pr, False) for pr in included) or "Only `main`, no pull requests."},
    ]
    if skipped:
        body += [
            {"type": "TextBlock", "text": f"Left out ({len(skipped)})", "weight": "Bolder",
             "spacing": "Medium"},
            {"type": "TextBlock", "wrap": True, "spacing": "Small",
             "text": "\n".join(line(pr, True) for pr in skipped)},
        ]
    actions = []
    if sandbox_url:
        actions.append({"type": "Action.OpenUrl", "title": "Open the Sandbox", "url": sandbox_url})
    actions.append({"type": "Action.OpenUrl", "title": "Pull requests in the Sandbox",
                    "url": f"{repo_url}/pulls?q=is%3Apr+is%3Aopen+label%3Ain-sandbox"})
    if run_url:
        actions.append({"type": "Action.OpenUrl", "title": "CI/CD run", "url": run_url})

    return {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "contentUrl": None,
            "content": {
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.4",
                "msteams": {"width": "Full"},
                "body": body,
                "actions": actions,
            },
        }],
    }


def main(argv):
    dry = argv[:1] == ["--dry-run"]
    url = os.environ.get("TEAMS_WEBHOOK_URL", "").strip()
    if not url and not dry:
        print("TEAMS_WEBHOOK_URL is not set - no Teams notification")
        return 0

    sha = os.environ.get("DEPLOYED_SHA", "")
    found = manifest(sha) if sha else None
    if found is None:
        print(f"commit '{sha}' is not a sandbox manifest - no Teams notification")
        return 0

    repo_url = (os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/") + "/"
                + os.environ.get("GITHUB_REPOSITORY", ""))
    payload = card(*found, repo_url, os.environ.get("RUN_URL", ""),
                   os.environ.get("SANDBOX_URL", "").strip())

    if dry:
        print(json.dumps(payload, indent=2))
        return 0

    request = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"),
                                     headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            print(f"posted to Teams ({response.status}): {len(found[1])} pull requests in the Sandbox")
    except (urllib.error.URLError, OSError) as e:
        # The webhook URL is a secret; the error text from urllib does not include it.
        print(f"::warning::Teams notification failed: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
