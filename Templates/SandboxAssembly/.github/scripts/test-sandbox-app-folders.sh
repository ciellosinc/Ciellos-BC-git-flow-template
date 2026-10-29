#!/usr/bin/env bash
#
# Exercises sandbox-app-folders.py against a throwaway repository. No network.
#
#   .github/scripts/test-sandbox-app-folders.sh

set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/sandbox-app-folders.py"
PY="$(command -v python3 || command -v python)"
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
# A Windows machine with core.autocrlf=true would warn on every commit below.
git config core.autocrlf false

put()     { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }
app()     { put "$1/app.json" '{"id":"x"}'; put "$1/src/Code.al" 'codeunit 50100 X {}'; }
commit()  { git add -A && git commit --quiet -m "$1" && git rev-parse HEAD; }
folders() { "$PY" "$SCRIPT" "$@" > "$T/out.txt"; }
listed()  { grep -qx "$1" "$T/out.txt"; }
shipped() { printf '%s\n' "$@" > "$T/files.txt"; "$PY" "$SCRIPT" --shipped "$T/files.txt" "$REF" > "$T/out.txt"; }

echo "1. a single project builds what its settings list, and only folders with an app.json"
app App; app App.Test; app Unlisted
put .AL-Go/settings.json '{"appFolders":["App","Missing"],"testFolders":["App.Test"]}'
put .github/AL-Go-Settings.json '{"type":"PTE"}'
ONE="$(commit one)"
check  "the run succeeds"                         folders "$ONE"
check  "App is an app folder"                     listed App
check  "App.Test is an app folder"                listed App.Test
refute "a folder with an app.json that the settings do not list is not" listed Unlisted
refute "a listed folder that does not exist is not" listed Missing

echo "2. what ships from those folders"
REF="$ONE"
shipped App/src/Code.al App/docs/Design.md App/scripts/run.ps1 Unlisted/src/Code.al .github/workflows/x.yaml README.md App/app.json
check  "code in an app folder ships"              listed App/src/Code.al
check  "app.json ships"                           listed App/app.json
refute "docs/ inside an app folder does not"      listed App/docs/Design.md
refute "scripts/ inside an app folder does not"   listed App/scripts/run.ps1
refute "an app AL-Go does not build does not"     listed Unlisted/src/Code.al
refute "the pipeline does not"                    listed .github/workflows/x.yaml
refute "the readme does not"                      listed README.md
shipped App.Testing/x.al
refute "a folder that only starts like an app folder does not" listed App.Testing/x.al

echo "3. a project with no lists builds every folder below it that has an app.json"
put .AL-Go/settings.json '{"country":"us"}'
EMPTY="$(commit empty)"
check  "the run succeeds"                         folders "$EMPTY"
check  "App is found"                             listed App
check  "Unlisted is found too"                    listed Unlisted
app Deep/Nested/App
NESTED="$(commit nested)"
folders "$NESTED"
check  "and so is an app further down"            listed Deep/Nested/App

echo "4. the repository settings add to every project's lists"
put .AL-Go/settings.json '{"appFolders":["App"]}'
put .github/AL-Go-Settings.json '{"type":"PTE","testFolders":["App.Test"]}'
REPOLEVEL="$(commit repolevel)"
folders "$REPOLEVEL"
check  "the project's own folder"                 listed App
check  "and the one from the repository settings" listed App.Test

echo "5. wildcards, the way Resolve-Path takes them"
put .AL-Go/settings.json '{"appFolders":["Apps/*"]}'
put .github/AL-Go-Settings.json '{"type":"PTE"}'
app Apps/One; app Apps/Two
WILD="$(commit wild)"
folders "$WILD"
check  "Apps/One matches Apps/*"                  listed Apps/One
check  "Apps/Two matches Apps/*"                  listed Apps/Two
refute "App does not"                             listed App

echo "6. a multi-project repository"
git rm --quiet -r .AL-Go
put Core/.AL-Go/settings.json '{"appFolders":["App"]}'
put Group/Edi/.AL-Go/settings.json '{"appFolders":["EdiApp"]}'
put Too/Deep/Down/.AL-Go/settings.json '{"appFolders":["X"]}'
app Core/App; app Group/Edi/EdiApp; app Too/Deep/Down/X
MULTI="$(commit multi)"
folders "$MULTI"
check  "a project one level down"                 listed Core/App
check  "a project two levels down"                listed Group/Edi/EdiApp
refute "a project three levels down is not one"   listed Too/Deep/Down/X
put .github/AL-Go-Settings.json '{"type":"PTE","projects":["Core"]}'
LISTEDPROJECTS="$(commit listedprojects)"
folders "$LISTEDPROJECTS"
check  "the projects setting keeps Core"          listed Core/App
refute "and leaves out the rest"                  listed Group/Edi/EdiApp

echo "7. two refs add up, so neither side can make the gate fail open"
git rm --quiet -r Core Group Too
put .github/AL-Go-Settings.json '{"type":"PTE"}'
put .AL-Go/settings.json '{"appFolders":["App"]}'
BASE="$(commit base)"
put .AL-Go/settings.json '{"appFolders":["App","NewApp"]}'
app NewApp
ADDS="$(commit adds)"
git checkout --quiet "$BASE"
put .AL-Go/settings.json '{"appFolders":[]  ,"testFolders":["App.Test"]}'
DROPS="$(commit drops)"
folders "$BASE" "$ADDS"
check  "a folder the request adds counts"         listed NewApp
folders "$BASE" "$DROPS"
check  "a folder the request takes out still counts" listed App

echo "8. settings that cannot be read stop with exit code 2"
put .AL-Go/settings.json '{"appFolders": ["App",'
BROKEN="$(commit broken)"
set +e
"$PY" "$SCRIPT" "$BROKEN" > /dev/null 2>&1
code=$?
set -e
check  "the exit code is 2"                       test "$code" -eq 2
put .AL-Go/settings.json "$(printf '\357\273\277{"appFolders":["App"]}')"
BOM="$(commit bom)"
check  "a settings file with a BOM is read"       folders "$BOM"
check  "and gives its folder"                     listed App

echo
if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
