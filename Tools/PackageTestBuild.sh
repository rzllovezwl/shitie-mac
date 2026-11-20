#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_app="$project_root/build/ClipHoook测试版.app"

if [[ ! -d "$source_app" ]]; then
    print -u2 "请先用 Xcode 构建 ClipHoook测试版。"
    exit 1
fi
build_number=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$source_app/Contents/Info.plist")
destination_app="${1:-$project_root/build/ClipHoook测试版-$build_number.app}"
if [[ -e "$destination_app" ]]; then
    print -u2 "目标已存在，不会覆盖：$destination_app"
    exit 1
fi

zsh "$project_root/Tools/VerifyTestBuild.sh" "$source_app"
ditto "$source_app" "$destination_app"
codesign --verify --deep --strict "$destination_app"
print "已打包 $destination_app（构建 $build_number）"
