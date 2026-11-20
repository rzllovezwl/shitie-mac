import AppKit

@MainActor
private final class ScreenshotMenuActionRecorder: NSObject {
    var chosen: [Int] = []
    @objc func choose(_ item: NSMenuItem) { chosen.append(item.tag) }
}

// Appended to the actual toolbar and button components, using hidden views.
@main struct ScreenshotToolbarLayoutSmoke {
    @MainActor static func main() {
        _ = NSApplication.shared
        for useNativeGlass in [true, false] {
            func button(_ width: CGFloat = 32) -> ScreenshotToolbarButton {
                let button = ScreenshotToolbarButton()
                button.title = ""
                button.isBordered = false
                button.widthAnchor.constraint(equalToConstant: width).isActive = true
                button.heightAnchor.constraint(equalToConstant: 34).isActive = true
                return button
            }
            func split() -> NSView {
                let group = ScreenshotToolbarSplitGroup(tool: button(), options: button(16))
                // Reproduce a stale stack frame before its first layout.
                group.frame = CGRect(x: 0, y: 0, width: 400, height: 34)
                return group
            }
            func group(_ views: [NSView]) -> NSStackView {
                let stack = NSStackView(views: views)
                stack.orientation = .horizontal
                stack.spacing = 2
                return stack
            }
            func divider() -> NSView {
                let view = NSView()
                view.widthAnchor.constraint(equalToConstant: 1).isActive = true
                view.heightAnchor.constraint(equalToConstant: 18).isActive = true
                return view
            }
            // Six common split tools, brush, discard, magnifier, number, advanced picker, palette,
            // OCR/translation/scroll and finishing actions.
            let items: [NSView] = (0..<6).map { _ in split() } + [
                button(), button(), split(), button(), split(), split(), divider(),
                group([button(), split(), button()]), divider(),
                group([button(), button(), button(), button()])
            ]
            let toolbar = ScreenshotAnnotationToolbar(items: items, useNativeGlass: useNativeGlass)
            let wide = toolbar.preferredSize(maxWidth: 1280)
            precondition(wide.width <= 870, "adding the discard button must keep the toolbar compact")
            let backdrop = toolbar.subviews.first { $0.identifier?.rawValue == "annotation-toolbar.material" }!
            let shadow = toolbar.subviews.first { $0.identifier?.rawValue == "annotation-toolbar.shadow" }!
            if #available(macOS 26.0, *), useNativeGlass {
                let glass = backdrop as! NSGlassEffectView
                precondition(glass.style == .clear && glass.cornerRadius == 12)
            } else {
                let frost = backdrop as! NSVisualEffectView
                precondition(frost.material == .popover && frost.blendingMode == .withinWindow)
            }
            var height: CGFloat = 0
            toolbar.onHeightChanged = { height = $0 }
            for width: CGFloat in [1280, 1024, 900, 800, 720, 640, 480, 320, 1280] {
                var size = toolbar.preferredSize(maxWidth: width)
                if width > 800 { size.width = width } // A wide image editor slot.
                toolbar.frame = CGRect(origin: .zero, size: size)
                toolbar.needsLayout = true
                toolbar.layoutSubtreeIfNeeded()
                precondition(height == size.height)
                let background = backdrop.convert(backdrop.bounds, to: toolbar)
                precondition(abs(background.midX - toolbar.bounds.midX) < 1 &&
                             abs(background.width - min(size.width, wide.width)) < 1,
                             "glass must centre around the controls, not stretch across the window")
                precondition(shadow.convert(shadow.bounds, to: toolbar) == background &&
                             shadow.layer?.shadowPath?.boundingBoxOfPath == shadow.bounds &&
                             !toolbar.clipsToBounds && !shadow.clipsToBounds,
                             "the shadow must follow the glass body when resizing, rather than the full editor slot")
                let rects = items.map { $0.convert($0.bounds, to: toolbar) }
                for rect in rects {
                    precondition(rect.minX >= background.minX + 9 && rect.maxX <= background.maxX - 9,
                                 "a toolbar item is clipped horizontally")
                    precondition(rect.minY >= 9 && rect.maxY <= toolbar.bounds.maxY - 9,
                                 "a toolbar item is clipped vertically")
                    precondition(abs(rect.midY - toolbar.bounds.midY) <= 1,
                                 "all controls must stay in the same row")
                }
                for pair in zip(rects, rects.dropFirst()) {
                    // At small scales, AppKit can round a subpixel gap to a
                    // shared edge. Allow floating-point conversion noise only.
                    precondition(pair.0.maxX <= pair.1.minX + 0.01, "toolbar controls overlap")
                }
                func checkHit(_ view: NSView) {
                    if let stack = view as? NSStackView {
                        stack.arrangedSubviews.forEach(checkHit)
                    } else if view is ScreenshotToolbarButton {
                        let rect = view.convert(view.bounds, to: toolbar)
                        let point = CGPoint(x: rect.midX, y: rect.midY)
                        var hit = toolbar.hitTest(point)
                        while hit != nil && hit !== view { hit = hit?.superview }
                        precondition(hit === view, "glass and scaled hit regions must preserve every button")
                    }
                }
                items.forEach(checkHit)
                precondition(toolbar.preferredSize(maxWidth: 1280) == wide,
                             "first layout must not change the natural toolbar measurement")
            }
            precondition(toolbar.preferredSize(maxWidth: 640).height == wide.height,
                         "a narrow toolbar must stay single-line")
            func findReadabilityPlate(in view: NSView) -> NSView? {
                if view.identifier?.rawValue == "annotation-toolbar.readability" { return view }
                return view.subviews.lazy.compactMap { findReadabilityPlate(in: $0) }.first
            }
            let plate = findReadabilityPlate(in: toolbar)!
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = NSAppearance(named: name)!
                plate.appearance = appearance
                appearance.performAsCurrentDrawingAppearance {
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    plate.draw(plate.bounds)
                    NSGraphicsContext.restoreGraphicsState()
                    let fill = bitmap.colorAt(x: 16, y: 16)!.usingColorSpace(.sRGB)!
                    precondition(fill.alphaComponent >= 0.73 && fill.alphaComponent <= 0.77,
                                 "busy backdrop protection must retain its opacity")
                    let label = NSColor.labelColor.usingColorSpace(.sRGB)!
                    func luminance(_ rgb: [CGFloat]) -> CGFloat {
                        let linear = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
                    }
                    for backdrop: CGFloat in [0, 1] {
                        let background = [fill.redComponent, fill.greenComponent, fill.blueComponent].map {
                            $0 * fill.alphaComponent + backdrop * (1 - fill.alphaComponent)
                        }
                        if name == .aqua && backdrop == 1 {
                            precondition(background.reduce(0, +) / 3 < 0.98,
                                         "a white screenshot must still show the tinted toolbar surface")
                        }
                        let foreground = zip([label.redComponent, label.greenComponent, label.blueComponent], background).map {
                            $0.0 * label.alphaComponent + $0.1 * (1 - label.alphaComponent)
                        }
                        let levels = [luminance(background), luminance(foreground)]
                        let contrast = (levels.max()! + 0.05) / (levels.min()! + 0.05)
                        precondition(contrast >= 4.5, "icons must remain legible over black and white backdrop extremes")
                    }
                }
            }
        }
        let recorder = ScreenshotMenuActionRecorder()
        let menu = ScreenshotToolbarMenuItem.menu("高级工具")
        precondition(!menu.showsStateColumn && menu.delegate != nil,
                     "dropdowns must use selected row backgrounds without a checkmark gutter")
        for (index, title) in ["贴图", "钢笔", "区域高亮"].enumerated() {
            let item = ScreenshotToolbarMenuItem.make(title,
                preview: ScreenshotToolbarMenuItem.symbol("photo"), selected: index == 2,
                previewSize: CGSize(width: 20, height: 20),
                target: recorder, action: #selector(ScreenshotMenuActionRecorder.choose(_:)))
            item.tag = index
            menu.addItem(item)
        }
        for (index, item) in menu.items.enumerated() {
            let row = item.view as! ScreenshotToolbarMenuRow
            row.layoutSubtreeIfNeeded()
            precondition(row.bounds.height == 36 && row.bounds.width <= 140,
                         "short tool names must have compact menu rows")
            precondition(row.isSelected == (index == 2) && item.state == .off,
                         "the current choice must use only a row background")
            precondition(row.previewFrame.width <= 20 && row.previewFrame.height <= 20,
                         "advanced icons must not be enlarged")
            precondition(abs(row.previewFrame.midY - row.labelFrame.midY) < 0.5 &&
                         row.labelFrame.minX - row.previewFrame.maxX >= 8 &&
                         row.labelFrame.minX - row.previewFrame.maxX <= 9,
                         "the preview and label must share a centreline without overlapping")
            precondition(item.attributedTitle?.string == item.title && item.toolTip == item.title)
            if #available(macOS 27.0, *) {
                precondition(item.preferredImageVisibility == .visible)
            }
            // Images, labels and row padding all belong to the same action.
            for point in [row.previewFrame.origin, row.labelFrame.origin, CGPoint(x: row.bounds.maxX - 6, y: 18)] {
                precondition(row.hitTest(point) === row)
            }
            let before = recorder.chosen
            precondition(row.accessibilityPerformPress())
            precondition(recorder.chosen == before,
                         "selection must wait for the old menu tracking loop to finish")
            menu.performPendingSelection()
            menu.performPendingSelection()
        }
        precondition(recorder.chosen == [0, 1, 2], "each illustrated row must dispatch its own tool once")
        menu.items[0].isEnabled = false
        precondition(!(menu.items[0].view as! ScreenshotToolbarMenuRow).accessibilityPerformPress())
        precondition(recorder.chosen == [0, 1, 2], "disabled choices must not dispatch actions")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            for item in menu.items {
                let row = item.view as! ScreenshotToolbarMenuRow
                row.appearance = appearance
                row.frame.size.width = 240
                row.needsLayout = true
                row.layoutSubtreeIfNeeded()
                precondition(row.labelFrame.maxX <= row.bounds.maxX - 10 &&
                             abs(row.previewFrame.midY - row.labelFrame.midY) < 0.5)
                for highlighted in [false, true] {
                    row.isMenuHighlighted = highlighted
                    appearance.performAsCurrentDrawingAppearance {
                        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 36,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                        row.draw(row.bounds)
                        NSGraphicsContext.restoreGraphicsState()
                        let alpha = bitmap.colorAt(x: 210, y: 18)!.alphaComponent
                        precondition((alpha > 0) == (row.isSelected || highlighted),
                                     "selected and hovered rows need a visible background in both appearances")
                    }
                }
            }
        }
        // Style images retain a wider gutter; language submenu parents remain
        // native so hover-open and keyboard submenu navigation are unchanged.
        let languageMenu = ScreenshotToolbarMenuItem.menu("翻译")
        let submenu = ScreenshotToolbarMenuItem.menu("语言")
        let english = ScreenshotToolbarMenuItem.make("英语", preview: ScreenshotToolbarMenuItem.badge("EN"),
            target: recorder, action: #selector(ScreenshotMenuActionRecorder.choose(_:)))
        submenu.addItem(english)
        let parent = ScreenshotToolbarMenuItem.submenu("译文语言",
            preview: ScreenshotToolbarMenuItem.badge("→A"), choices: submenu)
        languageMenu.addItem(parent)
        precondition(parent.submenu === submenu && parent.view == nil &&
                     parent.image?.size == CGSize(width: 28, height: 30),
                     "language parent rows must retain native submenu navigation")
        let languageRow = english.view as! ScreenshotToolbarMenuRow
        languageRow.layoutSubtreeIfNeeded()
        precondition(languageRow.previewFrame.width <= 44 && languageRow.previewFrame.height <= 22 &&
                     abs(languageRow.previewFrame.midY - languageRow.labelFrame.midY) < 0.5)
        english.tag = 9
        precondition(languageRow.accessibilityPerformPress())
        submenu.performPendingSelection()
        precondition(recorder.chosen == [0, 1, 2],
                     "a submenu selection must wait until its top-level menu closes")
        languageMenu.performPendingSelection()
        precondition(recorder.chosen == [0, 1, 2, 9],
                     "nested menus must dispatch the selected language exactly once")
        let advancedMenu = ScreenshotToolbarMenuItem.menu("高级工具")
        let sources = ScreenshotToolbarMenuItem.menu("插入贴图")
        for (index, title) in ["剪贴板图片", "本地图片"].enumerated() {
            let choice = ScreenshotToolbarMenuItem.make(title,
                preview: ScreenshotToolbarMenuItem.symbol(index == 0 ? "doc.on.clipboard" : "folder"),
                target: recorder, action: #selector(ScreenshotMenuActionRecorder.choose(_:)))
            choice.tag = index + 10
            sources.addItem(choice)
        }
        let sticker = ScreenshotToolbarMenuItem.submenu("贴图",
            preview: ScreenshotToolbarMenuItem.symbol("photo"),
            previewSize: CGSize(width: 20, height: 20), choices: sources)
        advancedMenu.addItem(sticker)
        precondition(sticker.view == nil && sticker.action == parent.action && sticker.submenu === sources &&
                     sources.supermenu === advancedMenu && sources.items.map(\.title) == ["剪贴板图片", "本地图片"],
                     "sticker sources must open as the same native submenu used by translation languages")
        precondition(sticker.image?.size == CGSize(width: 20, height: 30),
                     "a submenu tool must use the same 20-point glyph width as its neighbouring tools")
        let baseline = ScreenshotToolbarMenuItem.menu("高级工具行高基线")
        for title in ["贴图", "钢笔", "区域高亮", "设置"] {
            let makeRow = {
                ScreenshotToolbarMenuItem.make(title,
                    preview: ScreenshotToolbarMenuItem.symbol("photo"),
                    previewSize: CGSize(width: 20, height: 20), target: recorder,
                    action: #selector(ScreenshotMenuActionRecorder.choose(_:)))
            }
            baseline.addItem(makeRow())
            if title != "贴图" { advancedMenu.addItem(makeRow()) }
        }
        precondition(advancedMenu.size.height == baseline.size.height,
                     "native submenu rows and command rows must have identical heights")
        let alignedTool = ScreenshotToolbarMenuItem.make("钢笔",
            preview: NSImage(size: CGSize(width: 24, height: 24)),
            previewSize: CGSize(width: 20, height: 20), previewOffsetX: 2,
            target: recorder, action: #selector(ScreenshotMenuActionRecorder.choose(_:)))
        let alignedRow = alignedTool.view as! ScreenshotToolbarMenuRow
        alignedRow.layoutSubtreeIfNeeded()
        precondition(alignedRow.previewFrame.minX == 14 && alignedRow.labelFrame.minX == 40,
                     "advanced command icons need the native submenu inset without moving their labels")
        if CommandLine.arguments.count > 1 {
            let bundle = Bundle(path: CommandLine.arguments[1])!
            let image = bundle.image(forResource: NSImage.Name("AnnotationToolbar-extra-image"))!
            let native = ScreenshotToolbarMenuItem.submenu("贴图", preview: image,
                previewSize: CGSize(width: 20, height: 20), choices: ScreenshotToolbarMenuItem.menu("来源"))
            func bitmap(_ draw: () -> Void) -> NSBitmapImageRep {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 60,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
                draw()
                NSGraphicsContext.restoreGraphicsState()
                return rep
            }
            let actual = bitmap { native.image!.draw(in: CGRect(x: 0, y: 0, width: 20, height: 30)) }
            let expected = bitmap { image.draw(in: CGRect(x: 0, y: 5, width: 20, height: 20)) }
            for y in 0..<60 { for x in 0..<40 {
                precondition(abs(actual.colorAt(x: x, y: y)!.alphaComponent -
                                 expected.colorAt(x: x, y: y)!.alphaComponent) < 0.02,
                             "submenu image scaling must preserve the 20-point tool icon and its stroke weight")
            } }
        }
        for (index, item) in sources.items.enumerated() {
            precondition((item.view as! ScreenshotToolbarMenuRow).accessibilityPerformPress())
            precondition(recorder.chosen.count == index + 4,
                         "the source picker must not open until its menu hierarchy has closed")
            advancedMenu.performPendingSelection()
            precondition(recorder.chosen.last == index + 10,
                         "both clipboard and local-file source commands must stay reachable")
        }
        let color = ScreenshotToolbarMenuItem.make("石墨黑", preview: NSImage(size: CGSize(width: 28, height: 28)),
            previewSize: CGSize(width: 26, height: 26), target: recorder,
            action: #selector(ScreenshotMenuActionRecorder.choose(_:)))
        let colorRow = color.view as! ScreenshotToolbarMenuRow
        colorRow.layoutSubtreeIfNeeded()
        precondition(colorRow.bounds.width == 132 && colorRow.labelFrame.minX - colorRow.previewFrame.maxX == 8,
                     "color choices must use the same compact image-to-label spacing")
        if #available(macOS 27.0, *) {
            precondition(parent.preferredImageVisibility == .visible &&
                         english.preferredImageVisibility == .visible)
        }
        if CommandLine.arguments.count > 1 {
            let bundle = Bundle(path: CommandLine.arguments[1])!
            for name in ["rectangle", "circle", "arrow", "text", "zoom-in", "mosaic", "marker", "pen", "extra-square-x", "number", "highlight", "color", "ocr", "translate", "scroll-capture", "extra-ellipsis", "extra-settings"] {
                precondition(bundle.image(forResource: NSImage.Name("AnnotationToolbar-" + name)) != nil,
                             "a toolbar SVG asset is missing from the built app")
            }
            let brush = bundle.image(forResource: "AnnotationToolbar-pen")!
            let discard = bundle.image(forResource: "AnnotationToolbar-extra-square-x")!
            precondition(discard.size == brush.size, "discard and brush assets must have identical canvas sizes")
        }
        print("Toolbar layout smoke passed: clear glass and legacy frost, white/light/dark backdrop contrast, glass-sized shadow, compact illustrated dropdown alignment, selection backgrounds and actions, standalone magnifier, 320-1280 point single-line fitting, button hit regions, centring and SVG assets")
    }
}
