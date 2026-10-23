#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
"$(dirname "$0")/make-app.sh"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R HIFConverter.app "$stage/"
ln -s /Applications "$stage/Applications"
rm -f HIFConverter.dmg
diskutil image create from --format UDZO --volumeName "HIF Converter" "$stage" HIFConverter.dmg
echo "built HIFConverter.dmg"
