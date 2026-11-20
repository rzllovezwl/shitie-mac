#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_app="${1:?请指定已通过公证并附加票据的应用路径}"
source_app="${source_app:A}"
app_info="$source_app/Contents/Info.plist"
if [[ ! -f "$app_info" ]]; then
    print -u2 "找不到应用：$source_app"
    exit 1
fi

build_number=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app_info")
output_dir="${2:-$project_root/dist/github/$build_number}"
output_dir="${output_dir:A}"
if [[ -e "$output_dir" ]]; then
    print -u2 "目标已存在，不会覆盖：$output_dir"
    exit 1
fi

/usr/bin/python3 "$project_root/Tools/ValidateReleaseHistory.py" \
    "$project_root/ClipboardShelf/Info.plist" \
    "$project_root/ClipboardShelf/Resources/ReleaseHistory.json"
/usr/bin/python3 - "$project_root" "$source_app" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path

root, app = map(Path, sys.argv[1:])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
source = plistlib.loads((root / "ClipboardShelf/Info.plist").read_bytes())
for key in ("CFBundleVersion", "CFBundleShortVersionString"):
    assert info[key] == source[key], f"应用与源码版本不一致：{key}"
assert info["CFBundleIdentifier"] == "com.renzhenglin.shitie.dev"
assert info["LSMinimumSystemVersion"] == "14.0"
binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
archs = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).split()
assert set(archs) == {"arm64", "x86_64"}, "必须同时包含 Apple 芯片和 Intel 架构"
signature = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(app)],
                           capture_output=True, text=True, check=True).stderr
assert "Authority=Developer ID Application:" in signature, "需要 Developer ID Application 签名"
assert "TeamIdentifier=526XL62KAS" in signature, "签名团队不匹配"
assert "runtime" in signature and "Timestamp=" in signature
entitlements = plistlib.loads(subprocess.check_output(
    ["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(app)], stderr=subprocess.DEVNULL))
assert not entitlements.get("com.apple.security.get-task-allow"), "不可分发调试权限"
assert (app / "Contents/Resources/ReleaseHistory.json").read_bytes() == \
       (root / "ClipboardShelf/Resources/ReleaseHistory.json").read_bytes()
print("分发配置核验通过：双架构、版本、Developer ID、强化运行时和版本记录")
PY

/usr/bin/codesign --verify --deep --strict "$source_app"
/usr/bin/xcrun stapler validate "$source_app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$source_app"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ClipHoookGitHubPackage.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
archive_name="ClipHoook-dev-$build_number-universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$source_app" "$work_dir/$archive_name"
/usr/bin/unzip -tq "$work_dir/$archive_name"
/usr/bin/ditto -x -k "$work_dir/$archive_name" "$work_dir/extracted"
extracted_app="$work_dir/extracted/${source_app:t}"
/usr/bin/codesign --verify --deep --strict "$extracted_app"
/usr/bin/xcrun stapler validate "$extracted_app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$extracted_app"

mkdir -p "$output_dir"
mv "$work_dir/$archive_name" "$output_dir/$archive_name"
(
    cd "$output_dir"
    /usr/bin/shasum -a 256 "$archive_name" > SHA256SUMS.txt
)
print "已生成并验证：$output_dir/$archive_name"
