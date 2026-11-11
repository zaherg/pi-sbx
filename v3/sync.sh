#!/bin/sh
# Refresh the shared synced configuration, then mirror it into this kit's
# build context. The v2 spec remains untouched.
set -e

kit=$(cd -P "$(dirname "$0")" && pwd)
"$kit/../sync.sh"

stage=$(mktemp -d "$kit/.files.sync.XXXXXX")
old=
cleanup() {
  rm -rf "$stage"
  [ -z "$old" ] || rm -rf "$old"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cp -R "$kit/../files/." "$stage/"

if [ -e "$kit/files" ] || [ -L "$kit/files" ]; then
  old="$kit/.files.old.$$"
  mv "$kit/files" "$old"
fi
if ! mv "$stage" "$kit/files"; then
  [ -z "$old" ] || mv "$old" "$kit/files"
  old=
  echo "could not move the synced copy into $kit/files" >&2
  exit 1
fi

echo "== v3 sync done: $kit/files"
