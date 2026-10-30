#!/usr/bin/env bash
#
# Makes the `in-sandbox` label mean what it says: this pull request is deployed in the Sandbox
# environment right now. Run by the "Sandbox Deployed" workflow after a CI/CD run on the
# assembled branch has finished.
#
# The label used to be set when the branch was assembled, before anything had been built. A build
# that then failed left the label on requests that were nowhere near the environment. So the label
# follows the deployment instead, and only this script touches it:
#
#   - nothing happens unless the run's "Deploy to Sandbox" job succeeded. The run as a whole being
#     green is not enough: that job is skipped, and the run still green, when there is nothing to
#     deploy to;
#   - the requests named in the `Included:` section of the deployed manifest commit get the label
#     and, once per commit, a comment naming what was deployed;
#   - every other open request that still carries the label loses it, and so does a request that
#     was closed without being merged. A merged request keeps it, as a record that it was there.
#
# What changed is handed on to the Teams notification through $GITHUB_OUTPUT. The labels, read
# before this script touches them, are the previous deployment, so the change is the difference:
#   added=<number>@<sha> ...     requests that were not in the Sandbox before
#   removed=<number>:<why> ...   requests that left it, why being draft, closed or removed
# A request that left because it was merged into main is in neither: that is the normal way out,
# and nothing anyone needs to be told about.
#
# Inputs, from the workflow_run event:
#   DEPLOYED_SHA  head commit of the CI/CD run - the manifest commit assemble-sandbox.sh wrote
#   RUN_ID        id of that CI/CD run
#   RUN_URL       link to it, for the comment
#
# Nothing here may turn a good deployment red, so every outcome exits 0 and says what it did.

set -eu

LABEL=in-sandbox
DEPLOY_JOB="Deploy to Sandbox"
MANIFEST_PREFIX="sandbox/current: assembled from"
ROOT="$(git rev-parse --show-toplevel)"
TAB="$(printf '\t')"

: "${DEPLOYED_SHA:?}" "${RUN_ID:?}" "${RUN_URL:?}"

outcome="$(gh run view "$RUN_ID" --json jobs \
               --jq '.jobs[] | [.name, (.conclusion // "")] | @tsv' </dev/null 2>/dev/null \
           | tr -d '\r' | awk -F'\t' -v job="$DEPLOY_JOB" '$1 == job { print $2 }' | tail -1)"
if [ "$outcome" != "success" ]; then
    echo "\"$DEPLOY_JOB\" is '${outcome:-absent}' in run $RUN_ID - the Sandbox did not change, labels left alone"
    exit 0
fi

# The run may be about an assembly that has since been force-pushed away; it is usually still
# fetchable by SHA, and if it is not there is nothing to read.
if ! git -C "$ROOT" cat-file -e "$DEPLOYED_SHA^{commit}" 2>/dev/null; then
    git -C "$ROOT" fetch --quiet origin "$DEPLOYED_SHA" 2>/dev/null || true
fi
if ! git -C "$ROOT" cat-file -e "$DEPLOYED_SHA^{commit}" 2>/dev/null; then
    echo "commit $DEPLOYED_SHA is not available - labels left alone"
    exit 0
fi

body="$(git -C "$ROOT" log -1 --format=%B "$DEPLOYED_SHA" | tr -d '\r')"
case "$body" in
    "$MANIFEST_PREFIX"*) ;;
    *) echo "commit $DEPLOYED_SHA is not a sandbox manifest - labels left alone"; exit 0 ;;
esac

# "  #90 some/branch @ 6f3b6a9" inside Included: only. The number is the first field, so a '#'
# inside a branch name is never mistaken for one.
INCLUDED="$(printf '%s\n' "$body" | awk '
    /^Included:/ { on = 1; next }
    /^Skipped:/  { on = 0 }
    on && $1 ~ /^#[0-9]+$/ && $3 == "@" { printf "%s\t%s\t%s\n", substr($1, 2), $2, $4 }')"

gh label create "$LABEL" --color 0E8A16 \
    --description 'Deployed in the Sandbox environment right now' </dev/null >/dev/null 2>&1 || true

# Every gh call reads /dev/null: the loops below have their own stdin, and a command that read it
# would swallow the rest of the list.
comment_once() {  # <pr> <marker> <body>
    if gh pr view "$1" --json comments --jq '.comments[].body' </dev/null 2>/dev/null | grep -qF "$2"; then
        return 0
    fi
    printf '%s\n\n<!-- %s -->\n' "$3" "$2" | gh pr comment "$1" --body-file - >/dev/null 2>&1 || true
}

ASSEMBLY="$(printf %.7s "$DEPLOYED_SHA")"

# The previous deployment, read before anything below changes a label: the open requests that carry
# it, one "number<TAB>isDraft" row each. If this cannot be read, the labels are still put right, but
# nobody can say what changed, so no change is reported.
KNOWN=1
PREV="$(gh pr list --state open --label "$LABEL" --limit 200 --json number,isDraft \
            --jq '.[] | "\(.number)\t\(.isDraft)"' </dev/null 2>/dev/null)" || { PREV=""; KNOWN=0; }
PREV="$(printf '%s' "$PREV" | tr -d '\r')"
PREV_NUMS=" $(printf '%s\n' "$PREV" | awk -F"$TAB" 'NF { printf "%s ", $1 }')"

# Requests closed in the last week that still carry the label: closed while they were in the
# Sandbox. One "number<TAB>merged" row each. The week only keeps the first run of this script from
# digging up every request ever closed with the label on.
CUTOFF="$(date -u -d '7 days ago' +%Y-%m-%d 2>/dev/null || true)"
SEARCH=()
[ -z "$CUTOFF" ] || SEARCH=(--search "closed:>=$CUTOFF")
CLOSED="$(gh pr list --state closed --label "$LABEL" --limit 100 "${SEARCH[@]+"${SEARCH[@]}"}" \
              --json number,mergedAt --jq '.[] | "\(.number)\t\(.mergedAt != null)"' \
              </dev/null 2>/dev/null | tr -d '\r' || true)"

NUMBERS=" "
ADDED=""
while IFS="$TAB" read -r num branch short; do
    [ -n "$num" ] || continue
    NUMBERS="$NUMBERS$num "
    case "$PREV_NUMS" in *" $num "*) ;; *) ADDED="$ADDED $num@$short" ;; esac
    gh pr edit "$num" --add-label "$LABEL" </dev/null >/dev/null 2>&1 || true
    comment_once "$num" "sandbox-deployed:$short" \
        "Commit \`$short\` of this branch is deployed in the Sandbox environment (assembly \`$ASSEMBLY\`, [CI/CD run]($RUN_URL)). That is the commit to look at in BC before ticking the verification box."
    echo "  #$num $branch @ $short: deployed, labelled"
done <<LIST
$INCLUDED
LIST

# Whatever else still carries the label is not in the environment any more.
REMOVED=""
while IFS="$TAB" read -r num isdraft; do
    [ -n "$num" ] || continue
    case "$NUMBERS" in *" $num "*) continue ;; esac
    gh pr edit "$num" --remove-label "$LABEL" </dev/null >/dev/null 2>&1 || true
    if [ "$isdraft" = "true" ]; then why=draft; else why=removed; fi
    REMOVED="$REMOVED $num:$why"
    echo "  #$num: not in this deployment ($why), label removed"
done <<LIST
$PREV
LIST

# A request closed without a merge left the Sandbox by being abandoned; a merged one went to main.
while IFS="$TAB" read -r num merged; do
    [ -n "$num" ] || continue
    [ "$merged" = "false" ] || continue
    gh pr edit "$num" --remove-label "$LABEL" </dev/null >/dev/null 2>&1 || true
    REMOVED="$REMOVED $num:closed"
    echo "  #$num: closed without a merge, label removed"
done <<LIST
$CLOSED
LIST

echo "labels follow assembly $ASSEMBLY"

# Tells the workflow that this run really deployed a manifest, and what changed, so the steps after
# this one (the Teams notification) can rely on it instead of checking the same things again.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "deployed=true"
        echo "changes_known=$KNOWN"
        echo "added=${ADDED# }"
        echo "removed=${REMOVED# }"
    } >> "$GITHUB_OUTPUT"
fi
