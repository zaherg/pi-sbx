#!/bin/sh
# Mirror ~/.pi/agent into the kit as kit content (files/home/.pi/agent).
#
# auth.json is excluded on purpose: it holds real OAuth tokens on your Mac, and
# kit content is baked in at create. The engine writes the in-container
# auth.json from the credential bindings, with sentinels — never a real secret.
set -e

# Resolve $0 through symlinks so the kit is found next to the real script.
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
src="$HOME/.pi/agent"
dst="$kit/files/home/.pi/agent"
parent=$(dirname "$dst")
started=$(date +%s)

[ -f "$kit/spec.yaml" ] || { echo "no spec.yaml in $kit; refusing to sync" >&2; exit 1; }
[ -d "$src" ] || { echo "no $src — nothing to sync" >&2; exit 1; }

# Top-level entries that never become kit content:
#   auth.json            real OAuth tokens (the engine renders the sandbox copy)
#   AGENTS.md            copied below as a regular file (a symlink on the host)
#   install              host pi releases; the image ships its own pi
#   git                  managed package checkouts; pi clones them at startup
#   npm, bin             built for the host OS (macOS arm64): native addons and
#                        binaries that cannot run in the Linux sandbox. pi
#                        reinstalls the settings.json packages at startup and
#                        uses the image's fd/rg.
#   sessions, cache, web-search-cache, mcp-cache.json, mcp-npx-cache.json
#                        host history and caches; the MCP caches embed host paths
#   langfuse.json        tracing keys that no installed extension reads
#   missions, claude-sdk, provider-failover-state.json
#                        host work history and usage state (credential hashes)
#   .ruff_cache, .serena, tests
#                        host tooling for this directory
#   *.log, run-history.jsonl, settings_old.json, settings.json.*
#                        logs and backups
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

# Ownership is irrelevant here and restoring it fails when the destination is
# an NFS share under root-squash (or any dir you do not own). GNU and BSD tar
# both accept the flag; fall back to nothing if a tar does not.
xowner=""
tar --no-same-owner -cf /dev/null /dev/null 2>/dev/null && xowner="--no-same-owner"

# auth.json and .DS_Store are also dropped at any depth. The count mirrors the
# tar selection exactly, so the progress total is exact.
echo "   counting entries..."
entries=$(cd "$src" && find "$@" \( -name auth.json -o -name .DS_Store \) -prune -o -print |
  wc -l | tr -d ' ')
echo "   copying $entries entries"

# tar streams every entry name to stderr with -v. Fold that into one progress
# line per 5 percent and forward anything that is not a name (tar errors)
# as-is. The fd swap keeps the archive itself on stdout, straight into the
# extractor, while stderr goes to awk. A pipeline reports only its last
# command, so the archiver leaves a marker file when it exits cleanly.
{ (cd "$src" && tar cvf - --exclude=auth.json --exclude=.DS_Store "$@" && echo ok > "$status") 2>&1 1>&3 |
  awk -v total="$entries" '
    BEGIN { total += 0; step = int(total / 20); if (step < 1) step = 1 }
    /^(a |\.\/)/ {
      n++
      if (total > 0 && n % step == 0 && n != total) printf "   [%3d%%] %d/%d entries\n", n * 100 / total, n, total
      next
    }
    { print > "/dev/stderr" }
    END {
      if (total > 0 && n == total) printf "   [100%%] %d/%d entries\n", n, total
      else printf "   copied %d/%d entries\n", n, total
    }' >&2; } 3>&1 | (cd "$stage" && tar $xowner -xf -)
[ -s "$status" ] || { echo "reading $src failed (tar errors above); aborting without touching the kit" >&2; exit 1; }

# AGENTS.md is usually a symlink to the shared ~/.agents/AGENTS.md on the
# host. The kit engine rejects symlinks that resolve outside the artifact, so
# bake the target's bytes as a regular file instead of copying the link.
agents="$src/AGENTS.md"
if [ -L "$agents" ] && [ ! -e "$agents" ]; then
  echo "AGENTS.md is a broken symlink ($(readlink "$agents")); fix or remove it" >&2
  exit 1
fi
if [ -f "$agents" ]; then
  bytes=$(wc -c < "$agents" | tr -d ' ')
  if [ -L "$agents" ]; then
    echo "   AGENTS.md: following symlink $(readlink "$agents") -> regular file ($bytes bytes)"
  else
    echo "   AGENTS.md: regular file ($bytes bytes)"
  fi
  cp -L "$agents" "$stage/AGENTS.md"
fi

# Paths into the host's agent directory become paths into the sandbox's
# (/home/agent/.pi/agent: the agent user's home per kit spec v2 §9.1), e.g.
# pi-blitz-handoff's recoveryDirectory. Project paths are left alone because
# sbx mounts workspaces at their host paths.
sandbox_agent=/home/agent/.pi/agent
host_pattern=$(printf '%s' "$src" | sed 's/[][\.*^$|]/\\&/g')
find "$stage" -type f -name '*.json' |
  while IFS= read -r file; do
    grep -qF "$src" "$file" || continue
    if ! sed "s|$host_pattern|$sandbox_agent|g" "$file" > "$file.rewrite" ||
      ! cat "$file.rewrite" > "$file"; then
      echo "could not rewrite host paths in ${file#"$stage"/}" >&2
      exit 1
    fi
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
    dropped=$(jq -r "$mcp_defs"'
      .mcpServers | to_entries[] | (.value | verdict) as $v
      | select($v != "keep") | "\(.key) (\($v))"' "$mcp")
    jq "$mcp_defs"'
      .mcpServers |= with_entries(
        select(.value | verdict == "keep")
        | if .value.command == "uvx"
          then .value.command = "uv" | .value.args = ["tool", "run"] + (.value.args // [])
          else . end)' "$mcp" > "$mcp.adapted"
    cat "$mcp.adapted" > "$mcp"
    rm -f "$mcp.adapted"
    echo "   mcp.json: kept $(jq '.mcpServers | length' "$mcp") servers for the sandbox"
    printf '%s\n' "$dropped" | while IFS= read -r line; do
      [ -z "$line" ] || echo "     dropped $line"
    done
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
