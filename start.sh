#!/usr/bin/env bash
# Start your Workbench agent on this computer.
#
#   ./start.sh --api https://your-redline-server --token rlat_...   first time
#   ./start.sh --api ... --token ... --service   first time, and start it on every boot
#   ./start.sh                start it (or watch it, when it runs already)
#   ./start.sh opencode       switch to OpenCode and start it (./start.sh claude: back)
#   ./start.sh restart        stop it and start it again, updated
#   ./start.sh stop           stop it (the service too)
#   ./start.sh status         service, session, kit, token, last seen by the server
#   ./start.sh attach         watch it (detach: Ctrl-b d)
#   ./start.sh logs           what this script did, newest last
#   ./start.sh install        start it automatically after a reboot (user service)
#   ./start.sh uninstall      do not start it after a reboot any more
#   ./start.sh foreground     run it in this terminal instead of tmux
#   ./start.sh --dry-run      print the settings it would use, start nothing
#
# Options: --runner claude|opencode, --model provider/model (OpenCode),
# --name <agent name>, --headless (OpenCode without its screen).
# Settings are kept in config.yaml next to this file (flat `key: value`
# lines), the token in .env (readable only by you); neither is committed.
# The agent kit - the command line and the instructions the agent follows -
# is fetched from your Workbench server into kit/ on each start.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$HERE/kit"
ENV_FILE="$HERE/.env"
CONFIG="$HERE/config.yaml"
LOG_DIR="$HERE/logs"
LOG="$LOG_DIR/start.log"
LOCK="$HERE/.start.lock"
PROMPT="You are the Workbench main agent for this account, working on this computer through the Workbench server with the REDLINE_* settings in your environment. Never print, echo, write or paste REDLINE_TOKEN. Read CLAUDE.md and AGENTS.md, then start the main-agent loop from AGENTS.md and keep it going."
RESUME_PROMPT="You were restarted (the computer, the service or the agent), and the agent kit may have been updated: read CLAUDE.md and AGENTS.md again, run revisions.py resume as AGENTS.md says under \"First thing to do\", then carry on the main-agent loop. Never print, echo, write or paste REDLINE_TOKEN."

say()  { printf '%s\n' "$*"; log "$*"; }
die()  { printf 'start.sh: %s\n' "$*" >&2; log "error: $*"; exit 1; }

# A line in logs/start.log - never the token. Rotated at 1 MB, one old file kept.
log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv -f "$LOG" "$LOG.1"
  fi
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
}

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }

API="" TOKEN="" NAME="" RUNNER="" MODEL="" HEADLESS="" MODE="start" DRY=0 WANT_SERVICE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --api) [ $# -ge 2 ] || die "--api needs the server's address"; API="$2"; shift 2 ;;
    --api=*) API="${1#*=}"; shift ;;
    --token) [ $# -ge 2 ] || die "--token needs the token"; TOKEN="$2"; shift 2 ;;
    --token=*) TOKEN="${1#*=}"; shift ;;
    --name) [ $# -ge 2 ] || die "--name needs a name"; NAME="$2"; shift 2 ;;
    --name=*) NAME="${1#*=}"; shift ;;
    --runner) [ $# -ge 2 ] || die "--runner needs claude or opencode"; RUNNER="$2"; shift 2 ;;
    --runner=*) RUNNER="${1#*=}"; shift ;;
    --model) [ $# -ge 2 ] || die "--model needs provider/model"; MODEL="$2"; shift 2 ;;
    --model=*) MODEL="${1#*=}"; shift ;;
    --headless) HEADLESS="yes"; shift ;;
    --service) WANT_SERVICE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    claude|opencode) RUNNER="$1"; [ "$MODE" = "start" ] && MODE="switch"; shift ;;
    --foreground|foreground) MODE="foreground"; shift ;;
    --restart|restart) MODE="restart"; shift ;;
    --stop|stop) MODE="stop"; shift ;;
    --status|status) MODE="status"; shift ;;
    --attach|attach) MODE="attach"; shift ;;
    --logs|logs) MODE="logs"; shift ;;
    --install|install) MODE="install"; shift ;;
    --uninstall|uninstall) MODE="uninstall"; shift ;;
    --unit|unit) MODE="unit"; shift ;;        # print the service file install writes
    start) shift ;;
    --run) MODE="run"; shift ;;               # inside the tmux session
    --service-run|service-run) MODE="service-run"; shift ;;   # what the user service runs
    -h|--help|help) usage; exit 0 ;;
    *) die "unknown option: $1 (./start.sh --help)" ;;
  esac
done

# ---------------------------------------------------------------- settings

# config.yaml: flat `key: value` lines, `#` comments; no nesting, lists or
# multi-line values. Read by this script and start.ps1 without a YAML library.
cfg_get() {
  [ -f "$CONFIG" ] || return 0
  sed -n "s/^$1:[[:space:]]*//p" "$CONFIG" | tail -n 1 | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' \
    -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# .env: KEY=VALUE lines only; nothing in it is ever run.
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

# Settings that were kept in .env before config.yaml: moved there once.
migrate_env() {
  [ -f "$CONFIG" ] || [ ! -f "$ENV_FILE" ] && return 0
  grep -q -E '^REDLINE_(API|AGENT|RUNNER|CLAUDE_FLAGS)=' "$ENV_FILE" || return 0
  [ "$DRY" = 1 ] && return 0
  API_OLD="$(env_get REDLINE_API)" NAME_OLD="$(env_get REDLINE_AGENT)"
  RUNNER_OLD="$(env_get REDLINE_RUNNER)" FLAGS_OLD="$(env_get REDLINE_CLAUDE_FLAGS)"
  write_config "$API_OLD" "${NAME_OLD:-main}" "$RUNNER_OLD" "" "" "" "$FLAGS_OLD" ""
  write_env "$(env_get REDLINE_TOKEN)"
  log "moved the settings from .env to config.yaml"
}

load_settings() {
  migrate_env
  # (.env's old keys still count until they are moved: --dry-run moves nothing)
  [ -n "$API" ]      || API="$(cfg_get api)"
  [ -n "$API" ]      || API="$(env_get REDLINE_API)"
  [ -n "$TOKEN" ]    || TOKEN="$(env_get REDLINE_TOKEN)"
  [ -n "$NAME" ]     || NAME="$(cfg_get agent)"
  [ -n "$NAME" ]     || NAME="$(env_get REDLINE_AGENT)"
  [ -n "$NAME" ]     || NAME="main"
  [ -n "$RUNNER" ]   || RUNNER="$(cfg_get runner)"
  [ -n "$RUNNER" ]   || RUNNER="$(env_get REDLINE_RUNNER)"
  [ -n "$MODEL" ]    || MODEL="$(cfg_get model)"
  [ -n "$HEADLESS" ] || HEADLESS="$(cfg_get headless)"
  ROOM_MODEL="$(cfg_get room_model)"
  SESSION="${REDLINE_SESSION:-$(cfg_get session)}"
  SESSION="${SESSION:-redline-agent}"
  CLAUDE_FLAGS="$(cfg_get claude_flags)"
  [ -n "$CLAUDE_FLAGS" ] || CLAUDE_FLAGS="$(env_get REDLINE_CLAUDE_FLAGS)"
  [ -n "$CLAUDE_FLAGS" ] || CLAUDE_FLAGS="--allow-dangerously-skip-permissions"
  OPENCODE_FLAGS="$(cfg_get opencode_flags)"
  # OpenCode: what Claude Code's flag above does. The kit's opencode.json
  # denies what must stay denied (the token, .env, and any path outside the
  # folder the agent works in) - --auto approves what is asked, not a deny.
  [ -n "$OPENCODE_FLAGS" ] || OPENCODE_FLAGS="--auto"
  API="${API%/}"
  case "$HEADLESS" in yes|true|1|on) HEADLESS=yes ;; *) HEADLESS="" ;; esac
  if [ "$SESSION" = "redline-agent" ]; then UNIT="workbench-agent"; else UNIT="workbench-agent-$SESSION"; fi
}

# Claude Code when it is there, else OpenCode; config.yaml or --runner decide.
pick_runner() {
  if [ -z "$RUNNER" ]; then
    if command -v claude >/dev/null 2>&1; then RUNNER=claude
    elif find_opencode; then RUNNER=opencode
    else RUNNER=claude
    fi
  fi
  case "$RUNNER" in claude|opencode) ;; *) die "--runner is claude or opencode - got '$RUNNER'" ;; esac
}

write_config() {   # api agent runner model room_model headless claude_flags opencode_flags
  ( umask 077
    { printf '# Workbench agent settings for start.sh / start.ps1: flat `key: value` lines.\n'
      printf '# The token is NOT here: it is in .env (readable only by you). Never commit either.\n'
      printf 'api: %s\nagent: %s\nrunner: %s\n' "$1" "$2" "$3"
      printf '# OpenCode only: the model (provider/model, it must read images), and one for the room agents.\n'
      printf 'model: %s\nroom_model: %s\n' "$4" "$5"
      printf '# OpenCode without its screen (yes/no); flags passed to each runner.\n'
      printf 'headless: %s\nclaude_flags: %s\nopencode_flags: %s\n' "$6" "$7" "$8"
      if [ -n "${SESSION_SET:-}" ]; then printf 'session: %s\n' "$SESSION_SET"; fi
    } > "$CONFIG.new" )
  mv "$CONFIG.new" "$CONFIG"
}

write_env() {
  local extra=""
  [ -f "$ENV_FILE" ] && extra="$(grep -v -E '^(REDLINE_API|REDLINE_TOKEN|REDLINE_AGENT|REDLINE_RUNNER|REDLINE_CLAUDE_FLAGS)=|^# Workbench agent' "$ENV_FILE" || true)"
  ( umask 077
    { printf '# Workbench agent token - keep this file to yourself, never commit it.\n'
      printf 'REDLINE_TOKEN=%s\n' "$1"
      [ -n "$extra" ] && printf '%s\n' "$extra" || true
    } > "$ENV_FILE.new" )
  mv "$ENV_FILE.new" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

save_settings() {
  [ "$DRY" = 1 ] && return 0
  local headless="no" s
  [ "$HEADLESS" = yes ] && headless="yes"
  s="$(cfg_get session)"; SESSION_SET="$s"
  write_config "$API" "$NAME" "$RUNNER" "$MODEL" "$ROOM_MODEL" "$headless" \
    "$(cfg_get claude_flags)" "$(cfg_get opencode_flags)"
  write_env "$TOKEN"
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
  case "$SESSION" in *[!A-Za-z0-9._-]*) die "the session name may use letters, digits, . _ and - only" ;; esac
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

# OpenCode's installer puts it in ~/.opencode/bin, which a service's PATH lacks.
find_opencode() {
  OPENCODE="$(command -v opencode 2>/dev/null || true)"
  [ -n "$OPENCODE" ] || { [ -x "$HOME/.opencode/bin/opencode" ] && OPENCODE="$HOME/.opencode/bin/opencode"; }
  [ -n "$OPENCODE" ]
}

check_prereqs() {
  find_python || die "Python 3.12 or newer is needed (python.org, or: brew install python@3.12 / sudo apt install python3.12 python3.12-venv)"
  if [ "$RUNNER" = claude ]; then
    command -v claude >/dev/null 2>&1 || die "Claude Code is needed: https://docs.anthropic.com/en/docs/claude-code - install it, run 'claude' once to sign in, then start again (or use OpenCode: ./start.sh opencode)"
  else
    find_opencode || die "OpenCode is needed: https://opencode.ai/docs/ (curl -fsSL https://opencode.ai/install | bash), then 'opencode auth login' to sign in to a model provider, then start again"
    check_opencode_model
  fi
}

# A model OpenCode can use: the one in config.yaml must be one it knows; with
# none, OpenCode's own default is used - say that it has to read images.
check_opencode_model() {
  local models
  models="$("$OPENCODE" models 2>/dev/null || true)"
  if [ -n "$MODEL" ]; then
    printf '%s\n' "$models" | grep -qxF "$MODEL" \
      || die "OpenCode does not know the model '$MODEL' - sign in to its provider with 'opencode auth login' (or add it to OpenCode's config), list them with 'opencode models', then ./start.sh --model provider/model"
  elif [ -z "$models" ]; then
    die "OpenCode has no model to use - run 'opencode auth login' (you do that, not this script), then start again"
  else
    say "note: no model set for OpenCode - it uses its default. The notes' red marks are pictures: pick a model that reads images and uses tools reliably, e.g. ./start.sh --model provider/model (list: opencode models)"
  fi
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

# A person at a terminal, who may be asked and shown the agent.
tty_ok() { [ -t 0 ] && [ -t 1 ] && [ -z "${REDLINE_NO_ATTACH:-}" ]; }

running() { command -v tmux >/dev/null 2>&1 && tmux has-session -t "=$SESSION" 2>/dev/null; }

# One start at a time: the service and a hand-typed ./start.sh never both
# start an agent on the same token.
take_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock -w 120 9 || die "another start.sh is starting the agent - try again in a minute"
  else
    local i=0
    until mkdir "$LOCK.d" 2>/dev/null; do
      i=$((i + 1)); [ $i -lt 120 ] || die "another start.sh is starting the agent (or remove $LOCK.d)"
      sleep 1
    done
    trap 'rmdir "$LOCK.d" 2>/dev/null || true' EXIT
  fi
}

# Claude Code keeps a folder's conversations in ~/.claude/projects/<path
# with every other character a dash>; OpenCode's main session id is written
# to kit/work/.main-session by the kit's plugin.
claude_has_session() {
  local d="$HOME/.claude/projects/$(printf '%s' "$KIT" | sed 's/[^A-Za-z0-9]/-/g')"
  ls "$d"/*.jsonl >/dev/null 2>&1
}

opencode_session() {
  local f="$KIT/work/.main-session" id=""
  [ -f "$f" ] && id="$(tr -dc 'A-Za-z0-9_-' < "$f" | head -c 80)"
  printf '%s' "$id"
}

# The runner's command line: resuming the last conversation in kit/ when
# there is one ($1 = resume), a fresh one with the main-agent prompt if not.
runner_cmd() {
  local resume="$1"
  CMD=()
  if [ "$RUNNER" = claude ]; then
    # shellcheck disable=SC2206  # the flags are words on purpose
    CMD=(claude $CLAUDE_FLAGS)
    if [ "$resume" = resume ]; then CMD+=(--continue "$RESUME_PROMPT"); else CMD+=("$PROMPT"); fi
  else
    # shellcheck disable=SC2206
    CMD=("$OPENCODE" $OPENCODE_FLAGS)
    [ -n "$MODEL" ] && CMD+=(-m "$MODEL")
    # Resumed, the kit's plugin sends the prompt (OpenCode does not send
    # --prompt into a resumed session).
    if [ "$resume" = resume ]; then
      CMD+=(-s "$(opencode_session)"); export REDLINE_OPENCODE_RESUME="$RESUME_PROMPT"
    else
      CMD+=(--prompt "$PROMPT"); unset REDLINE_OPENCODE_RESUME
    fi
  fi
}

has_session() {
  if [ "$RUNNER" = claude ]; then claude_has_session; else [ -n "$(opencode_session)" ]; fi
}

opencode_env() {
  # Room agents in the background, their reports coming back as messages;
  # builds and questions to the person take minutes, so the shell waits an
  # hour; the room agents on room_model when one is set.
  export OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS=true
  export OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS="${OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS:-3600000}"
  if [ -n "$ROOM_MODEL" ]; then
    export OPENCODE_CONFIG_CONTENT="{\"agent\":{\"redline-3d\":{\"model\":\"$ROOM_MODEL\"},\"redline-pcb\":{\"model\":\"$ROOM_MODEL\"},\"redline-firmware\":{\"model\":\"$ROOM_MODEL\"}}}"
  fi
}

# OpenCode without its screen: a local server keeps the session (and the
# kit's watcher) alive; `opencode attach <url>` shows it.
run_headless() {
  local port="${REDLINE_OPENCODE_PORT:-4096}" url srv
  url="http://127.0.0.1:$port"
  "$OPENCODE" serve --hostname 127.0.0.1 --port "$port" &
  srv=$!
  sleep 3
  log "OpenCode server on $url (opencode attach $url to watch)"
  local args=(run --attach "$url" --dir "$KIT")
  # shellcheck disable=SC2206  # the flags are words on purpose
  [ -n "$OPENCODE_FLAGS" ] && args+=($OPENCODE_FLAGS)
  [ -n "$MODEL" ] && args+=(-m "$MODEL")
  if [ "$1" = resume ]; then args+=(-s "$(opencode_session)" "$RESUME_PROMPT"); else args+=("$PROMPT"); fi
  "$OPENCODE" "${args[@]}" || { [ "$1" = resume ] && "$OPENCODE" run --attach "$url" --dir "$KIT" ${MODEL:+-m "$MODEL"} "$PROMPT"; } || true
  wait "$srv"
}

run_agent() {
  load_settings
  pick_runner
  [ -n "$API" ] && [ -n "$TOKEN" ] || die "no settings - run ./start.sh --api ... --token ... first"
  export REDLINE_TRANSPORT=api REDLINE_API="$API" REDLINE_TOKEN="$TOKEN" REDLINE_AGENT="$NAME"
  unset MONGODB_URI
  cd "$KIT"
  mkdir -p work
  # The drawings and pages the commands write for the agent to look at go in
  # its own folder, not the system's temporary one: OpenCode refuses a path
  # outside this folder (the kit's opencode.json, external_directory), so the
  # temporary folder moves with it.
  export TMPDIR="$KIT/work"
  local how=fresh
  [ "$RUNNER" = opencode ] && { find_opencode || die "OpenCode is not installed"; opencode_env; }
  has_session && how=resume
  log "starting $RUNNER ($how) as agent '$NAME' on $API"
  if [ "$RUNNER" = opencode ] && [ "$HEADLESS" = yes ]; then
    run_headless "$how"
    return
  fi
  runner_cmd "$how"
  if [ "$how" = resume ]; then
    # A conversation that cannot be resumed ends at once: start a fresh one.
    local t0=$SECONDS
    "${CMD[@]}" && exit 0
    [ $((SECONDS - t0)) -lt 20 ] || exit 1
    log "could not resume the last conversation - starting a fresh one"
    runner_cmd fresh
  fi
  exec "${CMD[@]}"
}

start_session() {
  tmux new-session -d -s "$SESSION" -c "$KIT" "bash '$HERE/start.sh' --run"
  say "started in tmux session '$SESSION' as agent '$NAME' ($RUNNER) on $API"
}

# Fetch the kit and start the agent in tmux, unless it runs already.
prepare_and_start() {
  take_lock
  if running; then
    say "already running - ./start.sh attach to watch it (detach: Ctrl-b d), ./start.sh restart to start it again updated"
    return 0
  fi
  local out
  out="$(fetch_kit 2>&1)" || die "${out:-could not fetch the agent kit}"
  say "$out"
  ensure_venv
  start_session
}

# ---------------------------------------------------------------- start on boot

on_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

unit_file() { printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT.service"; }
plist_file() { printf '%s' "$HOME/Library/LaunchAgents/com.workbench.$UNIT.plist"; }

service_installed() {
  case "$(uname -s)" in
    Darwin) [ -f "$(plist_file)" ] ;;
    *) [ -f "$(unit_file)" ] ;;
  esac
}

write_unit() {   # to $1
  cat > "$1" <<EOF
# Workbench agent - started by $HERE/start.sh install
[Unit]
Description=Workbench agent ($NAME) in tmux session $SESSION
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/env bash $HERE/start.sh --service-run
ExecStop=/usr/bin/env bash -c 'tmux kill-session -t "=$SESSION" 2>/dev/null || true'
Restart=on-failure
RestartSec=15
RestartSteps=6
RestartMaxDelaySec=600
Environment="PATH=$PATH"
Environment=REDLINE_SESSION=$SESSION
# Only this script is stopped with the service: the tmux server may hold
# the person's own sessions too (ExecStop ends the agent's).
KillMode=process

[Install]
WantedBy=default.target
EOF
}

install_service() {
  case "$(uname -s)" in
    Darwin)
      mkdir -p "$HOME/Library/LaunchAgents"
      cat > "$(plist_file)" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.workbench.$UNIT</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$HERE/start.sh</string><string>--service-run</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>$PATH</string><key>REDLINE_SESSION</key><string>$SESSION</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
</dict></plist>
EOF
      launchctl unload "$(plist_file)" 2>/dev/null || true
      launchctl load -w "$(plist_file)"
      say "installed: starts at login (LaunchAgent com.workbench.$UNIT) - ./start.sh uninstall to undo" ;;
    *)
      on_wsl && ! systemctl --user show-environment >/dev/null 2>&1 && \
        die "in WSL, start it on Windows logon from PowerShell instead: start.ps1 -Install"
      command -v systemctl >/dev/null 2>&1 || die "no systemd here: start it again after each reboot with ./start.sh"
      mkdir -p "$(dirname "$(unit_file)")"
      write_unit "$(unit_file)"
      systemctl --user daemon-reload
      systemctl --user enable --now "$UNIT.service" >/dev/null
      say "installed: the user service $UNIT starts the agent at every login - ./start.sh uninstall to undo"
      if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
        say "to start it at boot, before you log in, run once (it may ask for your password): loginctl enable-linger $USER"
      fi ;;
  esac
}

uninstall_service() {
  case "$(uname -s)" in
    Darwin)
      [ -f "$(plist_file)" ] || { say "not installed"; return 0; }
      launchctl unload -w "$(plist_file)" 2>/dev/null || true
      rm -f "$(plist_file)" ;;
    *)
      [ -f "$(unit_file)" ] || { say "not installed"; return 0; }
      systemctl --user disable --now "$UNIT.service" >/dev/null 2>&1 || true
      rm -f "$(unit_file)"
      systemctl --user daemon-reload ;;
  esac
  say "uninstalled: it no longer starts by itself (./start.sh starts it by hand)"
}

service_start() {
  case "$(uname -s)" in
    Darwin) launchctl unload "$(plist_file)" 2>/dev/null || true; launchctl load "$(plist_file)" ;;
    *) systemctl --user restart "$UNIT.service" ;;
  esac
}

service_stop() {
  case "$(uname -s)" in
    Darwin) launchctl unload "$(plist_file)" 2>/dev/null || true ;;
    *) systemctl --user stop "$UNIT.service" 2>/dev/null || true ;;
  esac
}

stop_agent() {
  local was=""
  running && was=1
  if service_installed; then
    service_stop
    say "the service is stopped until the next login or ./start.sh (./start.sh uninstall: for good)"
  fi
  running && tmux kill-session -t "=$SESSION"
  if [ -n "$was" ]; then say "stopped"; else say "not running"; fi
}

# ---------------------------------------------------------------- commands

attach() {
  local i=0
  # Started by the service a moment ago: the kit may still be on its way.
  while ! running && [ $i -lt 90 ] && service_installed; do sleep 1; i=$((i + 1)); done
  running || die "not running - ./start.sh to start it (./start.sh logs says what happened)"
  tty_ok || { say "running - tmux attach -t $SESSION to watch it"; return 0; }
  exec tmux attach -t "=$SESSION"
}

status() {
  say() { printf '%s\n' "$*"; }     # looked at, not done: not logged
  load_settings
  pick_runner
  say "runner: $RUNNER${MODEL:+ ($MODEL)}   agent: $NAME   server: ${API:-none yet}"
  if service_installed; then
    if [ "$(uname -s)" = Darwin ]; then say "service: installed (LaunchAgent com.workbench.$UNIT)"
    else say "service: $UNIT $(systemctl --user is-enabled "$UNIT.service" 2>/dev/null || true), $(systemctl --user is-active "$UNIT.service" 2>/dev/null || true)"; fi
  else
    say "service: not installed (./start.sh install starts it after every reboot)"
  fi
  if running; then say "session: running (./start.sh attach to watch, Ctrl-b d to leave it)"; else say "session: not running"; fi
  [ -f "$KIT/VERSION" ] && say "kit: $(cat "$KIT/VERSION")"
  [ -n "$TOKEN" ] && [ -n "$API" ] || { say "no settings yet"; return 0; }
  find_python || die "Python 3.12 or newer is needed"
  REDLINE_TOKEN="$TOKEN" "$PY" -I -c '
import json, os, sys, urllib.request, urllib.error
h = {"Authorization": "Bearer " + os.environ["REDLINE_TOKEN"], "User-Agent": "redline-agent-seed"}
try:
    urllib.request.urlopen(urllib.request.Request(sys.argv[1] + "/api/agent/kit/version", headers=h), timeout=30)
    s = json.load(urllib.request.urlopen(urllib.request.Request(sys.argv[1] + "/api/agent/status", headers=h), timeout=30))
    seen = s.get("seen_s")
    print("token: good; last heard from an agent of this space " + ("%ds ago" % seen if seen is not None else "never")
          + (" (connected)" if s.get("connected") else ""))
except urllib.error.HTTPError as e:
    print("token: refused (%d) - make a new one under Agent tokens" % e.code)
except urllib.error.URLError as e:
    print("server: not reachable (%s)" % e.reason)' "$API"
}

dry_run() {
  load_settings
  pick_runner
  local how=fresh
  has_session && how=resume
  [ "$RUNNER" = opencode ] && { find_opencode || OPENCODE=opencode; }
  runner_cmd "$how"
  printf 'api: %s\nagent: %s\nrunner: %s\nmodel: %s\nroom_model: %s\nheadless: %s\nsession: %s\nservice: %s (%s)\ntoken: %s\nkit: %s\nstart: %s\n' \
    "${API:-none}" "$NAME" "$RUNNER" "${MODEL:-default}" "${ROOM_MODEL:-same as model}" "${HEADLESS:-no}" "$SESSION" \
    "$UNIT" "$(service_installed && echo installed || echo not installed)" "$([ -n "$TOKEN" ] && echo set || echo missing)" \
    "$KIT" "$how"
  printf 'command:'; printf ' %q' "${CMD[@]}" | sed 's/ [^ ]*You\\ .*$/ <prompt>/'; printf '\n'
}

case "$MODE" in
  run) run_agent; exit ;;
  service-run)
    # What the user service runs: start the agent in tmux, then stay while it
    # runs - a stopped session ends this with an error, and the service
    # starts it again (after a pause that grows).
    load_settings; pick_runner
    [ -n "$API" ] && [ -n "$TOKEN" ] || die "no settings - run ./start.sh --api ... --token ... first"
    check_prereqs
    prepare_and_start
    exec 9>&- 2>/dev/null || true
    while running; do sleep 20; done
    log "the tmux session $SESSION ended"
    exit 1 ;;
  stop) load_settings; stop_agent; exit 0 ;;
  status) status; exit 0 ;;
  attach) load_settings; attach; exit 0 ;;
  logs) [ -f "$LOG" ] && tail -n 60 "$LOG" || say "no log yet"; exit 0 ;;
  uninstall) load_settings; uninstall_service; exit 0 ;;
  unit) load_settings; write_unit /dev/stdout; exit 0 ;;
esac

[ "$DRY" = 1 ] && { dry_run; exit 0; }

FIRST=0
[ -f "$CONFIG" ] || FIRST=1
load_settings
pick_runner
ask_missing
save_settings
check_prereqs

case "$MODE" in
  install) install_service; exit 0 ;;
  switch|restart)
    if service_installed; then fetch_kit >/dev/null; service_start; say "restarted ($RUNNER)"; tty_ok && sleep 3 && attach; exit 0; fi
    if running; then tmux kill-session -t "=$SESSION"; say "stopped the running agent"; fi ;;
esac

# The first time: start it on every boot when asked (--service), or offer it.
if [ "$WANT_SERVICE" = 1 ] && ! service_installed; then
  install_service
  tty_ok && { sleep 3; attach; }
  exit 0
fi
# (In WSL the logon task does that: start.ps1 -Install, on Windows.)
if [ "$FIRST" = 1 ] && tty_ok && ! service_installed && [ "$MODE" = start ] && ! on_wsl; then
  read -r -p "Start the agent by itself after every reboot (a user service)? [y/N] " yn
  case "$yn" in y|Y|yes) install_service; sleep 3; attach; exit 0 ;; esac
  say "not installed - start it with ./start.sh after a reboot (./start.sh install to change your mind)"
fi

if service_installed && [ "$MODE" != foreground ]; then
  running || service_start
  tty_ok && { sleep 2; attach; }
  say "running under the service $UNIT - ./start.sh attach to watch it"
  exit 0
fi

if [ "$MODE" != foreground ] && command -v tmux >/dev/null 2>&1; then
  prepare_and_start
  say "keep it running while you develop: it is what works on the notes you queue."
  say "watch it: ./start.sh attach (detach: Ctrl-b d) - stop it: ./start.sh stop"
  # The first time, the runner may ask whether to trust the folder: attach
  # so that question is answered.
  tty_ok && attach
  exit 0
fi
take_lock
running && die "already running in tmux session $SESSION - ./start.sh stop first"
fetch_kit
ensure_venv
say "running in this terminal as agent '$NAME' ($RUNNER) on $API - keep it open while you develop (no tmux: install it to run in the background)"
run_agent
