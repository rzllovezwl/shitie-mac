#!/bin/zsh
# Render current app views with disposable demo data, without changing app sources.
set -euo pipefail
project_root="${0:A:h:h}"
source_app="$project_root/build/ClipHoook测试版.app"
if [[ ! -f "$source_app/Contents/Resources/Assets.car" ]]; then
    print -u2 "请先构建当前开发版，以取得同版图标资源。"
    exit 1
fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/ClipHoookReadme.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
bundle="$scratch/ClipHoookRepositoryArtwork.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

python3 - "$project_root" "$scratch" "$bundle" <<'PY'
from pathlib import Path
import plistlib, sys
root, scratch, bundle = map(Path, sys.argv[1:])
app = (root / "ClipboardShelf/App/ClipboardShelfApp.swift").read_text()
assert app.count("@main\n") == 1
(scratch / "ClipboardShelfApp.swift").write_text(app.replace("@main\n", "", 1))
controller = (root / "ClipboardShelf/App/AppController.swift").read_text()
old = "static let shared = AppController(store: ClipboardHistoryStore())"
new = '''static let shared = AppController(store: ClipboardHistoryStore(directory:
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLIPHOOOK_ARTWORK_DIR"]!)
        .appendingPathComponent("history")))'''
assert controller.count(old) == 1
controller = controller.replace(old, new, 1)
controller += '''
extension AppController {
    func configureRepositoryPhoneFixture() {
        phoneScreenshotReceivingEnabled = true
        phoneScreenshotReceiverStatus = "已就绪，等待 iPhone 截图"
        phoneScreenshotEndpoint = "http://demo-mac.local:52781/v1/screenshot/00000000000000000000000000000000"
        phoneScreenshotSetupAddress = "http://demo-mac.local:52781/v1/setup/00000000000000000000000000000000"
    }
}
'''
(scratch / "AppController.swift").write_text(controller)
settings = (root / "ClipboardShelf/Settings/SettingsWindowController.swift").read_text()
settings += '''
@MainActor func repositoryPhoneGuide(model: AppController) -> AnyView {
    AnyView(PhoneScreenshotGuideView(model: model, close: {}).preferredColorScheme(.light))
}
'''
(scratch / "SettingsWindowController.swift").write_text(settings)
# The appended fixture lives in the same temporary file as the private renderer.
# All shapes still use the app's real annotation geometry and drawing code.
annotation = (root / "ClipboardShelf/Services/MacScreenshotAnnotations.swift").read_text()
annotation += '''
@MainActor func repositoryAnnotationDocument() throws -> Data {
    let box = ScreenshotArrowBox(tail: CGPoint(x: 1030, y: 180),
        rect: CGRect(x: 110, y: 450, width: 625, height: 70),
        arrowWidth: 5, arrowScale: 1, rectangleWidth: 3, rectangleRadius: 9)
    let annotations: [ScreenshotAnnotation] = [
        .colored(.arrowBox(box), .blue),
        .colored(.styledRectangleWithRadius(CGRect(x: 120, y: 350, width: 530, height: 65),
            style: .discard, width: 2, radius: 8), .red),
        .colored(.number(CGPoint(x: 950, y: 560), 1, 46), .blue)
    ]
    return try JSONEncoder().encode(ScreenshotAnnotationDocument(version: 10,
        imageWidth: 1200, imageHeight: 760, annotations: annotations))
}
'''
(scratch / "MacScreenshotAnnotations.swift").write_text(annotation)
info = {"CFBundleIdentifier": "local.cliphoook.repository-artwork", "CFBundleExecutable": "RepositoryArtwork",
        "CFBundleName": "ClipHoook Repository Artwork", "CFBundlePackageType": "APPL", "LSUIElement": True}
(bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
PY

sources=()
for file in "$project_root"/ClipboardShelf/**/*.swift(.N); do
    case "$file" in
        */App/ClipboardShelfApp.swift|*/App/AppController.swift|*/Services/MacScreenshotAnnotations.swift|*/Settings/SettingsWindowController.swift) ;;
        *) sources+=("$file") ;;
    esac
done
swiftc -parse-as-library -D DEBUG -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "$scratch/ModuleCache" "${sources[@]}" \
    "$scratch/ClipboardShelfApp.swift" "$scratch/AppController.swift" \
    "$scratch/MacScreenshotAnnotations.swift" "$scratch/SettingsWindowController.swift" \
    "$project_root/Tools/RepositoryScreenshots/main.swift" \
    -lsqlite3 -Xlinker -weak_framework -Xlinker Translation \
    -Xlinker -weak_framework -Xlinker _Translation_SwiftUI \
    -o "$bundle/Contents/MacOS/RepositoryArtwork"
cp "$source_app/Contents/Resources/Assets.car" "$bundle/Contents/Resources/"
cp "$project_root/ClipboardShelf/Resources/ReleaseHistory.json" "$bundle/Contents/Resources/"
CLIPHOOOK_ARTWORK_DIR="$scratch/demo" "$bundle/Contents/MacOS/RepositoryArtwork" "$project_root" "$@"
