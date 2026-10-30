#!/usr/bin/env bash
#
# Exercises notify-teams.py with a stub `gh` first on PATH and a local HTTP server standing in for
# the Teams webhook. No network beyond localhost.
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

# The stub gh knows the title of #1 - with characters that are Markdown in a card - and of #9, and
# fails for every other request, so the line has to do without.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2 $3" in
    "pr view 1") echo '{"title":"AB#1 Lots [x] and *stars* on_lines"}' ;;
    "pr view 9") echo '{"title":"AB#9 Shortage allocation"}' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"
# Windows (Git Bash): Python cannot start a script without an extension, so give it a .cmd that
# hands the call to the bash stub.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '@bash "%%~dp0gh" %%*\r\n' > "$T/bin/gh.cmd" ;;
esac

# Note for the expressions below: Git Bash rewrites a quoted text that starts with "/" into a Windows
# path on its way to python.exe, so they search for "repo/pull/7)", never for "/pull/7)".
export PATH="$T/bin:$PATH" GITHUB_REPOSITORY=org/repo GITHUB_SERVER_URL=https://github.com \
       RUN_URL=https://example.test/runs/77 DEPLOYED_SHA=abcdef0123456789
unset TEAMS_WEBHOOK_URL SANDBOX_URL SANDBOX_ADDED SANDBOX_REMOVED CHANGES_KNOWN || true

notify() { "$PY" "$SCRIPT" "$@" > "$T/out.txt" 2>&1; }
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

echo "1. a request new in the Sandbox, and requests that left it"
export SANDBOX_ADDED="1@aaaaaaa 2@bbbbbbb" SANDBOX_REMOVED="9:draft 7:closed 5:removed"
check  "a dry run succeeds"                         notify --dry-run
check  "it is a Teams message with an Adaptive Card" payload "$T/out.txt" 'p["type"] == "message" and p["attachments"][0]["contentType"] == "application/vnd.microsoft.card.adaptive"'
check  "it names the assembly"                      payload "$T/out.txt" '"Assembly `abcdef0` is deployed." in text'
check  "two requests are new"                       payload "$T/out.txt" '"New in the Sandbox (2)" in text'
check  "#1 links to its pull request, with its commit" payload "$T/out.txt" '"[#1](https://github.com/org/repo/pull/1)" in text and "`aaaaaaa`" in text'
check  "#1 carries its title, Markdown escaped"     payload "$T/out.txt" 'r"Lots \[x\] and \*stars\* on\_lines" in text'
check  "#2 has no title to show, and still its line" payload "$T/out.txt" '"- [#2](https://github.com/org/repo/pull/2) @ `bbbbbbb`" in text'
check  "three requests left"                        payload "$T/out.txt" '"Left the Sandbox (3)" in text'
check  "#9 left as a draft"                         payload "$T/out.txt" '"Shortage allocation - marked as draft" in text'
check  "#7 was closed without a merge"              payload "$T/out.txt" '"repo/pull/7) - closed without a merge" in text'
check  "#5 was removed"                             payload "$T/out.txt" '"repo/pull/5) - removed from the Sandbox" in text'
check  "a button opens the CI/CD run"               payload "$T/out.txt" 'any(a["url"] == "https://example.test/runs/77" for a in c["actions"])'
refute "no Sandbox button without SANDBOX_URL"      payload "$T/out.txt" 'any(a["title"] == "Open the Sandbox" for a in c["actions"])'
SANDBOX_URL=https://businesscentral.dynamics.com/t/Sandbox notify --dry-run
check  "with SANDBOX_URL there is a Sandbox button" payload "$T/out.txt" 'any(a["title"] == "Open the Sandbox" for a in c["actions"])'

echo "2. only one side changed: only that section is on the card"
SANDBOX_ADDED="" SANDBOX_REMOVED="9:draft" notify --dry-run
refute "no New section"                             payload "$T/out.txt" '"New in the Sandbox" in text'
check  "the Left section"                           payload "$T/out.txt" '"Left the Sandbox (1)" in text'
SANDBOX_ADDED="1@aaaaaaa" SANDBOX_REMOVED="" notify --dry-run
check  "the New section"                            payload "$T/out.txt" '"New in the Sandbox (1)" in text'
refute "no Left section"                            payload "$T/out.txt" '"Left the Sandbox" in text'

echo "3. nothing came in and nothing left: no card at all"
check  "the run succeeds"                           env SANDBOX_ADDED="" SANDBOX_REMOVED="" TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x "$PY" "$SCRIPT"
SANDBOX_ADDED="" SANDBOX_REMOVED="" TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x notify || true
check  "and says why"                               said "no request came into the Sandbox or left it"
refute "and tries to post nothing"                  said "::warning::"

echo "4. a previous state that could not be read: no card"
CHANGES_KNOWN=0 TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x notify || true
check  "says why"                                   said "could not be read"
refute "and tries to post nothing"                  said "::warning::"

echo "5. malformed input is dropped, not posted"
SANDBOX_ADDED='1@aaaaaaa x@y 3@<script>' SANDBOX_REMOVED='9:draft;rm' notify --dry-run
check  "the good entry is kept"                     payload "$T/out.txt" '"New in the Sandbox (1)" in text'
refute "the bad ones are not"                       payload "$T/out.txt" '"script" in text or "Left the Sandbox" in text'

echo "6. without a webhook nothing is posted, and the run stays green"
check  "the run succeeds"                           notify
check  "and says why"                               said "TEAMS_WEBHOOK_URL is not set"

echo "7. a webhook that cannot be reached is a warning, not a failure"
check  "the run succeeds"                           env TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x "$PY" "$SCRIPT"
TEAMS_WEBHOOK_URL=http://127.0.0.1:9/x notify || true
check  "and warns"                                  said "::warning::Teams notification failed"

echo "8. the card really goes out as a JSON POST"
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
check  "the run succeeds"                           env TEAMS_WEBHOOK_URL="http://127.0.0.1:$PORT/hook" "$PY" "$SCRIPT"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
check  "the server received the card"               payload "$T/posted.json" '"New in the Sandbox (2)" in text'

echo
if [ "$FAILS" -eq 0 ]; then echo "all passed"; else echo "$FAILS failed"; exit 1; fi
