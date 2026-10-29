#!/usr/bin/env bash
#
# Exercises assemble-sandbox.sh against a throwaway repository: a bare "origin", a clone, and a few
# branches standing in for pull requests. No network and no gh - the pull request list comes from a
# file through ASSEMBLE_PR_LIST_FILE, and the one case that covers the labels and comments puts a
# stub `gh` first on PATH.
#
#   .github/scripts/test-assemble-sandbox.sh
#
# The cases run in order and inherit each other's sandbox, because the previous assembly is itself
# an input now: the shrink guard and the hold rule both read the manifest the last run pushed.

set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/assemble-sandbox.sh"
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

git init --quiet --bare --initial-branch=main "$T/origin.git"
git clone --quiet "$T/origin.git" "$T/clone" 2>/dev/null
cd "$T/clone"
git checkout --quiet -b main
echo "base" > base.txt
# The pipeline as main has it. Case 18 proves an assembly never carries anything else.
mkdir -p .github/workflows .AL-Go
echo "the pipeline on main" > .github/workflows/ci.yaml
echo "the settings on main" > .AL-Go/settings.json
git add . && git commit --quiet -m base && git push --quiet origin main

branch() {  # <name> <file> <content> - a branch off main that changes one file
    git checkout --quiet -b "$1" main
    echo "$3" > "$2"
    git add . && git commit --quiet -m "$1" && git push --quiet origin "$1"
    git checkout --quiet main
}
branch pr1 a.txt "from pr1"
branch pr2 b.txt "from pr2"
branch pr3 base.txt "pr3 rewrites base"
branch pr4 base.txt "pr4 rewrites base differently"

# A dated sandbox assembly already in the remote, the way one made by hand would be - proving the
# point of the name sandbox/current: pushing plain `sandbox` here would hit a refname conflict.
branch sandbox/2026-09-18 dated.txt "a dated sandbox assembly, not a pull request"
DATEDSHA="$(git rev-parse origin/sandbox/2026-09-18)"

# A stub gh: it records the call and says nothing back, so comment_once always finds the request
# uncommented and the notify stage runs in full.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
{
    printf 'gh'
    for a in "$@"; do printf ' %s' "$a"; done
    printf '\n'
} >> "$GH_LOG"
for a in "$@"; do
    [ "$a" = "--body-file" ] || continue
    sed 's/^/body: /' >> "$GH_LOG"
    break
done
exit 0
STUB
chmod +x "$T/bin/gh"

line()     { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(git rev-parse "origin/$2")" "${3:-false}" "${4:-false}" "${5:-SUCCESS}"; }
run()      { ASSEMBLE_PR_LIST_FILE="$T/prs.tsv" ASSEMBLE_NO_NOTIFY=1 bash "$SCRIPT" "$@" > "$T/out.txt" 2>&1; }
force()    { ASSEMBLE_FORCE=1 ASSEMBLE_PR_LIST_FILE="$T/prs.tsv" ASSEMBLE_NO_NOTIFY=1 bash "$SCRIPT" "$@" > "$T/out.txt" 2>&1; }
notify()   { GH_LOG="$1" PATH="$T/bin:$PATH" ASSEMBLE_PR_LIST_FILE="$T/prs.tsv" bash "$SCRIPT" > "$T/out.txt" 2>&1; }
sandbox()  { git fetch --quiet origin; git rev-parse origin/sandbox/current; }
has()      { git fetch --quiet origin; git ls-tree -r --name-only origin/sandbox/current | grep -qx "$1"; }
content()  { git fetch --quiet origin; git cat-file -p "$(git ls-tree origin/sandbox/current -- "$1" | awk '{print $3}')"; }
manifest() { git fetch --quiet origin; git log -1 --format=%B origin/sandbox/current | grep -q "$1"; }
contentis() { content "$1" | grep -q "$2"; }
dated()    { git fetch --quiet origin; git rev-parse origin/sandbox/2026-09-18; }
tree_of()  { git fetch --quiet origin; git rev-parse "origin/$1^{tree}"; }
said()     { grep -q "$1" "$T/out.txt"; }
logged()   { grep -qF -- "$2" "$1"; }
marker()   { grep -o 'sandbox-skipped:[^ ]*' "$1" | head -1; }
heldmarker() { grep -o 'sandbox-held:[^ ]*' "$1" | head -1; }

echo "1. two clean pull requests are both assembled"
{ line 1 pr1; line 2 pr2; } > "$T/prs.tsv"
check  "the run succeeds despite the dated sandbox/2026-09-18 already in the remote" run
check  "sandbox has the file from pr1"        has a.txt
check  "sandbox has the file from pr2"        has b.txt
check  "manifest names #1"                    manifest '#1 pr1'
check  "manifest names #2"                    manifest '#2 pr2'
check  "the pre-existing dated sandbox branch is untouched"  test "$DATEDSHA" = "$(dated)"

echo "2. a conflicting pull request is skipped, the rest still go in"
{ line 1 pr1; line 3 pr3; line 4 pr4; } > "$T/prs.tsv"
check  "the run still succeeds"               run
check  "pr1 is in"                            has a.txt
check  "pr3 won base.txt (lower number)"      contentis base.txt 'pr3 rewrites base'
check  "manifest lists #4 as skipped"         manifest '#4 pr4 .* conflict .* base.txt'
check  "the conflict names what came before"  manifest 'main plus #1 #3'

echo "3. a pull request that left the list leaves the sandbox"
refute "the file from pr2 is gone"            has b.txt

echo "4. an identical assembly is not pushed again"
before="$(sandbox)"
check  "the run succeeds"                     run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and says so"                          said "nothing to build"

echo "5. --dry-run pushes nothing"
{ line 1 pr1; line 2 pr2; } > "$T/prs.tsv"
before="$(sandbox)"
check  "the run succeeds"                     run --dry-run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and reports it would push"            said "would push"

echo "6. the checkout it is run from is never touched"
echo "local edit" >> base.txt
headbefore="$(git rev-parse HEAD)"
check  "the run succeeds with a dirty tree"   run
check  "HEAD did not move"                    test "$headbefore" = "$(git rev-parse HEAD)"
check  "the local edit is still there"        grep -q "local edit" base.txt
check  "no worktree is left behind"           test "$(git worktree list | wc -l)" -eq 1

echo "7. an unknown head commit is skipped, not fatal"
{ line 1 pr1; printf '9\tghost\t%s\tfalse\tfalse\tSUCCESS\n' "0000000000000000000000000000000000000001"; } > "$T/prs.tsv"
check  "the run succeeds"                     run
check  "manifest says why"                    manifest '#9 ghost .* not fetched'
check  "the readable one is still in"         has a.txt

echo "8. a pull request list that cannot be read stops the run"
{ line 1 pr1; } > "$T/prs.tsv"
run
before="$(sandbox)"
mv "$T/prs.tsv" "$T/prs.gone"
refute "the run fails"                        run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and says why"                         said "could not list"
mv "$T/prs.gone" "$T/prs.tsv"

echo "9. only ready pull requests are assembled"
branch pr5 e.txt "from pr5"
branch pr6 f.txt "from pr6"
branch pr7 g.txt "from pr7"
{
    line 1 pr1
    line 2 pr2 true  false SUCCESS
    line 5 pr5 false true  SUCCESS
    line 6 pr6 false false FAILURE
    line 7 pr7 false false NONE
} > "$T/prs.tsv"
check  "the run succeeds"                     run
check  "the ready one is in"                  has a.txt
refute "the draft is not in"                  has b.txt
refute "the fork is not in"                   has e.txt
refute "the red check is not in"              has f.txt
refute "the missing check is not in"          has g.txt
check  "manifest names the ready one"         manifest '#1 pr1'
refute "manifest never names the draft"       manifest '#2'
refute "manifest never names the fork"        manifest '#5'
refute "manifest never names the red check"   manifest '#6'
refute "manifest never names the missing check" manifest '#7'
check  "log explains the draft"               said 'draft'
check  "log explains the fork"                said 'fork'
check  "log explains the red check"           said 'FAILURE'
check  "log explains the missing check"       said 'has not run'

echo "10. no ready pull requests assembles plain main"
# With no sandbox to compare against, an empty list loses nothing and is simply the truth.
git push --quiet origin --delete sandbox/current
: > "$T/prs.tsv"
check  "the run succeeds"                     run
check  "sandbox tree equals main's tree"      test "$(tree_of sandbox/current)" = "$(tree_of main)"
refute "no pull request is named in the manifest" manifest '#[0-9]'

echo "11. an assembly that would drop every pull request refuses to push"
{ line 1 pr1; } > "$T/prs.tsv"
run
: > "$T/prs.tsv"
before="$(sandbox)"
refute "the run fails"                        run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and says it is refusing"              said "refusing to push"
check  "with force it succeeds"               force
check  "and the sandbox is plain main"        test "$(tree_of sandbox/current)" = "$(tree_of main)"

echo "12. a pull request whose build has not finished holds the assembly"
{ line 1 pr1; } > "$T/prs.tsv"
run
{ line 1 pr1 false false PENDING; line 2 pr2; } > "$T/prs.tsv"
before="$(sandbox)"
check  "the run succeeds"                     run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and says it is holding #1"            said "holding: #1"
refute "the ready newcomer waits too"         has b.txt
{ line 1 pr1 false false NONE; line 2 pr2; } > "$T/prs.tsv"
check  "a check that never ran holds as well" run
check  "sandbox still did not move"           test "$before" = "$(sandbox)"
check  "and says it is holding #1"            said "holding: #1"
check  "with force it pushes"                 force
refute "the held request is evicted"          has a.txt
check  "and the newcomer is in"               has b.txt

echo "13. an unfinished newcomer is left out without holding anything"
{ line 1 pr1 false false PENDING; line 2 pr2; line 5 pr5; } > "$T/prs.tsv"
check  "the run succeeds"                     run
refute "nothing is held"                      said "holding"
check  "the ready ones are in"                has b.txt
check  "and the second one too"               has e.txt
refute "the unfinished newcomer is not in"    has a.txt

echo "14. a red build holds a pull request that was in the sandbox, it is not evicted"
{ line 2 pr2; line 5 pr5 false false FAILURE; } > "$T/prs.tsv"
before="$(sandbox)"
refute "the run fails"                        run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and says it is holding #5"            said "holding: #5"
check  "the red one keeps what it had there"  has e.txt
check  "and so does the green one"            has b.txt

echo "15. a pull request from the target branch, or a dated sandbox branch, is never merged"
{
    line 2 pr2
    printf '3\tsandbox/current\t%s\tfalse\tfalse\tSUCCESS\n' "$(git rev-parse origin/pr1)"
    line 8 sandbox/2026-09-18
} > "$T/prs.tsv"
check  "the run succeeds"                     run
check  "and says why the target branch was left out"      said '#3 sandbox/current .* SKIPPED'
check  "and says why the dated branch was left out"       said '#8 sandbox/2026-09-18 .* SKIPPED'
refute "the target branch's content did not reach the sandbox" has a.txt
refute "the dated branch's content did not reach the sandbox"  has dated.txt

echo "16. an empty list is fine when main absorbed the last pull request"
git merge --quiet --no-ff --no-edit origin/pr2
git push --quiet origin main
: > "$T/prs.tsv"
before="$(sandbox)"
check  "the run succeeds"                     run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and says there is nothing to build"   said "nothing to build"
refute "and does not refuse"                  said "refusing to push"

echo "17. comments - and no labels: the label follows the deployment, not the assembly"
{ line 1 pr1; line 3 pr3; line 4 pr4; line 6 pr6 false false FAILURE; } > "$T/prs.tsv"
check  "the run succeeds"                     notify "$T/ghA.log"
check  "a conflicting request is told why"    logged "$T/ghA.log" "sandbox-skipped:"
check  "and the comment goes to that request" logged "$T/ghA.log" "gh pr comment 4"
refute "an included request is told nothing yet" logged "$T/ghA.log" "gh pr comment 1"
refute "a red request is told nothing"        logged "$T/ghA.log" "gh pr comment 6"
refute "no label is added by an assembly"     logged "$T/ghA.log" "--add-label"
refute "no label is removed by an assembly"   logged "$T/ghA.log" "--remove-label"
refute "and none is created"                  logged "$T/ghA.log" "gh label"
{ line 3 pr3; line 4 pr4; } > "$T/prs.tsv"
check  "a second assembly succeeds"           notify "$T/ghB.log"
check  "the conflict marker ignores who else was merged" \
                                              test "$(marker "$T/ghA.log")" = "$(marker "$T/ghB.log")"

echo "18. the pipeline in an assembly is always the one on main"
# pr8 changes the app and, in the same request, every kind of pipeline change there is: a settings
# edit, a new workflow, and a workflow deleted.
git checkout --quiet -b pr8 main
echo "from pr8" > c.txt
echo "settings a pull request would like" > .AL-Go/settings.json
echo "a workflow nobody reviewed" > .github/workflows/unreviewed.yaml
git rm --quiet .github/workflows/ci.yaml
git add . && git commit --quiet -m pr8 && git push --quiet origin pr8
git checkout --quiet main
{ line 8 pr8; } > "$T/prs.tsv"
check  "the run succeeds"                     run
check  "the app change from pr8 is in"        has c.txt
check  "the settings are the ones on main"    contentis .AL-Go/settings.json 'the settings on main'
check  "the workflow pr8 deleted is still there" contentis .github/workflows/ci.yaml 'the pipeline on main'
refute "the workflow pr8 added is not"        has .github/workflows/unreviewed.yaml
check  "and the run says so"                  said "taken from main"
check  "the manifest is still the tip"        manifest '#8 pr8'

echo "19. a request that only touches the pipeline changes nothing in the sandbox"
git checkout --quiet -b pr9 main
echo "another unreviewed workflow" > .github/workflows/other.yaml
git add . && git commit --quiet -m pr9 && git push --quiet origin pr9
git checkout --quiet main
{ line 8 pr8; line 9 pr9; } > "$T/prs.tsv"
before="$(sandbox)"
check  "the run succeeds"                     run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "there is nothing to build"            said "nothing to build"

echo "20. a newcomer that collides with a request in the sandbox is left out, nothing is held"
# Merge order puts what is in the sandbox first. #3 has the lower number but was not in the sandbox,
# so it is #3 that does not fit - not #4, which is. Merged by number, #4 would conflict, and the
# whole assembly would be held for a request that never was in it.
{ line 4 pr4; } > "$T/prs.tsv"
check  "the sandbox starts with #4 in it"     run
check  "#4 rewrote base.txt"                  contentis base.txt 'pr4 rewrites base differently'
{ line 3 pr3; line 4 pr4; } > "$T/prs.tsv"
before="$(sandbox)"
check  "the run succeeds"                     run
refute "nothing is held"                      said "holding"
check  "#3 is the one left out"               said '#3 pr3 .* SKIPPED - conflict'
check  "#4 still merges"                      said '#4 pr4 .* merged'
check  "#4's change is still in the sandbox"  contentis base.txt 'pr4 rewrites base differently'
check  "and the sandbox did not move, it is the same tree" test "$before" = "$(sandbox)"

echo "21. a request in the sandbox that no longer fits on main holds, and is told so"
# The one conflict that can still hold the assembly: main moved under a request that is in there.
git checkout --quiet main
echo "main rewrites base" > base.txt
git commit --quiet -am "main rewrites base" && git push --quiet origin main
{ line 4 pr4; } > "$T/prs.tsv"
before="$(sandbox)"
refute "the run fails, so nothing sits green and idle" run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and says it is holding #4"            said "holding: #4"
check  "and that the conflict is with main itself" said "conflict with main plus in"
check  "and says where to fix it"             said "fix it in that branch"
refute "the notifying run fails too"          notify "$T/ghC.log"
check  "#4 hears about the hold"              logged "$T/ghC.log" "gh pr comment 4"
check  "and the comment says the sandbox waits" logged "$T/ghC.log" "body: The \`sandbox/current\` assembly is on hold"
refute "and never says it was left out"       logged "$T/ghC.log" "Left out of"
refute "a second run over the same head also fails" notify "$T/ghD.log"
check  "the marker is the same, so it is posted once" test "$(heldmarker "$T/ghC.log")" = "$(heldmarker "$T/ghD.log")"
check  "with force it pushes anyway"          force
refute "and #4 is evicted"                    contentis base.txt 'pr4 rewrites base differently'
# Put main back, so the cases below start from a main every request still fits on.
echo "base" > base.txt
git commit --quiet -am "main puts base back" && git push --quiet origin main

echo "22. a conflicting newcomer is still skipped, and the assembly still ships"
{ line 1 pr1; } > "$T/prs.tsv"
check  "a sandbox with only #1 in it"         run
{ line 1 pr1; line 3 pr3; line 4 pr4; } > "$T/prs.tsv"
check  "the run succeeds"                     run
refute "nothing is held"                      said "holding"
check  "#3 is in"                             contentis base.txt 'pr3 rewrites base'
check  "and the manifest says #4 conflicted"  manifest '#4 pr4 .* conflict'

echo "23. a hold that waits for a build says nothing to anyone"
# The everyday race: a request in the sandbox pushes, its build starts, an assembly runs in between.
# It holds - that much is case 12 - and it must do so quietly, or every push comments on itself.
{ line 1 pr1; } > "$T/prs.tsv"
check  "a sandbox with #1 in it"              run
{ line 1 pr1 false false PENDING; } > "$T/prs.tsv"
check  "the run holds and stays green"        notify "$T/ghE.log"
check  "and says it is holding #1"            said "holding: #1"
refute "and tells the request nothing"        logged "$T/ghE.log" "gh pr comment 1"

echo "24. a red build holds what it has in the sandbox, and says so out loud"
{ line 1 pr1; line 2 pr2; } > "$T/prs.tsv"
check  "a sandbox with #1 and #2 in it"       run
{ line 1 pr1 false false FAILURE; line 2 pr2; } > "$T/prs.tsv"
before="$(sandbox)"
refute "the run fails, like a conflict does"  run
check  "sandbox did not move"                 test "$before" = "$(sandbox)"
check  "and says it is holding #1"            said "holding: #1"
check  "and names the red check"              said "FAILURE"
check  "#1 keeps what it had in the sandbox"  has a.txt
refute "the notifying run fails too"          notify "$T/ghF.log"
check  "#1 hears that the assembly waits"     logged "$T/ghF.log" "gh pr comment 1"
refute "and is not told it was left out"      logged "$T/ghF.log" "Left out of"
check  "with force it is evicted after all"   force
refute "and #1 is gone"                       has a.txt

echo "25. draft and abandon still evict, whatever the request has in the sandbox"
# The two deliberate ways out. Everything else waits, so these have to keep working.
{ line 1 pr1; line 2 pr2; } > "$T/prs.tsv"
check  "a sandbox with both in it"            run
check  "#1 is in"                             has a.txt
{ line 1 pr1 true false SUCCESS; line 2 pr2; } > "$T/prs.tsv"
check  "marking it draft keeps the run green" run
refute "and evicts it"                        has a.txt
check  "#2 is untouched"                      has b.txt
{ line 2 pr2; } > "$T/prs.tsv"
before="$(sandbox)"
check  "a closed request just leaves the list" run
check  "#2 is still there"                    has b.txt

echo "26. every project's .AL-Go folder is the one on main, at any depth"
# A multi-project repository: each project has its own .AL-Go, and AL-Go runs the PowerShell
# overrides it finds there inside the build. One project name has a space in it.
git checkout --quiet main
mkdir -p "Core/.AL-Go" "Group/My Edi/.AL-Go"
echo "core settings on main" > "Core/.AL-Go/settings.json"
echo "edi settings on main" > "Group/My Edi/.AL-Go/settings.json"
git add . && git commit --quiet -m "projects" && git push --quiet origin main
git checkout --quiet -b pr10 main
echo "from pr10" > d.txt
echo "settings a pull request would like" > "Core/.AL-Go/settings.json"
echo "Write-Host 'code nobody reviewed'" > "Group/My Edi/.AL-Go/NewBcContainer.ps1"
mkdir -p "New/.AL-Go" && echo "a project main does not have" > "New/.AL-Go/settings.json"
git add . && git commit --quiet -m pr10 && git push --quiet origin pr10
git checkout --quiet main
{ line 10 pr10; } > "$T/prs.tsv"
check  "the run succeeds"                     run
check  "the app change from pr10 is in"       has d.txt
check  "a project's settings are the ones on main" contentis "Core/.AL-Go/settings.json" 'core settings on main'
refute "an override script added to a project is not" has "Group/My Edi/.AL-Go/NewBcContainer.ps1"
check  "the project with a space keeps main's settings" contentis "Group/My Edi/.AL-Go/settings.json" 'edi settings on main'
refute "a .AL-Go folder only the request has is not" has "New/.AL-Go/settings.json"
check  "and the run says so"                  said "taken from main"

echo
if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
