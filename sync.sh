#!/bin/sh
# Mirror ~/.pi/agent into the kit as kit content (files/home/.pi/agent).
#
# auth.json is excluded on purpose: it holds real OAuth tokens on your Mac, and
# kit content is baked in at create. The engine writes the in-container
# auth.json from the credential bindings, with sentinels — never a real secret.
set -e

kit=$(dirname "$(realpath "$0")")
src="$HOME/.pi/agent"
dst="$kit/files/home/.pi/agent"
parent=$(dirname "$dst")
started=$(date +%s)

[ -f "$kit/spec.yaml" ] || { echo "no spec.yaml in $kit; refusing to sync" >&2; exit 1; }
[ -d "$src" ] || { echo "no $src — nothing to sync" >&2; exit 1; }

# Top-level entries that never become kit content. README.md ("What gets
# synced") gives the reason for each; AGENTS.md is copied below instead.
skip_top() {
  case $1 in
    auth.json | AGENTS.md | install | npm | git | bin | sessions | cache | \
      web-search-cache | mcp-cache.json | mcp-npx-cache.json | langfuse.json | \
      missions | claude-sdk | provider-failover-state.json | \
      .ruff_cache | .serena | tests | run-history.jsonl | settings_old.json | \
      settings.json.* | *.log | .DS_Store)
      return 0 ;;
  esac
  return 1
}

echo "== sync: $src -> $dst"

# Select top-level entries explicitly: tar's --exclude patterns are unanchored,
# so excluding "./bin" there would also drop every nested bin/ directory.
set --
skipped=
for path in "$src"/* "$src"/.[!.]* "$src"/..?*; do
  [ -e "$path" ] || [ -L "$path" ] || continue
  entry=${path##*/}
  if skip_top "$entry"; then
    skipped="$skipped $entry"
  else
    set -- "$@" "./$entry"
  fi
done
[ $# -gt 0 ] || { echo "nothing to copy from $src" >&2; exit 1; }
echo "   skipping:$skipped"

# Write into a staging directory and swap it in at the end, so the kit mirrors
# the host: files deleted or newly excluded on the host leave the kit too.
mkdir -p "$parent"
stage=$(mktemp -d "$parent/.agent.sync.XXXXXX")
status=$stage.status
old=
cleanup() {
  rm -rf "$stage" "$status"
  [ -z "$old" ] || rm -rf "$old"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# auth.json and .DS_Store are also dropped at any depth. A pipeline reports
# only its last command, so the archiver leaves a marker when it succeeds.
(cd "$src" && tar cf - --exclude=auth.json --exclude=.DS_Store "$@" && echo ok > "$status") |
  (cd "$stage" && tar xf -)
[ -s "$status" ] || { echo "reading $src failed (tar errors above); aborting without touching the kit" >&2; exit 1; }
echo "   copied $(find "$stage" -mindepth 1 | wc -l | tr -d ' ') entries"

# AGENTS.md is usually a symlink to the shared ~/.agents/AGENTS.md on the
# host. The kit engine rejects symlinks that resolve outside the artifact, so
# bake the target's bytes as a regular file instead of copying the link.
agents="$src/AGENTS.md"
if [ -L "$agents" ] && [ ! -e "$agents" ]; then
  echo "AGENTS.md is a broken symlink ($(readlink "$agents")); fix or remove it" >&2
  exit 1
fi
if [ -f "$agents" ]; then
  cp -L "$agents" "$stage/AGENTS.md"
  echo "   AGENTS.md: copied as a regular file"
fi

# Paths into the host's agent directory become paths into the sandbox's
# (/home/agent/.pi/agent: the agent user's home per kit spec v2 §9.1), e.g.
# pi-blitz-handoff's recoveryDirectory. Project paths are left alone because
# sbx mounts workspaces at their host paths.
sandbox_agent=/home/agent/.pi/agent
host_pattern=$(printf '%s' "$src" | sed 's/[][\.*^$|]/\\&/g')
grep -rlF --include='*.json' "$src" "$stage" |
  while IFS= read -r file; do
    sed "s|$host_pattern|$sandbox_agent|g" "$file" > "$file.rewrite"
    cat "$file.rewrite" > "$file" # keeps the file's mode
    rm -f "$file.rewrite"
    echo "   rewrote host agent paths: ${file#"$stage"/}"
  done

# MCP servers: keep what can start in the Linux sandbox. Remote (url) servers
# stay. A stdio server stays when its command is one the image ships and its
# command line points into no macOS-only path; the rest (host apps and
# binaries) are dropped from the kit's copy, never from the host file. uvx
# becomes `uv tool run`: the image has uv but not the uvx alias.
mcp="$stage/mcp.json"
if [ -f "$mcp" ]; then
  command -v jq >/dev/null 2>&1 || { echo "jq is required to adapt mcp.json" >&2; exit 1; }
  # shellcheck disable=SC2016 # $command is a jq variable, not a shell one
  mcp_defs='
    def runnable: ["npx", "node", "npm", "sh", "bash", "python3", "uv", "uvx"];
    def host_path: test("(^|[\\s\"=])(/Users/|/Applications/|/opt/homebrew/|/Library/|/System/)");
    def verdict:
      (.command // "") as $command
      | if (.url? // null) != null then "keep"
      elif (runnable | index($command)) == null
        then "command \(if $command == "" then "(none)" else $command end) is not in the sandbox image"
      elif ([.command, (.args // [])[]] | map(strings | select(host_path)) | length) > 0
        then "its command line uses a macOS path"
      else "keep" end;'
  if ! jq empty "$mcp" 2>/dev/null; then
    echo "   warning: mcp.json is not valid JSON; copied unchanged" >&2
  elif ! jq -e '.mcpServers | type == "object"' "$mcp" >/dev/null; then
    echo "   mcp.json: no mcpServers object; copied unchanged"
  else
    jq "$mcp_defs"'
      .mcpServers |= with_entries(
        select(.value | verdict == "keep")
        | if .value.command == "uvx"
          then .value.command = "uv" | .value.args = ["tool", "run"] + (.value.args // [])
          else . end)' "$mcp" > "$mcp.adapted"
    echo "   mcp.json: kept $(jq '.mcpServers | length' "$mcp.adapted") servers for the sandbox"
    jq -r "$mcp_defs"'
      .mcpServers | to_entries[] | (.value | verdict) as $v
      | select($v != "keep") | "     dropped \(.key) (\($v))"' "$mcp"
    cat "$mcp.adapted" > "$mcp"
    rm -f "$mcp.adapted"
  fi
fi

# Fail closed: a real token must never become kit content, whatever the
# selection above did: by file name, then by credential-shaped content.
if [ -n "$(find "$stage" -name auth.json -print | head -1)" ]; then
  echo "auth.json reached the staged kit content; aborting without touching the kit" >&2
  exit 1
fi
secret_shapes='sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|fc-[a-f0-9]{32}|BSA[A-Za-z0-9_-]{20,}|eyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{10,}\.|-----BEGIN [A-Z ]*PRIVATE KEY-----'
leaks=$(grep -rIlE "$secret_shapes" "$stage" || true)
if [ -n "$leaks" ]; then
  printf 'credential-shaped content in:\n%s\naborting without touching the kit\n' "$leaks" >&2
  exit 1
fi
echo "   auth.json and credential-shaped content: none in kit content (ok)"

# Swap: move the previous copy aside, put the new one in place, then delete
# the old one. A failure between the two moves restores the previous copy.
if [ -e "$dst" ] || [ -L "$dst" ]; then
  old="$parent/.agent.old.$$"
  mv "$dst" "$old"
fi
if ! mv "$stage" "$dst"; then
  [ -z "$old" ] || mv "$old" "$dst"
  old=
  echo "could not move the synced copy into $dst" >&2
  exit 1
fi

echo "== sync done in $(($(date +%s) - started))s"
