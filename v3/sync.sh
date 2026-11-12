#!/bin/sh
# Refresh the shared synced configuration, then mirror it into this kit's
# build context. The v2 spec remains untouched.
set -e

kit=$(cd -P "$(dirname "$0")" && pwd)
"$kit/../sync.sh"

rm -rf "$kit/files"
cp -R "$kit/../files" "$kit/files"

echo "== v3 sync done: $kit/files"
