#!/usr/bin/env bash
# Checks start.sh without starting anything: its syntax, the settings it
# resolves (--dry-run), config.yaml read with comments and quotes, the
# runner picked or switched, the old .env moved to config.yaml with the
# token left in .env (mode 600), and the service file it would install.
#
#   tests/test-start.sh
set -euo pipefail

SEED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

bash -n "$SEED/start.sh" && ok "start.sh parses" || bad "start.sh parses"

# A seed of its own, with stand-ins for both runners on the PATH.
mkdir -p "$T/seed" "$T/bin"
cp "$SEED/start.sh" "$T/seed/"
printf '#!/bin/sh\n[ "$1" = models ] && echo test/vision\nexit 0\n' > "$T/bin/opencode"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"
chmod +x "$T/bin/"*
export PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" HOME="$T/home"   # no real runner
mkdir -p "$HOME"
cd "$T/seed"
run() { ./start.sh "$@" 2>&1; }

# The old .env, as seeds before config.yaml wrote it.
printf 'REDLINE_API=https://wb.example.com\nREDLINE_TOKEN=rlat_test_secret\nREDLINE_AGENT=laptop\nREDLINE_CLAUDE_FLAGS=--x\n' > .env
out="$(run --dry-run)"
check "dry-run reads the old .env" 'grep -q "^api: https://wb.example.com$" <<<"$out" && grep -q "^agent: laptop$" <<<"$out"'
check "dry-run moves nothing" '[ ! -f config.yaml ]'
check "dry-run never prints the token" '! grep -q rlat_test_secret <<<"$out" && grep -q "^token: set$" <<<"$out"'
check "claude when it is there" 'grep -q "^runner: claude$" <<<"$out" && grep -q "^command: claude --x <prompt>$" <<<"$out"'

# Anything but a dry run moves the settings to config.yaml once.
run unit >/dev/null
check "settings moved to config.yaml" 'grep -q "^api: https://wb.example.com$" config.yaml && grep -q "^claude_flags: --x$" config.yaml'
check ".env keeps only the token" '[ "$(grep -c = .env)" = 1 ] && grep -q "^REDLINE_TOKEN=rlat_test_secret$" .env'
check ".env is 600" '[ "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)" = 600 ]'
check "config.yaml has no token" '! grep -q rlat_ config.yaml'

# config.yaml: comments, quotes, the last line of a key wins.
cat >> config.yaml <<'EOF'
# switched by hand
runner: "opencode"   # trailing comment
model: 'test/vision'
room_model: test/small
session: test-session
EOF
out="$(run --dry-run)"
check "config.yaml with quotes and comments" 'grep -q "^runner: opencode$" <<<"$out" && grep -q "^model: test/vision$" <<<"$out"'
check "OpenCode command line" 'grep -q "^command: .*opencode -m test/vision --prompt <prompt>$" <<<"$out"'
check "session and unit from config.yaml" 'grep -q "^session: test-session$" <<<"$out" && grep -q "^service: workbench-agent-test-session (not installed)$" <<<"$out"'
check "--runner on the command line wins" 'grep -q "^runner: claude$" <<<"$(run --dry-run --runner claude)"'

# Resuming: a main session left by the kit's plugin is resumed.
mkdir -p kit/work && echo ses_abc123 > kit/work/.main-session
out="$(run --dry-run)"
check "OpenCode resumes its last session" 'grep -q "^start: resume$" <<<"$out" && grep -q -- "-s ses_abc123$" <<<"$out"'
mkdir -p "$HOME/.claude/projects/$(printf '%s' "$T/seed/kit" | sed 's/[^A-Za-z0-9]/-/g')"
touch "$HOME/.claude/projects/$(printf '%s' "$T/seed/kit" | sed 's/[^A-Za-z0-9]/-/g')/x.jsonl"
check "Claude Code continues its last conversation" 'grep -q "^command: claude --x --continue <prompt>$" <<<"$(run --dry-run --runner claude)"'

# No runner named and no Claude Code: OpenCode.
sed -i.bak '/^runner:/d' config.yaml && rm -f "$T/bin/claude"
check "OpenCode when Claude Code is missing" 'grep -q "^runner: opencode$" <<<"$(run --dry-run)"'

# The service file.
run unit > "$T/workbench-agent.service"
check "the unit runs the service loop" 'grep -q "start.sh --service-run$" "$T/workbench-agent.service" && grep -q "^Restart=on-failure$" "$T/workbench-agent.service"'
if command -v systemd-analyze >/dev/null 2>&1; then
  check "systemd accepts the unit" 'systemd-analyze --user verify "$T/workbench-agent.service" 2>/dev/null'
fi
check "unknown options are refused" '! run --nope >/dev/null'

exit $fail
