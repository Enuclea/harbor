#!/bin/sh
# Refreshes the vendored xterm.js used by Harbor's browser terminal.
# Versions are pinned; bump them deliberately and review the diff.
set -eu

XTERM_VERSION="6.0.0"
FIT_VERSION="0.11.0"

root="$(cd "$(dirname "$0")/.." && pwd)"
vendor="$root/Packages/HarborKit/Sources/HarborRemote/Resources/web/vendor"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cd "$work"
npm pack "@xterm/xterm@$XTERM_VERSION" "@xterm/addon-fit@$FIT_VERSION" >/dev/null
mkdir xterm fit
tar -xzf "xterm-xterm-$XTERM_VERSION.tgz" -C xterm
tar -xzf "xterm-addon-fit-$FIT_VERSION.tgz" -C fit

mkdir -p "$vendor"
cp xterm/package/lib/xterm.js "$vendor/xterm.js"
cp xterm/package/css/xterm.css "$vendor/xterm.css"
cp fit/package/lib/addon-fit.js "$vendor/addon-fit.js"
cp xterm/package/LICENSE "$vendor/LICENSE-xterm.txt"
cp fit/package/LICENSE "$vendor/LICENSE-addon-fit.txt" 2>/dev/null || cp xterm/package/LICENSE "$vendor/LICENSE-addon-fit.txt"
echo "Vendored xterm.js $XTERM_VERSION and addon-fit $FIT_VERSION into $vendor"
