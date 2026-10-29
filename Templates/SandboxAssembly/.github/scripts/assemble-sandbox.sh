#!/usr/bin/env bash
#
# Assembles the `sandbox/current` branch: origin/main plus the head commit of every open pull
# request that is ready for it. AL-Go then builds that branch and deploys it to the Sandbox environment.
#
#   .github/scripts/assemble-sandbox.sh --dry-run   # show what would be assembled, push nothing
#   .github/scripts/assemble-sandbox.sh             # assemble, push, tell skipped requests why
#
# A pull request is ready when it is open against main, is not a draft, comes from this repository
# and its head commit passed "Pull Request Status Check". Marking a request as draft is how work is
# kept out of the sandbox.
#
# The branch is rebuilt from scratch every time and force-pushed, so nothing in it is unique: a
# request that was closed simply is not there after the next run. Nothing is ever resolved here. A
# request that does not merge cleanly is skipped and told why; the fix belongs in its own branch.
#
# Only application code comes from pull requests. .github, and every .AL-Go folder at any depth,
# are always the ones on main: CI/CD on this branch reads its settings and workflows from this
# branch, and runs the PowerShell overrides it finds in a project's .AL-Go folder inside the build,
# so a request that edits them would otherwise change where and how the sandbox build deploys - or
# run code in it - before anyone reviewed it. That includes AL-Go's own update requests, which
# rewrite CICD.yaml, and the .AL-Go folder of every project in a multi-project repository.
#
# The 'in-sandbox' label is not touched here. Being assembled is not being deployed - the build of
# this branch can still fail - so the label follows the deployment: mark-sandbox-deployed.sh sets
# and clears it once CI/CD has really deployed.
#
# An assembly that comes back SMALLER is the costly case: the tables and fields of a request that
# left it leave the Sandbox with it. The Sandbox is deployed with "SyncMode": "ForceSync"
# (DeployToSandbox in AL-Go-Settings.json), which accepts that and deletes their data - the test
# data someone set up to verify that request. (Under AL-Go's default, Add, the deploy refuses the
# change instead, and every deploy after it fails until someone steps in.) A failed assembly costs
# nothing; a shrunken one costs data. Hence two guards:
#
#   * an assembly that includes no pull request at all, where the previous one did, refuses to push
#     and fails the run;
#   * a pull request that is in the sandbox and is not ready any more holds the whole assembly back:
#     nothing is pushed, and the sandbox keeps what it has. Whether that is worth a red run depends
#     on who has to act:
#       - waiting for a build - the check has not run, has not finished, or the head was not fetched
#         - is the everyday race. The run stays green and quiet, because the run that follows that
#         build reassembles on its own;
#       - waiting for a person - the build ended red, or the branch no longer merges cleanly - fails
#         the run and says so on the request. Nothing releases those on its own, so a green run would
#         leave the sandbox frozen with nobody told.
#
# So the only two ways a request leaves the sandbox are the deliberate ones: marking it draft, and
# closing it. Everything else waits. Both still shrink the assembly, and the request's tables and
# their data leave the Sandbox - but someone chose that. Without these guards, a request skipped for
# a conflict or a red build would be shipped without, and ForceSync would drop every table only that
# branch declares, and the test data in them, without a word to anyone.
#
# ASSEMBLE_FORCE=1 overrides all of it, for a hand-started run that means to shrink the sandbox.
# Its data goes with it (ForceSync), or the deploy fails on the removed fields (Add).
#
# The work happens in a temporary worktree, so the checkout of whoever runs this is never touched -
# which is also what makes --dry-run safe to run from a working copy with changes in it.
#
# Test hooks (used by test-assemble-sandbox.sh, not by the workflow):
#   ASSEMBLE_PR_LIST_FILE  read raw rows "number<TAB>branch<TAB>sha<TAB>isDraft<TAB>isCrossRepository
#                          <TAB>checkConclusion" from this file instead of gh; select_ready below
#                          decides readiness from them exactly as it would from a real gh run
#   ASSEMBLE_NO_NOTIFY=1   skip the comments

set -eu

DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        -h|--help) sed -n '2,63p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

REMOTE=origin
BASE=main
# Not plain `sandbox`: git cannot hold refs/heads/sandbox next to other refs/heads/sandbox/<name>
# branches (a dated assembly made by hand, for example) - a leaf inside that namespace conflicts with nothing.
TARGET=sandbox/current
CHECK="Pull Request Status Check"
# What decides where and how this branch is built and deployed. Always taken from main. The list
# itself is worked out after the merges (pipeline_paths below): the root .github, and every folder
# named .AL-Go, at any depth, in main or in the assembly.
PIPELINE_DESC=".github and every .AL-Go folder"
FORCE="${ASSEMBLE_FORCE:-0}"
ROOT="$(git rev-parse --show-toplevel)"
TAB="$(printf '\t')"

# Commits made here belong to the assembly, not to whoever happens to run it.
GITID="-c user.name=sandbox-assembler -c user.email=sandbox-assembler@users.noreply.github.com"

list_prs() {
    if [ -n "${ASSEMBLE_PR_LIST_FILE:-}" ]; then
        cat "$ASSEMBLE_PR_LIST_FILE"
        return
    fi
    # The built-in --jq of gh: Git Bash has no jq, and this has to run locally too. jq only
    # projects and sorts - select_ready below decides who is ready, so a test can exercise that
    # decision without gh. Every column is projected to a non-empty value on purpose; see the
    # `read` in select_ready.
    gh pr list --base "$BASE" --state open --limit 200 \
        --json number,headRefName,headRefOid,isDraft,isCrossRepository,statusCheckRollup \
        --jq 'sort_by(.number) | .[]
              | [ .number, .headRefName, .headRefOid, (.isDraft | tostring), (.isCrossRepository | tostring),
                  ( [ .statusCheckRollup[]? | select(.name == "'"$CHECK"'") | (.conclusion // "") ]
                    | if any(. == "SUCCESS") then "SUCCESS"
                      elif length == 0 then "NONE"
                      else (map(select(. != "")) | first // "PENDING") end ) ]
              | @tsv'
}

# Reads raw rows (number, branch, sha, isDraft, isCrossRepository, checkConclusion; TAB-separated)
# on stdin and writes one classified row per input row to stdout - nothing else, no state, no temp
# file, so a test can drive the decision directly:
#
#   READY<TAB>number<TAB>branch<TAB>sha
#   HARD<TAB>number<TAB>branch<TAB>sha<TAB>reason
#   SOFT<TAB>number<TAB>branch<TAB>sha<TAB>reason
#   SOFTRED<TAB>number<TAB>branch<TAB>sha<TAB>reason
#
# What separates the three rejections is what it costs to be wrong. HARD is a settled answer about
# where the work belongs - a draft, or a fork - and the request leaves the sandbox. SOFT and SOFTRED
# are both "not now": the caller keeps a newcomer out, but holds the whole assembly rather than evict
# a request that is already in the sandbox, because evicting it would take its tables, and their
# test data, out of the Sandbox (see the header). They differ only in who has to act before the hold
# lifts - a build for SOFT, a person for SOFTRED - and so in whether the run goes red and the request
# is told.
select_ready() {
    # Six columns, none of which may ever be empty: TAB is IFS whitespace, so two adjacent TABs
    # collapse into one and every later column shifts left. list_prs projects each field to a
    # non-empty value ("false", "NONE") precisely so that cannot happen.
    while IFS="$TAB" read -r num branch sha isdraft iscross conclusion; do
        [ -n "$num" ] || continue
        if [ "$isdraft" = "true" ]; then
            printf 'HARD\t%s\t%s\t%s\tdraft\n' "$num" "$branch" "$sha"
        elif [ "$iscross" = "true" ]; then
            printf 'HARD\t%s\t%s\t%s\tfrom a fork\n' "$num" "$branch" "$sha"
        elif [ "$conclusion" = "SUCCESS" ]; then
            printf 'READY\t%s\t%s\t%s\n' "$num" "$branch" "$sha"
        elif [ "$conclusion" = "NONE" ]; then
            printf 'SOFT\t%s\t%s\t%s\t%s has not run\n' "$num" "$branch" "$sha" "$CHECK"
        elif [ "$conclusion" = "PENDING" ]; then
            printf 'SOFT\t%s\t%s\t%s\t%s has not finished\n' "$num" "$branch" "$sha" "$CHECK"
        else
            # A red build could evict, and evicting is what costs the sandbox its tables (see the
            # header). It holds instead: a sandbox a few commits stale is worth less than the tables.
            printf 'SOFTRED\t%s\t%s\t%s\t%s is %s\n' "$num" "$branch" "$sha" "$CHECK" "$conclusion"
        fi
    done
}

# The pull-request numbers of the Included: section of the previous assembly - the Skipped: ones
# were never in the sandbox, so losing them loses nothing. Anything that is not a manifest commit
# (no sandbox branch yet, or someone pushed by hand) reads as empty, which leaves both guards
# below inactive: they may not be built on a message this script did not write.
prev_included() {
    body="$(git -C "$ROOT" log -1 --format=%B "$REMOTE/$TARGET" 2>/dev/null || true)"
    case "$body" in
        "$TARGET: assembled from"*) ;;
        *) return 0 ;;
    esac
    printf '%s\n' "$body" | awk '
        /^Included:/ { inc = 1; next }
        /^Skipped:/  { inc = 0; next }
        inc && $1 ~ /^#[0-9]+$/ { print substr($1, 2) }'
}

git -C "$ROOT" fetch "$REMOTE" --prune --quiet

WORK="$(mktemp -d)"
# Path lists that must not live inside the worktree, where they would end up in the assembly.
LISTS="$(mktemp -d)"
cleanup() {
    git -C "$ROOT" worktree remove --force "$WORK" >/dev/null 2>&1 || true
    rm -rf "$WORK" "$LISTS"
}
trap cleanup EXIT
git -C "$ROOT" worktree add --detach --quiet "$WORK" "$REMOTE/$BASE"

BASESHA="$(git -C "$WORK" rev-parse --short HEAD)"
echo "assembling $TARGET from $REMOTE/$BASE @ $BASESHA"

# Not piped: a pipe would hide a failing gh behind the exit code of tr, the list would come back
# empty, and an empty list assembles bare main - whose deploy would then fail on the fields of
# every pull request that was in the sandbox, and keep failing. No list, no assembly.
PRS="$(list_prs)" || { echo "could not list the pull requests - nothing assembled" >&2; exit 1; }
PRS="$(printf '%s' "$PRS" | tr -d '\r')"

# Readiness is decided here, in shell, not inside the jq query - so a test can drive it through
# ASSEMBLE_PR_LIST_FILE too, instead of trusting a jq expression no test ever runs. printf adds
# back the newline that $(...) stripped - a pipe without it drops select_ready's last row, since
# `read` fails (and its loop body is skipped) on a final line with no trailing newline.
CLASSIFIED="$(printf '%s\n' "$PRS" | select_ready)"

READY=""        # lines: number<TAB>branch<TAB>sha
SOFT=""         # lines: number<TAB>branch<TAB>sha<TAB>kind<TAB>reason - see the hold rule
while IFS="$TAB" read -r class num branch sha reason; do
    [ -n "$num" ] || continue
    if [ "$class" = "READY" ]; then
        READY="$READY$num$TAB$branch$TAB$sha
"
        continue
    fi
    echo "  #$num $branch: not ready - $reason" >&2
    # The kind travels with the row, so nothing downstream has to read a reason to know whether a
    # build will lift this hold or a person has to.
    case "$class" in
        SOFT)    kind=build ;;
        SOFTRED) kind=person ;;
        *)       continue ;;
    esac
    SOFT="$SOFT$num$TAB$branch$TAB$sha$TAB$kind$TAB$reason
"
done <<CLASSES
$CLASSIFIED
CLASSES

# The requests of the previous assembly, in the order it merged them.
PREV_INCLUDED="$(prev_included | tr '\n' ' ')"

# Merge order: what is in the sandbox already goes first, in the order it went in last time, and
# newcomers follow by number. Two requests that collide then always collide on the newcomer, which
# is simply left out - it has nothing in the sandbox to lose. Merged by number alone, a request that
# was a draft for weeks and is then made ready would go in ahead of one that is in the sandbox, and
# the conflict would land on the one that is in there: the whole assembly held for a request that
# never was in it. What is left that can hold the assembly is a request in the sandbox that no
# longer fits on main, or on another request in the sandbox that pushed since.
ORDERED=""
for num in $PREV_INCLUDED; do
    ORDERED="$ORDERED$(printf '%s' "$READY" | awk -F"$TAB" -v n="$num" '$1 == n { print; exit }')
"
done
ORDERED="$ORDERED$(printf '%s' "$READY" | awk -F"$TAB" -v prev=" $PREV_INCLUDED " 'NF && index(prev, " " $1 " ") == 0')
"

INCLUDED=""     # lines: number<TAB>branch<TAB>sha
SKIPPED=""      # lines: number<TAB>branch<TAB>sha<TAB>reason
MERGED_SO_FAR=""

while IFS="$TAB" read -r num branch sha; do
    [ -n "$num" ] || continue
    short="$(printf %.7s "$sha")"
    case "$branch" in
        "$TARGET")
            # The assembly is not a thing one opens a pull request from; merging it into itself
            # would fold a previous assembly into the next one and make the branch cumulative.
            echo "  #$num $branch @ $short: SKIPPED - $TARGET is the assembly itself, never an input"
            SKIPPED="$SKIPPED$num$TAB$branch$TAB$sha$TAB$TARGET is the assembly itself, never an input
"
            continue
            ;;
        sandbox/*)
            # Other sandbox/* branches (a dated assembly made by hand, for example) are assemblies
            # too, even though none of them is the target - merging one in would fold a whole other
            # assembly's history in.
            echo "  #$num $branch @ $short: SKIPPED - $branch is a sandbox assembly branch, never an input"
            SKIPPED="$SKIPPED$num$TAB$branch$TAB$sha$TAB$branch is a sandbox assembly branch, never an input
"
            continue
            ;;
    esac
    if ! git -C "$WORK" cat-file -e "$sha^{commit}" 2>/dev/null; then
        echo "  #$num $branch @ $short: SKIPPED - head commit was not fetched"
        SKIPPED="$SKIPPED$num$TAB$branch$TAB$sha${TAB}head commit was not fetched
"
        # Not a verdict on the request, only on this run's fetch - so it holds, like a build that
        # has not finished, rather than evicting.
        SOFT="$SOFT$num$TAB$branch$TAB$sha${TAB}build${TAB}head commit was not fetched
"
        continue
    fi
    # shellcheck disable=SC2086
    if git -C "$WORK" $GITID merge --no-ff --no-edit \
           -m "$TARGET: merge #$num $branch" "$sha" >/dev/null 2>&1; then
        echo "  #$num $branch @ $short: merged"
        INCLUDED="$INCLUDED$num$TAB$branch$TAB$sha
"
        MERGED_SO_FAR="$MERGED_SO_FAR #$num"
    else
        files="$(git -C "$WORK" diff --name-only --diff-filter=U | tr '\n' ' ' | sed 's/ $//')"
        # A merge that failed before it started leaves nothing to abort, and a failing abort here
        # must not take the whole assembly down with it.
        git -C "$WORK" merge --abort >/dev/null 2>&1 || true
        echo "  #$num $branch @ $short: SKIPPED - conflict in $files"
        SKIPPED="$SKIPPED$num$TAB$branch$TAB$sha${TAB}conflict with main plus$MERGED_SO_FAR in: $files
"
        # Held as well, for the same reason a build that has not finished is: evicting a request that
        # is in the sandbox takes its tables and their data out of the Sandbox. A
        # newcomer that conflicts has nothing in there to lose, and the hold rule below holds only
        # what the previous assembly included - so this line costs a newcomer nothing.
        SOFT="$SOFT$num$TAB$branch$TAB$sha${TAB}person${TAB}conflict with main plus$MERGED_SO_FAR in: $files
"
    fi
done <<LIST
$ORDERED
LIST

# Every pipeline path in the given trees, NUL-terminated: the root .github, and every path whose
# name has a part called .AL-Go - at any depth, the last part included (a symlink or a file by that
# name), and in ANY letter case. A Windows runner checks .al-go/ out into the same folder as .AL-Go/,
# so a request that adds Project/.al-go/NewBcContainer.ps1 would have AL-Go run it. The spelling the
# tree really uses is what is printed, so exactly that is removed.
#
# NUL-separated from ls-tree -z to git rm/checkout, never one path per line: git puts a name with a
# quote, a backslash or a control character in quotes when it prints one per line, and the quoted
# text names no path at all - the folder would quietly stay.
pipeline_paths() {  # <tree-ish>...
    local ref f rest comp prefix
    for ref in "$@"; do
        git -C "$WORK" ls-tree -r -z --name-only "$ref"
    done | while IFS= read -r -d '' f; do
        comp="${f%%/*}"
        if [ "${comp,,}" = ".github" ]; then
            printf '%s\0' "$comp"
            continue
        fi
        rest="$f"; prefix=""
        while [ -n "$rest" ]; do
            comp="${rest%%/*}"
            if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
            prefix="${prefix:+$prefix/}$comp"
            if [ "${comp,,}" = ".al-go" ]; then
                printf '%s\0' "$prefix"
                break
            fi
        done
    done | sort -zu
}

# Put the pipeline back to what main has: remove every pipeline path of the assembly, then check out
# main's. Removing first and checking out after restores it exactly: a plain checkout would bring
# back what a request changed or deleted, but leave the files it added. --literal-pathspecs, so a
# name that starts with ':' or holds a '*' is a name, not pathspec magic.
pipeline_paths HEAD > "$LISTS/remove"
pipeline_paths "$REMOTE/$BASE" > "$LISTS/restore"
if [ -s "$LISTS/remove" ]; then
    git -C "$WORK" --literal-pathspecs rm -r --quiet --ignore-unmatch \
        --pathspec-from-file="$LISTS/remove" --pathspec-file-nul >/dev/null
fi
if [ -s "$LISTS/restore" ]; then
    git -C "$WORK" --literal-pathspecs checkout --quiet "$REMOTE/$BASE" \
        --pathspec-from-file="$LISTS/restore" --pathspec-file-nul
fi
if ! git -C "$WORK" diff --cached --quiet; then
    echo "  pipeline files ($PIPELINE_DESC) taken from main - what pull requests change there does not reach the sandbox"
    # shellcheck disable=SC2086
    git -C "$WORK" $GITID commit --quiet -m "$TARGET: pipeline files taken from $BASE"
fi

# An empty commit, so the tree still compares cleanly against the previous assembly.
MANIFEST="$TARGET: assembled from $BASE @ $BASESHA

Included:
$(printf '%s' "$INCLUDED" | awk -F'\t' 'NF { printf "  #%s %s @ %.7s\n", $1, $2, $3 }')
Skipped:
$(printf '%s' "$SKIPPED" | awk -F'\t' 'NF { printf "  #%s %s @ %.7s - %s\n", $1, $2, $3, $4 }')"
# shellcheck disable=SC2086
git -C "$WORK" $GITID commit --quiet --allow-empty -m "$MANIFEST"

NEWTREE="$(git -C "$WORK" rev-parse 'HEAD^{tree}')"
OLDTREE="$(git -C "$ROOT" rev-parse --verify --quiet "$REMOTE/$TARGET^{tree}" || true)"
SAME=0
[ "$NEWTREE" = "$OLDTREE" ] && SAME=1

# shellcheck disable=SC2086
set -- $PREV_INCLUDED
PREV_COUNT=$#

# Which of the "not yet" rejections would evict a pull request that is in the sandbox right now.
HELD=""
# Red only for a hold that waits for a person. A build that has not finished is followed by the run
# that reassembles, and failing on that would paint the everyday race red.
HOLD_IS_RED=0
if [ "$FORCE" != "1" ] && [ "$PREV_COUNT" -gt 0 ]; then
    while IFS="$TAB" read -r num branch sha kind reason; do
        [ -n "$num" ] || continue
        case " $PREV_INCLUDED " in
            *" $num "*)
                HELD="$HELD$num$TAB$sha$TAB$kind$TAB$reason
"
                if [ "$kind" = person ]; then HOLD_IS_RED=1; fi
                ;;
        esac
    done <<HOLDS
$SOFT
HOLDS
fi

REFUSE=0
if [ "$FORCE" != "1" ] && [ -z "$INCLUDED" ] && [ "$PREV_COUNT" -gt 0 ]; then
    REFUSE=1
fi

say_holds() {  # <prefix>
    printf '%s' "$HELD" | while IFS="$TAB" read -r num sha kind reason; do
        [ -n "$num" ] || continue
        if [ "$kind" = person ]; then
            next="fix it in that branch - nothing is ever resolved in the sandbox - and the next assembly picks it up"
        else
            next="the run that follows its build will reassemble"
        fi
        echo "$1holding: #$num was in the previous assembly and $reason - not pushing; $next (run Assemble Sandbox by hand with force to push anyway, or mark the request as draft)"
    done
}
REFUSAL="previous assembly had $PREV_COUNT pull requests, this one has none - refusing to push (run Assemble Sandbox by hand with force if this is intended)"

if [ "$DRY" -eq 1 ]; then
    if [ "$SAME" -eq 1 ]; then
        echo "(dry run - identical to $REMOTE/$TARGET, nothing to push)"
    elif [ -n "$HELD" ]; then
        say_holds "(dry run) would be "
    elif [ "$REFUSE" -eq 1 ]; then
        echo "(dry run) would be $REFUSAL"
    else
        echo "(dry run - differs from $REMOTE/$TARGET, would push)"
    fi
    exit 0
fi

EXITCODE=0
if [ "$SAME" -eq 1 ]; then
    # Evaluated after the tree comparison on purpose: the everyday way to end with no pull request
    # is that the last one was squash-merged into main, and then the assembly is main, unchanged.
    # Nothing is lost, nothing is pushed, and there is nothing to refuse.
    echo "identical to $REMOTE/$TARGET - nothing to build, not pushing"
else
    if [ -n "$HELD" ]; then
        say_holds ""
        EXITCODE="$HOLD_IS_RED"
    elif [ "$REFUSE" -eq 1 ]; then
        echo "$REFUSAL" >&2
        exit 1
    else
        # Fully qualified refspec: the destination cannot resolve to any branch but the sandbox.
        git -C "$WORK" push --force --quiet "$REMOTE" "HEAD:refs/heads/$TARGET"
        echo "pushed $TARGET @ $(git -C "$WORK" rev-parse --short HEAD)"
    fi
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo '```'; echo "$MANIFEST"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi

[ "${ASSEMBLE_NO_NOTIFY:-0}" = "1" ] && exit "$EXITCODE"
command -v gh >/dev/null 2>&1 || exit "$EXITCODE"

# Nothing below may fail the run: the branch is already pushed and usable, and an expired token
# must not turn a good assembly into a red one. Every gh call reads /dev/null, because the loop
# has its own stdin and a command that reads it would swallow the rest of the list.

# A hidden marker carries the SHA, so a re-run over the same commit adds no second comment.
comment_once() {  # <pr> <marker> <body>
    if gh pr view "$1" --json comments --jq '.comments[].body' </dev/null 2>/dev/null | grep -qF "$2"; then
        return 0
    fi
    printf '%s\n\n<!-- %s -->\n' "$3" "$2" | gh pr comment "$1" --body-file - >/dev/null 2>&1 || true
}

# The requests the hold is for. They are in SKIPPED as well - this assembly did leave them out - but
# nothing was pushed, so telling them they were left out of the sandbox says the opposite of what
# happened to their data.
HELD_NUMS=" $(printf '%s' "$HELD" | awk -F"$TAB" 'NF { printf "%s ", $1 }')"

printf '%s' "$HELD" | while IFS="$TAB" read -r num sha kind reason; do
    [ -n "$num" ] || continue
    # Only the holds that wait for a person. A build that has not finished is an everyday race, and
    # a comment for it would be noise on every request that is still building.
    [ "$kind" = person ] || continue
    short="$(printf %.7s "$sha")"
    comment_once "$num" "sandbox-held:$sha:$(printf '%s' "${reason##*in: }" | cksum | cut -d' ' -f1)" \
        "The \`$TARGET\` assembly is on hold at \`$short\`: $reason. Nothing was pushed, so what this request already has in the sandbox is still there - leaving it out would take its tables, and the test data in them, out of the Sandbox. Resolve it in this branch - nothing is ever resolved in the sandbox - and the next assembly picks it up."
done

# A request that went in hears about it from mark-sandbox-deployed.sh, once it is deployed. A
# request that was left out hears now: that is known at this point, and no deployment will say it.
printf '%s' "$SKIPPED" | while IFS="$TAB" read -r num branch sha reason; do
    [ -n "$num" ] || continue
    case "$HELD_NUMS" in *" $num "*) continue ;; esac
    short="$(printf %.7s "$sha")"
    # Only the conflicting files are hashed, not the whole reason: the reason also names the
    # requests merged before this one, and that changes whenever an unrelated request comes or
    # goes - which would post the same news again every time.
    comment_once "$num" "sandbox-skipped:$sha:$(printf '%s' "${reason##*in: }" | cksum | cut -d' ' -f1)" \
        "Left out of \`$TARGET\` at \`$short\`: $reason. Resolve it in this branch - nothing is ever resolved in the sandbox - and the next assembly picks it up."
done

exit "$EXITCODE"
