#!/usr/bin/env bash
#
# Exercises mark-sandbox-deployed.sh against a throwaway repository and a stub `gh` first on PATH.
# No network. The stub records every call and answers the three queries the script makes from
# files the test writes beforehand.
#
#   .github/scripts/test-mark-sandbox-deployed.sh

set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/mark-sandbox-deployed.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
FAILS=0

check() {  # <description> <command...> - the command must succeed
    desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok    $desc"; else echo "  FAIL  $desc"; FAILS=$((FAILS + 1)); fi
}
refute() {  # <description> <command...> - the command must fail
    desc="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  FAIL  $desc"; FAILS=$((FAILS + 1)); else echo "  ok    $desc"; fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init --quiet --initial-branch=main "$T/repo"
cd "$T/repo"
echo base > base.txt
git add . && git commit --quiet -m base

# Two assemblies, written the way assemble-sandbox.sh writes them: an empty commit whose message
# is the manifest.
git commit --quiet --allow-empty -m "sandbox/current: assembled from main @ 1111111

Included:
  #1 feature/one @ aaaaaaa
  #2 fix/two#2 @ bbbbbbb
Skipped:
  #4 feature/four @ ddddddd - conflict with main plus #1 #2 in: base.txt"
WITH_TWO="$(git rev-parse HEAD)"

git commit --quiet --allow-empty -m "sandbox/current: assembled from main @ 1111111

Included:
Skipped:"
WITH_NONE="$(git rev-parse HEAD)"

git commit --quiet --allow-empty -m "an ordinary commit, not a manifest"
NOT_A_MANIFEST="$(git rev-parse HEAD)"

# The stub gh. Answers come from files so each case can set them up:
#   $GH_JOBS      what `gh run view --json jobs` prints (one "name<TAB>conclusion" per line)
#   $GH_LABELLED  what `gh pr list --label in-sandbox` prints (one number per line)
#   $GH_COMMENTS  what `gh pr view N --json comments` prints
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
{
    printf 'gh'
    for a in "$@"; do printf ' %s' "$a"; done
    printf '\n'
} >> "$GH_LOG"
case "$1 $2" in
    "run view") cat "$GH_JOBS" ;;
    "pr list")  cat "$GH_LABELLED" ;;
    "pr view")  cat "$GH_COMMENTS" ;;
esac
for a in "$@"; do
    [ "$a" = "--body-file" ] || continue
    sed 's/^/body: /' >> "$GH_LOG"
    break
done
exit 0
STUB
chmod +x "$T/bin/gh"

export GH_JOBS="$T/jobs.txt" GH_LABELLED="$T/labelled.txt" GH_COMMENTS="$T/comments.txt"
deployed() { printf 'Initialization\tsuccess\nDeploy to Sandbox\t%s\n' "$1" > "$GH_JOBS"; }
run() {  # <log file> <sha>
    : > "$1"
    GH_LOG="$1" PATH="$T/bin:$PATH" DEPLOYED_SHA="$2" RUN_ID=77 \
        RUN_URL="https://example.test/runs/77" bash "$SCRIPT" > "$T/out.txt" 2>&1
}
logged() { grep -qF -- "$2" "$1"; }

echo "1. a successful deployment labels exactly what the manifest includes"
deployed success; printf '2\n9\n' > "$GH_LABELLED"; : > "$GH_COMMENTS"
check  "the run succeeds"                          run "$T/1.log" "$WITH_TWO"
check  "#1 gets the label"                         logged "$T/1.log" "gh pr edit 1 --add-label in-sandbox"
check  "#2 gets the label"                         logged "$T/1.log" "gh pr edit 2 --add-label in-sandbox"
check  "#1 is told which commit was deployed"      logged "$T/1.log" "sandbox-deployed:aaaaaaa"
check  "and is given the run"                      logged "$T/1.log" "https://example.test/runs/77"
check  "#9 carried the label but is not deployed - it comes off" \
                                                   logged "$T/1.log" "gh pr edit 9 --remove-label in-sandbox"
refute "#2 is deployed - its label stays"          logged "$T/1.log" "gh pr edit 2 --remove-label"
refute "a skipped request is not labelled"         logged "$T/1.log" "gh pr edit 4 --add-label"
refute "the #2 inside a branch name is not a request" logged "$T/1.log" "gh pr edit 22"

echo "2. the same commit deployed again is not announced twice"
printf 'earlier text <!-- sandbox-deployed:aaaaaaa -->\n' > "$GH_COMMENTS"
check  "the run succeeds"                          run "$T/2.log" "$WITH_TWO"
check  "the label is still asserted"               logged "$T/2.log" "gh pr edit 1 --add-label in-sandbox"
refute "but #1 gets no second comment"             logged "$T/2.log" "gh pr comment 1"
: > "$GH_COMMENTS"

echo "3. a run whose deploy job did not succeed changes nothing"
for outcome in failure skipped cancelled; do
    deployed "$outcome"
    check  "($outcome) the run itself succeeds"    run "$T/3.log" "$WITH_TWO"
    refute "($outcome) no label is added"          logged "$T/3.log" "--add-label"
    refute "($outcome) no label is removed"        logged "$T/3.log" "--remove-label"
    refute "($outcome) nothing is posted"          logged "$T/3.log" "gh pr comment"
done
printf 'Initialization\tsuccess\n' > "$GH_JOBS"
check  "(no deploy job at all) the run succeeds"   run "$T/3.log" "$WITH_TWO"
refute "(no deploy job at all) no label is added"  logged "$T/3.log" "--add-label"
check  "and it says why"                           grep -q "Deploy to Sandbox" "$T/out.txt"

echo "4. an assembly with no pull requests takes every label off"
deployed success; printf '1\n2\n' > "$GH_LABELLED"
check  "the run succeeds"                          run "$T/4.log" "$WITH_NONE"
check  "#1 loses the label"                        logged "$T/4.log" "gh pr edit 1 --remove-label in-sandbox"
check  "#2 loses the label"                        logged "$T/4.log" "gh pr edit 2 --remove-label in-sandbox"
refute "nothing is added"                          logged "$T/4.log" "--add-label"

echo "5. a commit that is not a manifest changes nothing"
deployed success; printf '1\n' > "$GH_LABELLED"
check  "the run succeeds"                          run "$T/5.log" "$NOT_A_MANIFEST"
refute "no label is removed"                       logged "$T/5.log" "--remove-label"
refute "no label is added"                         logged "$T/5.log" "--add-label"

echo "6. a commit that cannot be found changes nothing"
check  "the run succeeds"                          run "$T/6.log" "0000000000000000000000000000000000000001"
refute "no label is touched"                       logged "$T/6.log" "gh pr edit"

echo "7. the workflow is told whether a manifest was really deployed"
deployed success; : > "$GH_LABELLED"
: > "$T/ghout.txt"
GITHUB_OUTPUT="$T/ghout.txt" run "$T/7.log" "$WITH_TWO"
check  "a deployed manifest sets deployed=true"    grep -qx "deployed=true" "$T/ghout.txt"
deployed failure
: > "$T/ghout.txt"
GITHUB_OUTPUT="$T/ghout.txt" run "$T/7.log" "$WITH_TWO"
refute "a failed deploy job does not"              grep -q "deployed" "$T/ghout.txt"
deployed success
: > "$T/ghout.txt"
GITHUB_OUTPUT="$T/ghout.txt" run "$T/7.log" "$NOT_A_MANIFEST"
refute "a commit that is not a manifest does not"  grep -q "deployed" "$T/ghout.txt"

echo
if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
