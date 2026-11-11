#!/bin/sh
# Run pi in a sandbox built from this kit.
#
#   ./run.sh                          sandbox pi-<cwd folder>
#   ./run.sh bear-mcp                 sandbox pi-bear-mcp
#   ./run.sh --fresh bear-mcp         recreate it with freshly synced settings
#   ./run.sh bear-mcp ~/code/bear-mcp ... with that directory as the workspace
#
# The first argument names the project and the sandbox becomes pi-<project>;
# with no argument the current folder's name is used. SANDBOX=name sets the
# sandbox name outright. Remaining arguments are workspace paths, and sbx
# mounts the current directory when none is given.
#
# Kit content, credentials and workspaces are fixed when a sandbox is created.
# An existing sandbox is re-attached as-is, without syncing; --fresh removes it
# and creates it again from a fresh sync.
set -e

# Resolve $0 through symlinks: run.sh is often linked into ~/bin (pi-sbx), and
# the kit lives next to the real script, not next to the link.
self=$0
while [ -L "$self" ]; do
  dir=$(cd -P "$(dirname "$self")" && pwd)
  target=$(readlink "$self")
  case $target in
    /*) self=$target ;;
    *) self=$dir/$target ;;
  esac
done
kit=$(cd -P "$(dirname "$self")" && pwd)
me=$(basename "$0")

fail() {
  echo "$me: $*" >&2
  exit 1
}

# Workspaces are mounted read-write. One that contains a host credential store
# ($HOME and / included) would hand the sandbox the real tokens the proxy
# exists to keep out.
guard_workspace() { # sbx workspace argument: PATH[:TARGET][:ro]
  dir=$(cd -P "${1%%:*}" 2>/dev/null && pwd) || fail "workspace not found: ${1%%:*}"
  home=$(cd -P "$HOME" && pwd)
  for secret in .pi/agent/auth.json .ssh .gnupg .config/gh; do
    case $home/$secret/ in
      "${dir%/}"/*) fail "workspace $dir contains $home/$secret" ;;
    esac
  done
}

fresh=
if [ "${1:-}" = "--fresh" ]; then
  fresh=1
  shift
fi

if [ $# -gt 0 ]; then
  project=$1
  shift
  case $project in
    */*) fail "project must be a name, not a path: $project
use: $me <project-name> $project" ;;
  esac
else
  project=$(basename "$PWD")
fi

suffix=$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]' |
  tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')
[ -n "$suffix" ] || fail "cannot make a sandbox name from: $project"
name=${SANDBOX:-pi-$suffix}

command -v jq >/dev/null 2>&1 || fail "jq is required"

# Host-side custom secrets, global to all sandboxes. Each maps a placeholder
# the sandbox sees to a value that stays on this Mac; the proxy swaps it in on
# requests to the target host. `sbx secret ls --json` never shows values.
secrets=
load_secrets() {
  secrets=$(sbx secret ls --json) || fail "could not list sbx secrets"
}
global_secret() { # TARGET-HOST ENV -> prints the matching entry, if any
  printf '%s' "$secrets" | jq -c --arg h "$1" --arg e "$2" '
    [.. | objects | select(.scope? == "global" and .env? == $e and
      ((.targets? // []) | index($h)))][0] // empty'
}

# Claude. sbx registers only the first OAuth credential of a kit, and this
# kit's is ChatGPT, so Claude uses a custom secret whose value host pi prints
# on demand (refreshing its own login when needed). The fixed placeholder has
# the sk-ant-oat shape pi needs to send it as a Bearer token. sbx replays the
# command from a bare environment, so it carries absolute paths; it is
# re-registered when pi or Node move, and the fixed placeholder keeps every
# existing sandbox working across that.
claude_placeholder=sk-ant-oat01-pi-sub-proxy-managed
ensure_claude_secret() {
  pi_bin=$(command -v pi) || fail "pi is not on PATH; the Claude login comes from host pi"
  node_bin=$(command -v node) || fail "node is not on PATH; host pi needs it"
  case $pi_bin$node_bin in
    *"'"*) fail "paths containing a single quote are not supported: $pi_bin $node_bin" ;;
  esac
  want="PATH='$(dirname "$node_bin")':/usr/bin:/bin '$pi_bin' auth print-bearer-token --provider anthropic --min-expiry 1h"
  have=$(global_secret api.anthropic.com ANTHROPIC_OAUTH_TOKEN)
  if [ -n "$have" ] &&
    [ "$(printf '%s' "$have" | jq -r .placeholder)" = "$claude_placeholder" ] &&
    [ "$(printf '%s' "$have" | jq -r .source)" = "$want" ]; then
    echo "   Claude: custom secret up to date"
    return 0
  fi
  echo "   Claude: registering custom secret (token from host pi)"
  if ! out=$(sbx secret set-custom --host api.anthropic.com --env ANTHROPIC_OAUTH_TOKEN \
    --placeholder "$claude_placeholder" --command "$want" --refresh 30m 2>&1); then
    printf '%s\n' "$out" >&2
    fail "could not register the Claude custom secret; check host pi with: pi auth check --provider anthropic"
  fi
}

# API keys that pi's configs read from the environment (web search, the
# executor MCP server, TypeSafe), taken from this shell once and kept as they are
# afterwards (sbx secret set-custom ... to change one).
ensure_env_secret() { # TARGET-HOST ENV
  if [ -n "$(global_secret "$1" "$2")" ]; then
    echo "   $2: custom secret present"
  elif printenv "$2" >/dev/null 2>&1; then
    echo "   $2: registering custom secret for $1"
    if ! out=$(printenv "$2" | tr -d '\n' |
      sbx secret set-custom --host "$1" --env "$2" --value-stdin 2>&1); then
      printf '%s\n' "$out" >&2
      fail "could not register the $2 custom secret"
    fi
  else
    echo "   note: $2 is not set here; requests to $1 from the sandbox will not authenticate" >&2
  fi
}

echo "== run: kit $kit, sandbox $name"
echo "== checking host-side secrets"
load_secrets
ensure_claude_secret
ensure_env_secret api.search.brave.com BRAVE_API_KEY
ensure_env_secret firecrawl.nanosite.app FIRECRAWL_API_KEY
ensure_env_secret executor.mac.srvr.dev EXECUTOR_API_KEY
ensure_env_secret api.typesafe.ai TYPESAFE_API_KEY

existing=$(sbx ls -q) || fail "could not list sandboxes (is sbx signed in and its daemon running?)"
exists=
if printf '%s\n' "$existing" | grep -Fqx -- "$name"; then
  exists=1
fi

if [ -n "$exists" ] && [ -z "$fresh" ]; then
  [ $# -eq 0 ] ||
    echo "   note: $name already exists; workspace arguments apply only at create (use --fresh)" >&2
  echo "== attaching to existing sandbox $name (kit content is fixed at create; --fresh re-syncs)"
  exec sbx run --name "$name"
fi

# From here on a sandbox is created. Everything that can refuse runs before
# --fresh removes the old one.
[ $# -gt 0 ] || set -- "$PWD"
for workspace in "$@"; do
  guard_workspace "$workspace"
done

# sbx attaches a stored GitHub credential to every sandbox's GitHub requests
# and forwards the host SSH agent; the kit cannot switch either off.
if [ -z "${PI_SBX_ALLOW_EXPOSURE:-}" ]; then
  printf '%s' "$secrets" | jq -e '
    any(.secrets[]?; .scope == "global" and .type == "service" and .name == "github")
  ' >/dev/null && fail "sbx would attach its stored GitHub credential to the sandbox; run: sbx secret rm github
(PI_SBX_ALLOW_EXPOSURE=1 skips this check)"
  [ "$(sbx settings get ssh.agentForwardingEnabled)" != true ] ||
    fail "sbx would forward your SSH agent into the sandbox; run: sbx settings set ssh.agentForwardingEnabled false
(PI_SBX_ALLOW_EXPOSURE=1 skips this check)"
fi

# Check before removing a sandbox for --fresh. Never replace an existing
# service secret from the shell, and do not block re-attaching an older kit.
if ! printf '%s' "$secrets" | jq -e '
  any(.secrets[]?; .scope == "global" and .type == "service" and .name == "openrouter")
' >/dev/null; then
  fail "OpenRouter key is not stored in sbx; run: sbx secret import openrouter
or enter it with: sbx secret set openrouter"
fi
echo "   OpenRouter: stored service secret present"

if [ -n "$exists" ]; then
  echo "== removing sandbox $name so the synced settings re-apply"
  sbx rm -f "$name" || fail "could not remove sandbox $name; not recreating it"
fi

"$kit/sync.sh"

echo "== validating kit"
sbx kit validate --offline "$kit" >/dev/null || fail "kit validation failed"

# Git runs .git/hooks and the options in .git/config on the host, so the agent
# must not rewrite them. Other files the host later runs (package scripts,
# repo-tracked hooks) stay writable.
case $1 in
  *:*) echo "   note: the first workspace has a : suffix; its .git hooks and config stay writable" >&2 ;;
  *)
    [ ! -d "$1/.git/hooks" ] || set -- "$@" "$1/.git/hooks:ro"
    [ ! -f "$1/.git/config" ] || set -- "$@" "$1/.git/config:ro"
    ;;
esac

echo "== creating sandbox $name (sbx output follows)"
exec sbx run --name "$name" "$kit" "$@"
