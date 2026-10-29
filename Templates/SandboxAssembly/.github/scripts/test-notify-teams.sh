#!/usr/bin/env bash
#
# Exercises notify-teams.py against a throwaway repository, a stub `gh` first on PATH and a local
# HTTP server standing in for the Teams webhook. No network beyond localhost.
#
#   .github/scripts/test-notify-teams.sh

set -eu

SCRIPT="$(cd "$(dirname "$0")" && pwd)/notify-teams.py"
PY="$(command -v python3 || command -v python)"
T="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$T"' EXIT
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
git config core.autocrlf false
echo base > base.txt
git add . && git commit --quiet -m base

# A manifest, written the way assemble-sandbox.sh writes it.
git commit --quiet --allow-empty -m "sandbox/current: assembled from main @ 1111111

Included:
  #1 feature/1-one @ aaaaaaa
  #2 fix/2-two @ bbbbbbb
Skipped:
  #4 feature/4-four @ ddddddd - conflict with main plus #1 #2 in: base.txt"
MANIFEST="$(git rev-parse HEAD)"
git commit --quiet --allow-empty -m "an ordinary commit, not a manifest"
NOT_A_MANIFEST="$(git rev-parse HEAD)"

# The stub gh knows the title of #1 - with characters that are Markdown in a card - and fails for
# every other request, so the branch name has to stand in.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2 $3" = "pr view 1" ]; then
    echo '{"title":"AB#1 Lots [x] and *stars* on_lines"}'
    exit 0
fi
exit 1
STUB
chmod +x "$T/bin/gh"
# Windows (Git Bash): Python cannot start a script without an extension, so give it a .cmd that
# hands the call to the bash stub.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '@bash "%%~dp0gh" %%*\r\n' > "$T/bin/gh.cmd" ;;
esac

export PATH="$T/bin:$PATH" GITHUB_REPOSITORY=org/repo GITHUB_SERVER_URL=https://github.com \
       RUN_URL=https://example.test/runs/77
unset TEAMS_WEBHOOK_URL SANDBOX_URL || true

notify() { DEPLOYED_SHA="$1" "$PY" "$SCRIPT" "${@:2}" > "$T/out.txt" 2>&1; }
said()   { grep -qF -- "$1" "$T/out.txt"; }
# Reads the payload printed by --dry-run, or posted to the server, and evaluates a Python expression
# on it: p is the message, c the card, text all the card's text joined. eval is safe here: the
# expressions are the literal ones written in this file, run on a payload this test produced.
payload() {  # <file> <python expression>
    "$PY" - "$1" "$2" <<'PYEOF'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
c = p["attachments"][0]["content"]
text = "\n".join(b.get("text", "") for b in c["body"])
sys.exit(0 if eval(sys.argv[2]) else 1)
PYEOF
}

echo "1. the card lists what is in the Sandbox and what was left out"
check  "a dry run succeeds"                         notify "$MANIFEST" --dry-run
check  "it is a Teams message with an Adaptive Card" payload "$T/out.txt" 'p["type"] == "message" and p["attachments"][0]["contentType"] == "application/vnd.microsoft.card.adaptive"'
check  "it counts two requests in the Sandbox"      payload "$T/out.txt" '"In the Sandbox now (2)" in text'
check  "#1 links to its pull request"               payload "$T/out.txt" '"[#1](https://github.com/org/repo/pull/1)" in text'
check  "#1 carries its title, Markdown escaped"     payload "$T/out.txt" 'r"Lots \[x\] and \*stars\* on\_lines" in text'
check  "#2 falls back to its branch"                payload "$T/out.txt" 'r"fix/2-two @ `bbbbbbb`" in text'
check  "the left-out request says why"              payload "$T/out.txt" '"Left out (1)" in text and "conflict with main plus #1 #2 in: base.txt" in text'
check  "a button opens the CI/CD run"               payload "$T/out.txt" 'any(a["url"] == "https://example.test/runs/77" for a in c["actions"])'
refute "no Sandbox button without SANDBOX_URL"      payload "$T/out.txt" 'any(a["title"] == "Open the Sandbox" for a in c["actions"])'
SANDBOX_URL=https://businesscentral.dynamics.com/t/Sandbox notify "$MANIFEST" --dry-run
check  "with SANDBOX_URL there is a Sandbox button" payload "$T/out.txt" 'any(a["title"] == "Open the Sandbox" for a in c["actions"])'

echo "2. without a webhook nothing is posted, and the run stays green"
check  "the run succeeds"                           notify "$MANIFEST"
check  "and says why"                               said "TEAMS_WEBHOOK_URL is not set"

echo "3. a commit that is not a manifest posts nothing"
check  "the run succeeds"                           env TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x DEPLOYED_SHA="$NOT_A_MANIFEST" "$PY" "$SCRIPT"
TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x notify "$NOT_A_MANIFEST" || true
check  "and says why"                               said "is not a sandbox manifest"

echo "4. a webhook that cannot be reached is a warning, not a failure"
check  "the run succeeds"                           env TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x DEPLOYED_SHA="$MANIFEST" "$PY" "$SCRIPT"
TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x notify "$MANIFEST" || true
check  "and warns"                                  said "::warning::Teams notification failed"

echo "5. the card really goes out as a JSON POST"
# A one-request server: it writes the body it receives to a file and answers 202, as Teams does.
"$PY" - "$T/port" "$T/posted.json" <<'PYEOF' &
import http.server, sys
port_file, out_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with open(out_file, "wb") as f:
            f.write(body)
        self.send_response(202); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.handle_request()
PYEOF
SERVER_PID=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
PORT="$(cat "$T/port")"
check  "the run succeeds"                           env TEAMS_WEBHOOK_URL="http://127.0.0.1:$PORT/hook" DEPLOYED_SHA="$MANIFEST" "$PY" "$SCRIPT"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
check  "the server received the card"               payload "$T/posted.json" '"In the Sandbox now (2)" in text'

echo
if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
