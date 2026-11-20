#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_app="${1:-$project_root/build/ClipHoook测试版.app}"

if [[ ! -d "$source_app" ]]; then
    print -u2 "请先构建 ClipHoook测试版：$source_app"
    exit 1
fi

/usr/bin/python3 "$project_root/Tools/ValidateReleaseHistory.py" \
    "$project_root/ClipboardShelf/Info.plist" \
    "$project_root/ClipboardShelf/Resources/ReleaseHistory.json"

source_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_root/ClipboardShelf/Info.plist")
source_build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$project_root/ClipboardShelf/Info.plist")
app_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source_app/Contents/Info.plist")
app_build=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$source_app/Contents/Info.plist")
app_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")
if [[ "$source_version" != "$app_version" || "$source_build" != "$app_build" ]]; then
    print -u2 "构建产物版本与源码不一致（源码 $source_version/$source_build，产物 $app_version/$app_build）；请重新构建。"
    exit 1
fi
if [[ "$app_bundle_id" != "com.renzhenglin.shitie.dev" ]]; then
    print -u2 "这不是测试版 Bundle ID：$app_bundle_id"
    exit 1
fi
if ! cmp -s "$project_root/ClipboardShelf/Resources/ReleaseHistory.json" \
    "$source_app/Contents/Resources/ReleaseHistory.json"; then
    print -u2 "应用包内版本记录与源码不一致，请重新构建。"
    exit 1
fi

signature=$(codesign -dv --verbose=2 "$source_app" 2>&1)
team_id=$(print -r -- "$signature" | sed -n 's/^TeamIdentifier=//p')
if [[ -z "$team_id" || "$team_id" == "not set" ]]; then
    print -u2 "测试包缺少开发者团队签名；请勿用临时签名重签。"
    exit 1
fi
codesign --verify --deep --strict "$source_app"

# A lowered deployment target is insufficient if a newer framework is still
# loaded unconditionally before main(). Check the shipped Mach-O, too.
/usr/bin/python3 - "$source_app" <<'PY'
import plistlib
from pathlib import Path
import re
import subprocess
import sys

app = Path(sys.argv[1])
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["LSMinimumSystemVersion"] == "14.0", "测试包最低系统应为 macOS 14.0"
binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
commands = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True)
builds = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \S+\s+minos (\S+)", commands)
assert builds and all(value == "14.0" for value in builds), "Mach-O 部署目标与 Sonoma 支持不一致"
for command in commands.split("Load command"):
    if "/Translation.framework/" in command or "/_Translation_SwiftUI.framework/" in command:
        assert "cmd LC_LOAD_WEAK_DYLIB" in command, "旧系统可能缺失的翻译框架必须弱链接"
print("Sonoma binary compatibility checks passed: minimum OS and weak framework loading")
PY

/usr/bin/python3 - "$source_app" <<'PY'
import plistlib, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1])
host = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert not list(app.rglob("*.appex")), "已移除的小组件扩展仍残留在产物中，请重新构建干净的应用包"
assert "WidgetAppGroupIdentifier" not in host and "WidgetURLScheme" not in host
assert not host.get("CFBundleURLTypes"), "已移除的小组件 URL 仍被注册"
raw = subprocess.check_output(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(app)], stderr=subprocess.DEVNULL)
entitlement = plistlib.loads(raw)
assert not entitlement.get("com.apple.security.application-groups"), "产物不应申请小组件共享目录权限"
binary = app / "Contents/MacOS" / host["CFBundleExecutable"]
linked = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
assert "/WidgetKit.framework/" not in linked, "主应用不应再链接 WidgetKit"
print("Removed widget checks passed: no extension, App Group, URL registration or WidgetKit dependency")
PY

check_dir=$(mktemp -d "${TMPDIR:-/tmp}/ClipHoookVerify.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT
module_cache="$check_dir/ModuleCache"
cd "$project_root"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Services/CopySoundPlayer.swift Tests/CopySoundSmoke.swift \
    -o "$check_dir/copy-sound"
"$check_dir/copy-sound" "$source_app"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ReleaseHistory.swift Tests/ReleaseHistorySmoke.swift \
    -o "$check_dir/release-history"
"$check_dir/release-history" "$source_app"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/AppShortcut.swift ClipboardShelf/Views/ShelfKeyboard.swift \
    ClipboardShelf/Services/GlobalHotKey.swift \
    Tests/Stage1KeyboardSmoke.swift -o "$check_dir/edit-shortcut"
"$check_dir/edit-shortcut"

/usr/bin/python3 - "$project_root" "$check_dir/TextEditorSession.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Panel/PanelController.swift").read_text()
start = source.index("private final class ClipboardTextEditorPanel")
end = source.index("\n}\n", start) + len("\n}\n")
editor = "import AppKit\n" + source[start:end]
test = (root / "Tests/TextEditorSessionSmoke.swift").read_text()
Path(sys.argv[2]).write_text(editor + "\n" + test)
PY
swiftc -parse-as-library -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    "$check_dir/TextEditorSession.swift" -o "$check_dir/text-editor-session"
"$check_dir/text-editor-session"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Services/PasteTargetFocus.swift Tests/PasteTargetWindowSmoke.swift \
    -o "$check_dir/paste-target"
"$check_dir/paste-target"

# Test the production pin and its controls with an invisible synthetic panel.
/usr/bin/python3 - "$project_root" "$check_dir/PinnedImageGeometry.swift" <<'PY_PIN'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Panel/PinnedImageWindowManager.swift").read_text()
end = source.index("/// One borderless, nonactivating floating panel per pinned image.")
test = (root / "Tests/PinnedImageGeometrySmoke.swift").read_text()
Path(sys.argv[2]).write_text(source[:end] + test)
PY_PIN
swiftc -parse-as-library -module-cache-path "$module_cache" \
    ClipboardShelf/Services/PinnedImageStore.swift ClipboardShelf/Services/PasteTargetFocus.swift \
    "$check_dir/PinnedImageGeometry.swift" -o "$check_dir/pinned-image-geometry"
"$check_dir/pinned-image-geometry"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/ClipboardQuickSearch.swift \
    ClipboardShelf/Services/PasteTargetFocus.swift Tests/QuickSearchSmoke.swift \
    -o "$check_dir/quick-search"
"$check_dir/quick-search"

# Exercise the actual paste routing with inert endpoints, without changing
# the user's clipboard, launching apps, posting keys or opening file dialogs.
/usr/bin/python3 - "$project_root" "$check_dir/QuickSearchPaste.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/App/AppController.swift").read_text()
start = source.index("    private func paste(_ selected: [ClipboardEntry]")
end = source.index("    private func endPasteHandoff(", start)
methods = source[start:end]
assert methods.count("NSPasteboard.general.changeCount") == 1
methods = methods.replace("NSPasteboard.general.changeCount", "0")
search = (root / "ClipboardShelf/Model/ClipboardQuickSearch.swift").read_text()
context = search[search.index("@MainActor\nstruct QuickSearchPasteContext"):]
context = context.replace("struct QuickSearchPasteContext", "private struct QuickSearchPasteContext", 1)
fixture = (root / "Tests/QuickSearchPasteSmoke.swift").read_text()
Path(sys.argv[2]).write_text(fixture.replace("    // INSERT_PRODUCTION_PASTE_ROUTING", methods)
    .replace("// INSERT_PRODUCTION_SEARCH_CONTEXT", context)
    .replace("NSRunningApplication", "SearchTestApplication"))
PY
swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    "$check_dir/QuickSearchPaste.swift" -o "$check_dir/quick-search-paste"
"$check_dir/quick-search-paste"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Services/PhoneScreenshotHTTPParser.swift \
    ClipboardShelf/Services/PhoneScreenshotReceiver.swift \
    Tests/PhoneScreenshotTransportSmoke.swift \
    -o "$check_dir/phone-transport"
"$check_dir/phone-transport"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ScreenRecordingState.swift \
    ClipboardShelf/Services/MacScreenshotCapture.swift \
    Tests/MacScreenshotGeometrySmoke.swift \
    -o "$check_dir/screenshot-geometry"
"$check_dir/screenshot-geometry"

swiftc -O -module-cache-path "$module_cache" \
    ClipboardShelf/Services/LongScreenshotStitcher.swift Tests/LongScreenshotSmoke.swift \
    -o "$check_dir/long-screenshot"
"$check_dir/long-screenshot"

/usr/bin/python3 - "$project_root" "$check_dir/ScreenshotCursor.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Services/MacScreenshotCapture.swift").read_text()
test = (root / "Tests/ScreenshotCursorSmoke.swift").read_text()
Path(sys.argv[2]).write_text(source + "\n" + test)
PY
swiftc -parse-as-library -module-cache-path "$module_cache" \
    ClipboardShelf/Model/AppShortcut.swift \
    ClipboardShelf/Model/ScreenRecordingState.swift \
    "$check_dir/ScreenshotCursor.swift" -o "$check_dir/screenshot-cursor"
"$check_dir/screenshot-cursor"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    Tests/ClipboardFilterSmoke.swift \
    -o "$check_dir/clipboard-filter"
"$check_dir/clipboard-filter"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/HistoryStoragePolicy.swift \
    ClipboardShelf/Services/ClipboardBatchCapture.swift \
    ClipboardShelf/Services/ClipboardImageCapture.swift \
    ClipboardShelf/Services/ClipboardHistoryDatabase.swift \
    ClipboardShelf/Services/ClipboardHistoryStore.swift \
    ClipboardShelf/Services/ClipboardPasteboardWriter.swift \
    ClipboardShelf/Services/TextPreviewRenderer.swift \
    Tests/ClipboardCalendarSmoke.swift \
    -lsqlite3 -o "$check_dir/clipboard-calendar"
"$check_dir/clipboard-calendar"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/HistoryStoragePolicy.swift \
    ClipboardShelf/Model/RecordingExclusionPolicy.swift \
    ClipboardShelf/Services/ClipboardBatchCapture.swift \
    ClipboardShelf/Services/ClipboardImageCapture.swift \
    ClipboardShelf/Services/ClipboardHistoryDatabase.swift \
    ClipboardShelf/Services/ClipboardHistoryStore.swift \
    ClipboardShelf/Services/TextPreviewRenderer.swift \
    Tests/StorageSmoke.swift \
    -lsqlite3 -o "$check_dir/storage"
"$check_dir/storage"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/HistoryStoragePolicy.swift \
    ClipboardShelf/Services/ClipboardBatchCapture.swift \
    ClipboardShelf/Services/ClipboardImageCapture.swift \
    ClipboardShelf/Services/ClipboardHistoryDatabase.swift \
    ClipboardShelf/Services/ClipboardHistoryStore.swift \
    ClipboardShelf/Services/TextPreviewRenderer.swift \
    Tests/ClipboardFavoritesSmoke.swift \
    -lsqlite3 -o "$check_dir/clipboard-favorites"
"$check_dir/clipboard-favorites"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/HistoryStoragePolicy.swift \
    ClipboardShelf/Services/ClipboardBatchCapture.swift \
    ClipboardShelf/Services/ClipboardImageCapture.swift \
    ClipboardShelf/Services/ClipboardHistoryDatabase.swift \
    ClipboardShelf/Services/ClipboardHistoryStore.swift \
    ClipboardShelf/Services/TextPreviewRenderer.swift \
    Tests/CardReorderingSmoke.swift \
    -lsqlite3 -o "$check_dir/card-reordering"
"$check_dir/card-reordering"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/HistoryStoragePolicy.swift \
    ClipboardShelf/Model/StagingShelfItem.swift \
    ClipboardShelf/Services/ClipboardBatchCapture.swift \
    ClipboardShelf/Services/ClipboardImageCapture.swift \
    ClipboardShelf/Services/ClipboardHistoryDatabase.swift \
    ClipboardShelf/Services/ClipboardHistoryStore.swift \
    ClipboardShelf/Services/TextPreviewRenderer.swift \
    ClipboardShelf/Services/StagingShelfStore.swift \
    ClipboardShelf/Model/AppShortcut.swift \
    Tests/StagingShelfSmoke.swift \
    -lsqlite3 -o "$check_dir/staging-shelf"
"$check_dir/staging-shelf"

/usr/bin/python3 - "$project_root" "$check_dir/StagingShelfVisibility.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Panel/StagingShelfController.swift").read_text()
# Permit a presentation-only fixture; controller/drop logic is unchanged.
source = source.replace("private final class StagingShelfPanel: NSPanel", "private class StagingShelfPanel: NSPanel")
source = source.replace("private final class StagingShelfPreviewPanel: NSPanel", "private class StagingShelfPreviewPanel: NSPanel")
test = (root / "Tests/StagingShelfVisibilitySmoke.swift").read_text()
card = (root / "ClipboardShelf/Views/ClipboardCardView.swift").read_text()
gesture = card[card.index("class ContentDragGestureRecognizer:"):card.index("class CardInteractionView:")]
Path(sys.argv[2]).write_text(source + "\n" + gesture + "\n" + test)
PY
swiftc -parse-as-library -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/HistoryStoragePolicy.swift \
    ClipboardShelf/Model/StagingShelfItem.swift \
    ClipboardShelf/Panel/PanelLayout.swift \
    ClipboardShelf/Services/ClipboardBatchCapture.swift \
    ClipboardShelf/Services/ClipboardImageCapture.swift \
    ClipboardShelf/Services/ClipboardHistoryDatabase.swift \
    ClipboardShelf/Services/ClipboardHistoryStore.swift \
    ClipboardShelf/Services/TextPreviewRenderer.swift \
    ClipboardShelf/Services/StagingShelfStore.swift \
    ClipboardShelf/Model/AppShortcut.swift \
    "$check_dir/StagingShelfVisibility.swift" \
    -lsqlite3 -o "$check_dir/staging-shelf-visibility"
"$check_dir/staging-shelf-visibility"

# Use the real controller copy methods and store, with a named pasteboard and
# isolated history directory. The user's clipboard and existing history are untouched.
/usr/bin/python3 - "$project_root" "$check_dir/DerivedTextCopy.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
controller = (root / "ClipboardShelf/App/AppController.swift").read_text()
methods = controller[controller.index("    func copyRecognizedText(_ text:"):
                     controller.index("    func canPinImage(")]
assert methods.count("let board = NSPasteboard.general") == 1
methods = methods.replace("let board = NSPasteboard.general", "let board = testPasteboard")
fixture = (root / "Tests/DerivedTextCopySmoke.swift").read_text()
Path(sys.argv[2]).write_text(fixture.replace("    // INSERT_PRODUCTION_TEXT_COPY_METHODS", methods))
PY
swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/HistoryStoragePolicy.swift \
    ClipboardShelf/Services/ClipboardBatchCapture.swift \
    ClipboardShelf/Services/ClipboardImageCapture.swift \
    ClipboardShelf/Services/ClipboardHistoryDatabase.swift \
    ClipboardShelf/Services/ClipboardHistoryStore.swift \
    ClipboardShelf/Services/ClipboardChangeTracker.swift \
    ClipboardShelf/Services/TextPreviewRenderer.swift \
    "$check_dir/DerivedTextCopy.swift" \
    -lsqlite3 -o "$check_dir/derived-text-copy"
"$check_dir/derived-text-copy"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/AppShortcut.swift ClipboardShelf/Views/ShelfKeyboard.swift \
    ClipboardShelf/Services/GlobalHotKey.swift \
    Tests/ShortcutSmoke.swift -o "$check_dir/shortcuts"
"$check_dir/shortcuts"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Panel/PanelLayout.swift Tests/PanelCardDragSmoke.swift \
    -o "$check_dir/panel-card-drag"
"$check_dir/panel-card-drag"

# Exercise the real shelf selection methods, without hosting the full app.
/usr/bin/python3 - "$project_root" "$check_dir/ShelfSelection.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Views/ShelfView.swift").read_text()
methods = source[source.index("    private func select(\n"):source.index("    private func toggleGroup(")]
methods += source[source.index("    private func selectForContextMenu("):source.index("    private func contextSelection(")]
methods += source[source.index("    private func moveSelection(by offset: Int)"):source.index("\n}\n\nprivate extension ClipboardFavoriteCategory.Tint")]
test = (root / "Tests/ShelfSelectionSmoke.swift").read_text()
Path(sys.argv[2]).write_text(test.replace("    // PRODUCTION_SELECTION_METHODS", methods))
PY
swiftc -parse-as-library -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ClipboardEntry.swift \
    ClipboardShelf/Model/ClipboardTextClassification.swift \
    "$check_dir/ShelfSelection.swift" -o "$check_dir/shelf-selection"
"$check_dir/shelf-selection"

# Exercise the shelf backdrop and drag views without reading the clipboard or showing a window.
/usr/bin/python3 - "$project_root" \
    "$check_dir/CardInteractionView.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1]) / "ClipboardShelf"
card = (root / "Views/ClipboardCardView.swift").read_text()
panel = (root / "Panel/PanelController.swift").read_text()
surface = panel[panel.index("final class ShelfPanelSurface: NSView {"):
                panel.index("private final class ShelfHostingView:")]
Path(sys.argv[2]).write_text("import AppKit\nimport ImageIO\n" + surface + card[card.index("final class CardReorderViewportView: NSView {"):])
PY
swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Model/AppShortcut.swift ClipboardShelf/Views/ShelfKeyboard.swift \
    ClipboardShelf/Services/GlobalHotKey.swift \
    "$check_dir/CardInteractionView.swift" Tests/CardDragLifecycleSmoke.swift \
    -o "$check_dir/card-drag-lifecycle"
"$check_dir/card-drag-lifecycle"

/usr/bin/python3 - "$project_root" "$check_dir/ScreenshotScanExport.swift" "$check_dir/ScreenshotArrow.swift" "$check_dir/ScreenshotText.swift" "$check_dir/ScreenshotCrop.swift" "$check_dir/ScreenshotElementClipboard.swift" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Services/MacScreenshotAnnotations.swift").read_text()
icons = (root / "ClipboardShelf/Views/LucideIcon.swift").read_text()
definitions = source[:source.index("private struct ScreenshotTextMessageView:")]
canvas = source[source.index("private final class ScreenshotAnnotationCanvas:"):
                source.index("private final class ScreenshotAnnotationOverlayPanel:")]
icon_enum = icons[icons.index("enum LucideSymbol:"):icons.index("extension ClipboardEntry.Kind")]
test = (root / "Tests/ScreenshotScanExportSmoke.swift").read_text()
Path(sys.argv[2]).write_text(definitions + icon_enum + canvas + test)
arrow_test = (root / "Tests/ScreenshotArrowSmoke.swift").read_text()
Path(sys.argv[3]).write_text(definitions + icon_enum + canvas + arrow_test)
text_test = (root / "Tests/ScreenshotTextSmoke.swift").read_text()
Path(sys.argv[4]).write_text(definitions + icon_enum + canvas + text_test)
crop_test = (root / "Tests/ScreenshotCropSmoke.swift").read_text()
Path(sys.argv[5]).write_text(definitions + icon_enum + canvas + crop_test)
element_test = (root / "Tests/ScreenshotElementClipboardSmoke.swift").read_text()
Path(sys.argv[6]).write_text(definitions + icon_enum + canvas + element_test)
PY
swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Views/ScanLoadingView.swift ClipboardShelf/Views/ZoomableImageView.swift \
    ClipboardShelf/Model/ScreenRecordingState.swift \
    ClipboardShelf/Services/MacScreenshotCapture.swift \
    ClipboardShelf/Model/AppShortcut.swift \
    "$check_dir/ScreenshotScanExport.swift" -o "$check_dir/screenshot-scan-export"
"$check_dir/screenshot-scan-export"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Views/ScanLoadingView.swift ClipboardShelf/Views/ZoomableImageView.swift \
    ClipboardShelf/Model/ScreenRecordingState.swift \
    ClipboardShelf/Services/MacScreenshotCapture.swift \
    ClipboardShelf/Model/AppShortcut.swift \
    "$check_dir/ScreenshotArrow.swift" -o "$check_dir/screenshot-arrow"
"$check_dir/screenshot-arrow"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Views/ScanLoadingView.swift ClipboardShelf/Views/ZoomableImageView.swift \
    ClipboardShelf/Model/ScreenRecordingState.swift \
    ClipboardShelf/Services/MacScreenshotCapture.swift \
    ClipboardShelf/Model/AppShortcut.swift \
    "$check_dir/ScreenshotText.swift" -o "$check_dir/screenshot-text"
"$check_dir/screenshot-text"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Views/ScanLoadingView.swift ClipboardShelf/Views/ZoomableImageView.swift \
    ClipboardShelf/Model/ScreenRecordingState.swift \
    ClipboardShelf/Services/MacScreenshotCapture.swift ClipboardShelf/Model/AppShortcut.swift \
    "$check_dir/ScreenshotCrop.swift" -o "$check_dir/screenshot-crop"
"$check_dir/screenshot-crop"

swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Views/ScanLoadingView.swift ClipboardShelf/Views/ZoomableImageView.swift \
    ClipboardShelf/Model/ScreenRecordingState.swift \
    ClipboardShelf/Services/MacScreenshotCapture.swift ClipboardShelf/Model/AppShortcut.swift \
    "$check_dir/ScreenshotElementClipboard.swift" -o "$check_dir/screenshot-element-clipboard"
"$check_dir/screenshot-element-clipboard"

/usr/bin/python3 - "$project_root" "$check_dir/ScreenshotPenSticker.swift" <<'PY_PEN'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Services/MacScreenshotAnnotations.swift").read_text()
icons = (root / "ClipboardShelf/Views/LucideIcon.swift").read_text()
definitions = source[:source.index("private struct ScreenshotTextMessageView:")]
canvas = source[source.index("private final class ScreenshotAnnotationCanvas:"):source.index("private final class ScreenshotAnnotationOverlayPanel:")]
icon_enum = icons[icons.index("enum LucideSymbol:"):icons.index("extension ClipboardEntry.Kind")]
Path(sys.argv[2]).write_text(definitions + icon_enum + canvas + (root / "Tests/ScreenshotPenStickerSmoke.swift").read_text())
PY_PEN
swiftc -module-cache-path "$module_cache" \
    ClipboardShelf/Views/ScanLoadingView.swift ClipboardShelf/Views/ZoomableImageView.swift \
    ClipboardShelf/Model/ScreenRecordingState.swift \
    ClipboardShelf/Services/MacScreenshotCapture.swift ClipboardShelf/Model/AppShortcut.swift \
    "$check_dir/ScreenshotPenSticker.swift" -o "$check_dir/screenshot-pen-sticker"
"$check_dir/screenshot-pen-sticker"

/usr/bin/python3 - "$project_root" "$check_dir/ScreenshotToolbarLayout.swift" <<'PY_TOOLBAR'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Services/MacScreenshotAnnotations.swift").read_text()
component = source[source.index("private final class ScreenshotAnnotationToolbar:"):source.index("@MainActor\nfinal class MacScreenshotEditorController:")]
Path(sys.argv[2]).write_text("import AppKit\n" + component + (root / "Tests/ScreenshotToolbarLayoutSmoke.swift").read_text())
PY_TOOLBAR
swiftc -parse-as-library -module-cache-path "$module_cache" "$check_dir/ScreenshotToolbarLayout.swift" -o "$check_dir/screenshot-toolbar-layout"
"$check_dir/screenshot-toolbar-layout" "$source_app"

print "测试包检查通过：$app_version ($app_build)，团队 $team_id"

# Synthetic media only: no screen capture, microphone input or desktop control.
/usr/bin/python3 - "$project_root" "$check_dir/ScreenRecordingSmoke.swift" <<'PY_RECORDING'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / "ClipboardShelf/Views/ScreenRecordingViews.swift").read_text()
start = source.index("@MainActor\nprivate final class RecordingDraftEdits:")
end = source.index("private struct RecordingDraftResultView:", start)
model = source[start:end]
Path(sys.argv[2]).write_text("import AVKit\nimport SwiftUI\n" + model + (root / "Tests/ScreenRecordingSmoke.swift").read_text())
PY_RECORDING
swiftc -parse-as-library -module-cache-path "$module_cache" \
    ClipboardShelf/Model/ScreenRecordingState.swift ClipboardShelf/Services/ScreenRecordingWriter.swift \
    ClipboardShelf/Services/ScreenRecordingDraftStore.swift \
    ClipboardShelf/Model/ClipboardEntry.swift ClipboardShelf/Model/ClipboardTextClassification.swift \
    ClipboardShelf/Model/HistoryStoragePolicy.swift ClipboardShelf/Services/ClipboardBatchCapture.swift \
    ClipboardShelf/Services/ClipboardImageCapture.swift ClipboardShelf/Services/ClipboardHistoryDatabase.swift \
    ClipboardShelf/Services/ClipboardHistoryStore.swift ClipboardShelf/Services/TextPreviewRenderer.swift \
    ClipboardShelf/Model/AppShortcut.swift "$check_dir/ScreenRecordingSmoke.swift" \
    -lsqlite3 -o "$check_dir/screen-recording"
"$check_dir/screen-recording"
