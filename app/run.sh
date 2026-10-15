#!/bin/sh
# Runs cli.mjs with the first JavaScript runtime found: the app's shell has
# almost no PATH, so the usual places are tried by name.
here="$(cd "$(dirname "$0")" && pwd)"
for js in /opt/homebrew/bin/node /usr/local/bin/node "$HOME/.bun/bin/bun" "$HOME"/.cache/magpie/bun/*/magpie-bun; do
  if [ -x "$js" ]; then
    exec "$js" "$here/cli.mjs" "$@"
  fi
done
echo "找不到 Node.js 或 Bun，请先安装 Node.js" >&2
exit 1
