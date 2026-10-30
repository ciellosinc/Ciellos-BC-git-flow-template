#!/usr/bin/env python3
"""
Tells a Teams channel when the set of pull requests in the Sandbox changes: which requests are new
in it, and which left it because they were marked as draft, closed, or removed. Run by the
"Sandbox Deployed" workflow after mark-sandbox-deployed.sh has confirmed a real deployment and
worked out what changed.

  notify-teams.py             # post it
  notify-teams.py --dry-run   # print the payload, post nothing

Only changes are posted, never the full list. A new commit to a request that is in the Sandbox
already, or a request that left because it was merged into main, changes nothing anyone needs to
hear about in a channel - the request itself gets a comment either way. No change, no card.

Inputs, from the environment:
  TEAMS_WEBHOOK_URL   the URL of a Teams Workflows webhook ("Send webhook alerts to a channel").
                      Not set: nothing is posted - the notification is optional.
  SANDBOX_ADDED       "<number>@<sha> ..." - requests that are new in the Sandbox
  SANDBOX_REMOVED     "<number>:<draft|closed|removed> ..." - requests that left it
  CHANGES_KNOWN       "0" when mark-sandbox-deployed.sh could not read the previous state
  DEPLOYED_SHA        the assembly that was deployed
  RUN_ID, RUN_URL     the CI/CD run that deployed it - its artifacts give the build version
  SANDBOX_URL         optional: the BC Sandbox, for an "Open the Sandbox" button
  GITHUB_REPOSITORY, GITHUB_SERVER_URL - set by GitHub Actions

Office 365 connectors (the old Incoming Webhooks) are retired in Teams. A Workflows webhook takes a
message with an Adaptive Card attachment, which is what this sends.

Nothing here may turn a good deployment red: every outcome exits 0 and says what it did.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

WHY = {
    "draft": "marked as draft",
    "closed": "closed without a merge",
    "removed": "removed from the Sandbox",
}


def parse(text, sep):
    """'118@4f1c2aa 121@9be03d1' -> [('118', '4f1c2aa'), ...]; anything malformed is dropped."""
    rows = []
    for item in text.split():
        number, _, value = item.partition(sep)
        if number.isdigit() and re.fullmatch(r"[A-Za-z0-9]+", value or "x"):
            rows.append((number, value))
    return rows


def gh(*args):
    """The output of a gh call, or None when it fails."""
    try:
        # shutil.which honours PATHEXT on Windows, where a plain "gh" would only ever find gh.exe.
        return subprocess.run([shutil.which("gh") or "gh", *args],
                              check=True, capture_output=True, text=True, encoding="utf-8",
                              stdin=subprocess.DEVNULL).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def pr_title(number):
    """The title of a pull request, or None - a missing title only costs the line its text."""
    try:
        return json.loads(gh("pr", "view", number, "--json", "title") or "").get("title")
    except ValueError:
        return None


def build_version(repo, run_id):
    """
    The version AL-Go built in the run, e.g. "1.4.513.0", or None. AL-Go puts it at the end of the
    name of every artifact ("<repo>-<branch>-Apps-1.4.513.0"), whatever versioningStrategy made
    it, so it is read from there rather than worked out from the run number. Projects with
    different versions are all listed.
    """
    if not (repo and run_id.isdigit()):
        return None
    try:
        artifacts = json.loads(gh("api", f"repos/{repo}/actions/runs/{run_id}/artifacts") or "")
        names = [a.get("name", "") for a in artifacts.get("artifacts", [])]
    except (ValueError, AttributeError):
        return None
    found = sorted({m.group(1) for n in names
                    if (m := re.search(r"-Apps-(\d+(?:\.\d+){1,3})$", n))})
    return ", ".join(found) or None


def md(text):
    # Adaptive Card text is Markdown; a title with brackets or emphasis characters must not turn
    # into a broken link or half the card in italics.
    for ch in "\\[]*_`":
        text = text.replace(ch, "\\" + ch)
    return text


def card(added, removed, repo_url, deployed, run_url, sandbox_url):
    def line(number, tail):
        title = pr_title(number)
        text = f"- [#{number}]({repo_url}/pull/{number})"
        if title:
            text += " " + md(title)
        return text + tail

    body = [
        {"type": "TextBlock", "text": "Sandbox changed", "weight": "Bolder", "size": "Medium"},
        {"type": "TextBlock", "text": f"{deployed} is deployed.", "isSubtle": True,
         "spacing": "None", "wrap": True},
    ]
    if added:
        body += [
            {"type": "TextBlock", "text": f"New in the Sandbox ({len(added)})", "weight": "Bolder",
             "spacing": "Medium"},
            {"type": "TextBlock", "wrap": True, "spacing": "Small",
             "text": "\n".join(line(n, f" @ `{sha}`") for n, sha in added)},
        ]
    if removed:
        body += [
            {"type": "TextBlock", "text": f"Left the Sandbox ({len(removed)})", "weight": "Bolder",
             "spacing": "Medium"},
            {"type": "TextBlock", "wrap": True, "spacing": "Small",
             "text": "\n".join(line(n, f" - {WHY.get(why, why)}") for n, why in removed)},
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

    if os.environ.get("CHANGES_KNOWN", "1") == "0":
        print("the previous state of the Sandbox could not be read - no Teams notification")
        return 0

    added = parse(os.environ.get("SANDBOX_ADDED", ""), "@")
    removed = parse(os.environ.get("SANDBOX_REMOVED", ""), ":")
    if not added and not removed:
        print("no request came into the Sandbox or left it - no Teams notification")
        return 0

    repo = os.environ.get("GITHUB_REPOSITORY", "")
    repo_url = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/") + "/" + repo
    # The build version is what people find in BC (Extension Management); the assembly commit is
    # the fallback when the run's artifacts cannot be read.
    version = build_version(repo, os.environ.get("RUN_ID", ""))
    deployed = (f"Build `{version}`" if version
                else f"Assembly `{os.environ.get('DEPLOYED_SHA', '')[:7]}`")
    payload = card(added, removed, repo_url, deployed, os.environ.get("RUN_URL", ""),
                   os.environ.get("SANDBOX_URL", "").strip())

    if dry:
        print(json.dumps(payload, indent=2))
        return 0

    request = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"),
                                     headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            print(f"posted to Teams ({response.status}): {len(added)} new, {len(removed)} left")
    except (urllib.error.URLError, OSError) as e:
        # The webhook URL is a secret; the error text from urllib does not include it.
        print(f"::warning::Teams notification failed: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
