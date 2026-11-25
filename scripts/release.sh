#!/bin/zsh
set -euo pipefail
root=${0:A:h:h}
version=$(tr -d '\r\n' < "$root/VERSION")
out="$root/dist"
mkdir -p "$out"
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
"$root/ReviewApp/build.sh" "$stage/매일의 기도 편집 검토.app"
ln -s /Applications "$stage/Applications"
hdiutil create -ov -volname "Maeki Maker $version" -srcfolder "$stage" -format UDZO "$out/MaekiMaker-v$version.dmg"
hdiutil verify "$out/MaekiMaker-v$version.dmg"
print "$out/MaekiMaker-v$version.dmg"
