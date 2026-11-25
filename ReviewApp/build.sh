#!/bin/zsh
set -euo pipefail

source_dir=${0:A:h}
project_dir=${source_dir:h}
app_dir="${1:-$project_dir/매일의 기도 편집 검토.app}"
contents="$app_dir/Contents"
resources="$contents/Resources"
version=$(tr -d '\r\n' < "$project_dir/VERSION")
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 'VERSION must be MAJOR.MINOR.PATCH'
    exit 1
fi
mkdir -p "$contents/MacOS" "$resources/ReviewApp"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macos26.0 -framework AVKit \
    "$source_dir"/ReviewModel.swift "$source_dir"/ReviewApp.swift "$source_dir"/PrayerPreview.swift \
    "$source_dir"/ReleaseUpdates.swift "$source_dir"/SetupGuide.swift "$source_dir"/UpdateInstaller.swift \
    -o "$contents/MacOS/PrayerReview"
cp "$source_dir/Info.plist" "$contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$contents/Info.plist"
cp "$project_dir/build_prayer.py" "$project_dir/defaults.json" "$project_dir/매일의 기도 자동편집.command" "$project_dir/설치 및 권한 안내.txt" "$resources/"
cp "$source_dir"/{review_bridge,auto_prepare,caption_grouping,cut_analysis,progress_log}.py "$resources/ReviewApp/"
chmod +x "$resources/매일의 기도 자동편집.command"
codesign --force --sign "${MAEKI_SIGN_IDENTITY:--}" "$app_dir"
codesign --verify --strict "$app_dir"
print "$app_dir"
