#!/usr/bin/env bash
# Start your Workbench agent on this computer.
#
#   ./start.sh --api https://your-redline-server --token rlat_...   first time
#   ./start.sh                     start again (settings from .env, kit updated)
#   ./start.sh --restart           stop it and start it again, updated
#   ./start.sh --stop              stop it
#   ./start.sh --status            is it running, and is the token good
#   ./start.sh --foreground        run it here instead of in tmux
#
# The settings are kept in .env next to this file (readable only by you,
# never committed). The agent kit - the command line and the instructions
# the agent follows - is fetched from your Workbench server into kit/ on each
# start, so it is always the server's current one.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$HERE/kit"
ENV_FILE="$HERE/.env"
SESSION="${REDLINE_SESSION:-redline-agent}"
PROMPT="You are the Workbench main agent for this account, working on this computer through the Workbench server with the REDLINE_* settings in your environment. Never print, echo, write or paste REDLINE_TOKEN. Read CLAUDE.md and AGENTS.md, then start the main-agent loop from AGENTS.md and keep it going."

say()  { printf '%s\n' "$*"; }
die()  { printf 'start.sh: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

API="" TOKEN="" NAME="" MODE="start"
while [ $# -gt 0 ]; do
  case "$1" in
    --api) [ $# -ge 2 ] || die "--api needs the server's address"; API="$2"; shift 2 ;;
    --api=*) API="${1#*=}"; shift ;;
    --token) [ $# -ge 2 ] || die "--token needs the token"; TOKEN="$2"; shift 2 ;;
    --token=*) TOKEN="${1#*=}"; shift ;;
    --name) [ $# -ge 2 ] || die "--name needs a name"; NAME="$2"; shift 2 ;;
    --name=*) NAME="${1#*=}"; shift ;;
    --foreground) MODE="foreground"; shift ;;
    --restart) MODE="restart"; shift ;;
    --stop) MODE="stop"; shift ;;
    --status) MODE="status"; shift ;;
    --run) MODE="run"; shift ;;            # inside the tmux session
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (./start.sh --help)" ;;
  esac
done

# ---------------------------------------------------------------- settings

# KEY=VALUE lines only; nothing in .env is ever run.
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

load_settings() {
  [ -n "$API" ]   || API="$(env_get REDLINE_API)"
  [ -n "$TOKEN" ] || TOKEN="$(env_get REDLINE_TOKEN)"
  [ -n "$NAME" ]  || NAME="$(env_get REDLINE_AGENT)"
  [ -n "$NAME" ]  || NAME="main"
  CLAUDE_FLAGS="$(env_get REDLINE_CLAUDE_FLAGS)"
  [ -n "$CLAUDE_FLAGS" ] || CLAUDE_FLAGS="--allow-dangerously-skip-permissions"
  API="${API%/}"
}

ask_missing() {
  if [ -z "$API" ]; then
    [ -t 0 ] || die "no server address: ./start.sh --api https://your-redline-server --token rlat_..."
    read -r -p "Workbench server address (e.g. https://workbench.example.com): " API
    API="${API%/}"
  fi
  if [ -z "$TOKEN" ]; then
    [ -t 0 ] || die "no token: make one in Workbench (Settings > Agent tokens), then ./start.sh --token rlat_..."
    read -r -s -p "Agent token (rlat_..., from Settings > Agent tokens; not shown): " TOKEN
    echo
  fi
  case "$API" in http://*|https://*) ;; *) die "the server address starts with https:// - got '$API'" ;; esac
  case "$TOKEN" in rlat_*) ;; *) die "an agent token starts with rlat_ - make one in Workbench under Agent tokens" ;; esac
  case "$NAME" in *[!A-Za-z0-9._\ -]*) die "the agent name may use letters, digits, space, . _ and - only" ;; esac
}

save_settings() {
  local extra=""
  [ -f "$ENV_FILE" ] && extra="$(grep -v -E '^(REDLINE_API|REDLINE_TOKEN|REDLINE_AGENT)=' "$ENV_FILE" || true)"
  ( umask 077
    { printf '# Workbench agent settings - keep this file to yourself, never commit it.\n'
      printf 'REDLINE_API=%s\nREDLINE_TOKEN=%s\nREDLINE_AGENT=%s\n' "$API" "$TOKEN" "$NAME"
      [ -n "$extra" ] && printf '%s\n' "$extra" | grep -v '^# Workbench agent settings' || true
    } > "$ENV_FILE.new" )
  mv "$ENV_FILE.new" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

# ---------------------------------------------------------------- prerequisites

find_python() {
  local c
  for c in "${REDLINE_PYTHON:-}" python3.14 python3.13 python3.12 python3 python; do
    [ -n "$c" ] || continue
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' 2>/dev/null; then
      PY="$(command -v "$c")"; return 0
    fi
  done
  return 1
}

check_prereqs() {
  find_python || die "Python 3.12 or newer is needed (python.org, or: brew install python@3.12 / sudo apt install python3.12 python3.12-venv)"
  command -v claude >/dev/null 2>&1 || die "Claude Code is needed: https://docs.anthropic.com/en/docs/claude-code - install it, run 'claude' once to sign in, then start again"
}

# ---------------------------------------------------------------- the kit

# Fetch the kit when the server has a newer one; check the token on the way.
# The token goes in a header from the environment, never on a command line.
fetch_kit() {
  REDLINE_TOKEN="$TOKEN" REDLINE_AGENT="$NAME" "$PY" -I - "$API" "$KIT" <<'PYEOF'
import io, json, os, shutil, sys, tarfile, urllib.error, urllib.request
api, kit = sys.argv[1], sys.argv[2]
headers = {"Authorization": "Bearer " + os.environ["REDLINE_TOKEN"], "User-Agent": "redline-agent-seed",
           "X-Workbench-Actor": "agent:" + os.environ.get("REDLINE_AGENT", "main"), "X-Workbench-CSRF": "1"}

def get(path):
    try:
        return urllib.request.urlopen(urllib.request.Request(api + path, headers=headers), timeout=180)
    except urllib.error.HTTPError as e:
        if e.code == 401:
            sys.exit("the token is unknown, revoked or expired - make a new one in Workbench (Settings > Agent tokens) "
                     "and run ./start.sh --token rlat_...")
        if e.code == 403:
            sys.exit("the server refused the kit (403) - is this an agent token from Settings > Agent tokens?")
        if e.code == 404:
            sys.exit(f"{api} has no agent kit - is this the address of your Workbench server?")
        sys.exit(f"{api}{path}: HTTP {e.code}")
    except urllib.error.URLError as e:
        hint = (" (on macOS with Python from python.org, run 'Install Certificates.command' once)"
                if "CERTIFICATE" in str(e.reason).upper() else "")
        sys.exit(f"cannot reach {api}: {e.reason}{hint}")

want = json.load(get("/api/agent/kit/version"))["version"]
try:
    have = open(os.path.join(kit, "VERSION")).read().strip()
except OSError:
    have = ""
if have == want and os.path.isdir(os.path.join(kit, "tools")):
    print(f"kit {want}: up to date")
    sys.exit(0)
blob = get("/api/agent/kit").read()
new = kit + ".new"
shutil.rmtree(new, ignore_errors=True)
os.makedirs(new)
with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
    for m in tar.getmembers():
        name = m.name.split("/", 1)[1] if "/" in m.name else ""
        if not name or not m.isfile() or name.startswith("/") or ".." in name.split("/"):
            continue
        dest = os.path.join(new, *name.split("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(tar.extractfile(m).read())
os.makedirs(kit, exist_ok=True)
# Everything but the Python environment and the agent's work is replaced.
for entry in os.listdir(kit):
    if entry in (".venv", "work"):
        continue
    p = os.path.join(kit, entry)
    shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)
for entry in os.listdir(new):
    if entry == "work" and os.path.exists(os.path.join(kit, "work")):
        continue
    shutil.move(os.path.join(new, entry), os.path.join(kit, entry))
shutil.rmtree(new, ignore_errors=True)
print(f"kit {want}: fetched" + (f" (was {have})" if have else ""))
PYEOF
}

# The kit's Python packages, in kit/.venv - installed again only when its
# requirements change. Light: builds and parts run on the server.
ensure_venv() {
  local venv="$KIT/.venv" req="$KIT/requirements.txt" stamp="$KIT/.venv/.requirements"
  if [ ! -x "$venv/bin/python" ]; then
    say "making the Python environment (kit/.venv)"
    if ! "$PY" -m venv "$venv" >/dev/null 2>&1; then
      rm -rf "$venv"
      if command -v uv >/dev/null 2>&1; then
        uv venv -q -p "$PY" "$venv"
      else
        die "Python could not make a virtual environment - on Debian/Ubuntu: sudo apt install python3-venv (or python3.12-venv), then start again"
      fi
    fi
  fi
  if ! cmp -s "$req" "$stamp" 2>/dev/null; then
    say "installing the kit's Python packages"
    if [ -x "$venv/bin/pip" ]; then
      "$venv/bin/python" -m pip install -q --disable-pip-version-check -r "$req"
    else
      VIRTUAL_ENV="$venv" uv pip install -q -r "$req"
    fi
    cp "$req" "$stamp"
  fi
}

# ---------------------------------------------------------------- running it

running() { command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION" 2>/dev/null; }

run_agent() {
  load_settings
  [ -n "$API" ] && [ -n "$TOKEN" ] || die "no settings in .env - run ./start.sh --api ... --token ... first"
  export REDLINE_TRANSPORT=api REDLINE_API="$API" REDLINE_TOKEN="$TOKEN" REDLINE_AGENT="$NAME"
  unset MONGODB_URI
  cd "$KIT"
  mkdir -p work
  # shellcheck disable=SC2086  # the flags are words on purpose
  exec claude $CLAUDE_FLAGS "$PROMPT"
}

case "$MODE" in
  run) run_agent ;;
  stop)
    if running; then tmux kill-session -t "$SESSION"; say "stopped"; else say "not running"; fi
    exit 0 ;;
  status)
    load_settings
    if running; then say "running (tmux session $SESSION - tmux attach -t $SESSION)"; else say "not running"; fi
    [ -n "$TOKEN" ] && [ -n "$API" ] || { say "no settings yet"; exit 0; }
    find_python || die "Python 3.12 or newer is needed"
    REDLINE_TOKEN="$TOKEN" "$PY" -I -c '
import os, sys, urllib.request, urllib.error
r = urllib.request.Request(sys.argv[1] + "/api/agent/kit/version",
    headers={"Authorization": "Bearer " + os.environ["REDLINE_TOKEN"], "User-Agent": "redline-agent-seed"})
try:
    urllib.request.urlopen(r, timeout=30); print("token: good, server " + sys.argv[1])
except urllib.error.HTTPError as e:
    print("token: refused (%d) - make a new one under Agent tokens" % e.code)
except urllib.error.URLError as e:
    print("server: not reachable (%s)" % e.reason)' "$API"
    exit 0 ;;
esac

load_settings
ask_missing
save_settings
check_prereqs

if [ "$MODE" = "restart" ] && running; then
  tmux kill-session -t "$SESSION"
  say "stopped the running agent"
fi
if running; then
  say "already running - tmux attach -t $SESSION to watch it (detach: Ctrl-b d), ./start.sh --restart to start it again updated"
  [ -t 0 ] && [ -t 1 ] && exec tmux attach -t "$SESSION"
  exit 0
fi

fetch_kit
ensure_venv

if [ "$MODE" != "foreground" ] && command -v tmux >/dev/null 2>&1; then
  tmux new-session -d -s "$SESSION" -c "$KIT" "bash '$HERE/start.sh' --run"
  say "started in tmux session '$SESSION' as agent '$NAME' on $API"
  say "keep it running while you develop: it is what works on the notes you queue."
  say "watch it: tmux attach -t $SESSION (detach: Ctrl-b d) - stop it: ./start.sh --stop"
  # The first time, Claude Code asks whether to trust the folder: attach so
  # that question is answered.
  [ -t 0 ] && [ -t 1 ] && exec tmux attach -t "$SESSION"
  exit 0
fi
say "running in this terminal as agent '$NAME' on $API - keep it open while you develop (no tmux: install it to run in the background)"
run_agent
