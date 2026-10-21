import CoreGraphics

private enum PanelLayoutTestError: Error {
    case failed(String)
}

@main
struct PanelLayoutSmoke {
    static func main() throws {
        try check(PanelPlacement.allCases == [.bottom, .left, .right, .top],
                  "面板和设置中的布局顺序应为底部、左侧、右侧、顶部")
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let compact = PanelLayout.frame(in: screen, heightPreference: "compact")
        let standard = PanelLayout.frame(in: screen, heightPreference: "standard")
        let large = PanelLayout.frame(in: screen, heightPreference: "large")
        let preview = PanelLayout.detailPreviewFrame(
            in: screen, avoiding: standard, placement: .bottom,
            preferredSize: CGSize(width: 1240, height: 780)
        )

        try check(compact.minX == 10 && compact.minY == 10 && compact.width == 1420,
                  "面板应保持左右及底部 10 pt 边距")
        try check(compact.height == 300, "紧凑高度不正确")
        try check(abs(standard.height - 342) < 0.01, "标准高度不正确")
        try check(abs(large.height - 468) < 0.01, "宽敞高度不正确")
        try check(compact.maxX == standard.maxX && standard.minY == large.minY,
                  "切换高度时不应移动面板底边或侧边")
        try check(screen.contains(preview) && preview.minY > standard.maxY &&
                  preview.height > standard.height,
                  "图片预览应位于剪贴板面板上方，并提供更大的画布")

        let desktopScreen = CGRect(x: 0, y: 0, width: 1904, height: 1227)
        let desktopShelf = PanelLayout.frame(in: desktopScreen, heightPreference: "standard")
        let desktopPreview = PanelLayout.detailPreviewFrame(
            in: desktopScreen, avoiding: desktopShelf, placement: .bottom,
            preferredSize: CGSize(width: 1240, height: 780)
        )
        try check(desktopScreen.contains(desktopPreview) &&
                  desktopPreview.width <= 1240 && desktopPreview.height <= 780 &&
                  desktopPreview.midX == desktopScreen.midX &&
                  desktopPreview.minY > desktopShelf.maxY,
                  "大屏上的图片预览应居中并与剪贴板面板分开")

        let imageAvailable = PanelLayout.detailPreviewAvailableSize(
            in: desktopScreen, avoiding: desktopShelf, placement: .bottom
        )
        let tinyImage = PanelLayout.imagePreviewPreferredSize(
            pixelSize: CGSize(width: 240, height: 160), backingScale: 2,
            availableSize: imageAvailable, placement: .bottom,
            isFileReference: false
        )
        let normalImage = PanelLayout.imagePreviewPreferredSize(
            pixelSize: CGSize(width: 1200, height: 800), backingScale: 2,
            availableSize: imageAvailable, placement: .bottom,
            isFileReference: false
        )
        let wideImage = PanelLayout.imagePreviewPreferredSize(
            pixelSize: CGSize(width: 4000, height: 400), backingScale: 2,
            availableSize: imageAvailable, placement: .bottom,
            isFileReference: false
        )
        let tallImage = PanelLayout.imagePreviewPreferredSize(
            pixelSize: CGSize(width: 400, height: 4000), backingScale: 2,
            availableSize: imageAvailable, placement: .bottom,
            isFileReference: false
        )
        try check(tinyImage == CGSize(width: 360, height: 345),
                  "小图预览应只保留容纳操作控件的最小窗口")
        try check(normalImage.width > tinyImage.width &&
                  normalImage.height > tinyImage.height &&
                  normalImage.width < 1240 && normalImage.height < 780,
                  "普通图片应按原始尺寸开窗")
        try check(wideImage.width == 1240 && wideImage.height < 400 &&
                  tallImage.height == 780 && tallImage.width == 360,
                  "宽图和长图应按比例使用可用空间")
        let fileImage = PanelLayout.imagePreviewPreferredSize(
            pixelSize: CGSize(width: 240, height: 160), backingScale: 2,
            availableSize: imageAvailable, placement: .bottom,
            isFileReference: true
        )
        try check(fileImage == CGSize(width: 460, height: 365),
                  "文件引用需要足够空间显示保存副本按钮和展开的信息")
        let oneXImage = PanelLayout.imagePreviewPreferredSize(
            pixelSize: CGSize(width: 1200, height: 800), backingScale: 1,
            availableSize: imageAvailable, placement: .bottom,
            isFileReference: false
        )
        try check(oneXImage.width > normalImage.width && oneXImage.height >= normalImage.height,
                  "相同像素的图片应按屏幕缩放比例换算窗口尺寸")

        let shortText = PanelLayout.textPreviewPreferredSize(
            for: "我觉得是不是需要有三个环境？测试、预发布、生产。")
        let mediumText = PanelLayout.textPreviewPreferredSize(
            for: String(repeating: "这一段文字需要换行阅读。", count: 28))
        let longText = PanelLayout.textPreviewPreferredSize(
            for: String(repeating: "一行代码和说明\n", count: 20))
        try check(shortText == CGSize(width: 560, height: 360) &&
                  mediumText == CGSize(width: 620, height: 420) &&
                  longText == CGSize(width: 680, height: 480),
                  "文字预览应按内容长度选择紧凑、中等或完整尺寸")
        try check(PanelLayout.textPreviewPreferredSize(for: String(repeating: "x", count: 5_000))
                    == CGSize(width: 680, height: 480),
                  "长文本预览应保持足够的滚动阅读空间")

        for placement in PanelPlacement.allCases {
            let selectedCard = placement.isVertical
                ? CGRect(x: 50, y: 420, width: 260, height: 250)
                : CGRect(x: 550, y: 70, width: 260, height: 250)
            let shelf = PanelLayout.frame(in: desktopScreen, placement: placement,
                                          heightPreference: "standard")
            let card = PanelLayout.cardScreenFrame(
                shelfFrame: shelf, cardFrame: selectedCard
            )
            guard let card else { throw PanelLayoutTestError.failed("缺少卡片位置") }
            let anchored = PanelLayout.detailPreviewFrame(
                in: desktopScreen, avoiding: shelf, placement: placement,
                preferredSize: CGSize(width: 860, height: 620), cardFrame: card
            )
            try check(desktopScreen.contains(anchored), "\(placement.title)预览超出屏幕")
            switch placement {
            case .bottom:
                try check(abs(anchored.minY - card.maxY - 1) < 0.01,
                          "底部预览应靠近卡片上沿")
            case .top:
                try check(abs(card.minY - anchored.maxY - 1) < 0.01,
                          "顶部预览应靠近卡片下沿")
            case .left:
                try check(abs(anchored.minX - card.maxX - 1) < 0.01,
                          "左侧预览应靠近卡片右沿")
            case .right:
                try check(abs(card.minX - anchored.maxX - 1) < 0.01,
                          "右侧预览应靠近卡片左沿")
            }
            let tail = PanelLayout.previewTail(
                previewFrame: anchored, cardFrame: card, placement: placement
            )
            let dimension = placement.isVertical ? anchored.height : anchored.width
            try check(tail.edge == placement && tail.offset >= 34 && tail.offset <= dimension - 34,
                      "\(placement.title)预览尖角应贴近所选卡片并避开圆角")
            let tip: CGPoint
            let cardContact: CGPoint
            switch placement {
            case .bottom:
                tip = CGPoint(x: anchored.minX + tail.offset, y: anchored.minY)
                cardContact = CGPoint(x: card.midX, y: card.maxY)
            case .top:
                tip = CGPoint(x: anchored.minX + tail.offset, y: anchored.maxY)
                cardContact = CGPoint(x: card.midX, y: card.minY)
            case .left:
                tip = CGPoint(x: anchored.minX, y: anchored.maxY - tail.offset)
                cardContact = CGPoint(x: card.maxX, y: card.midY)
            case .right:
                tip = CGPoint(x: anchored.maxX, y: anchored.maxY - tail.offset)
                cardContact = CGPoint(x: card.minX, y: card.midY)
            }
            try check(abs(tip.x - cardContact.x) <= 1.01 &&
                      abs(tip.y - cardContact.y) <= 1.01,
                      "\(placement.title)预览尖角应贴近卡片边缘，以同一锚点缩放")
        }

        let firstCard = CGRect(x: 50, y: 70, width: 260, height: 250)
        let middleCard = firstCard.offsetBy(dx: 550, dy: 0)
        let lastCard = firstCard.offsetBy(dx: 1150, dy: 0)
        let horizontalPreviews = [firstCard, middleCard, lastCard].compactMap { local in
            PanelLayout.cardScreenFrame(shelfFrame: desktopShelf, cardFrame: local)
        }.map { card in
            PanelLayout.detailPreviewFrame(
                in: desktopScreen, avoiding: desktopShelf, placement: .bottom,
                preferredSize: CGSize(width: 860, height: 620), cardFrame: card
            )
        }
        try check(horizontalPreviews.count == 3 &&
                  horizontalPreviews[0].minX < horizontalPreviews[1].minX &&
                  horizontalPreviews[1].minX < horizontalPreviews[2].minX,
                  "不同卡片的预览应沿面板移动，而非全部居中")
        try check(PanelLayout.cardScreenFrame(
            shelfFrame: desktopShelf,
            cardFrame: firstCard.offsetBy(dx: 2200, dy: 0)
        ) == nil, "不可见卡片不应提供定位")

        let secondScreen = CGRect(x: 1920, y: -100, width: 1280, height: 720)
        let moved = PanelLayout.frame(in: secondScreen, heightPreference: "large")
        let secondPreview = PanelLayout.detailPreviewFrame(
            in: secondScreen, avoiding: moved, placement: .bottom,
            preferredSize: CGSize(width: 1240, height: 780)
        )
        try check(moved.minX == 1930 && moved.minY == -90 && moved.width == 1260,
                  "副屏坐标不正确")
        try check(secondScreen.contains(secondPreview) && secondPreview.midX == secondScreen.midX,
                  "图片预览应在副屏居中且保持边距")

        let shortScreen = CGRect(x: 0, y: 0, width: 800, height: 280)
        let limited = PanelLayout.frame(in: shortScreen, heightPreference: "large")
        try check(limited.height == 260, "面板不应超出较矮屏幕")
        try check(shortScreen.contains(PanelLayout.detailPreviewFrame(
            in: shortScreen, avoiding: limited, placement: .bottom,
            preferredSize: CGSize(width: 1240, height: 780)
        )),
                  "图片预览不应超出较矮屏幕")

        for placement in PanelPlacement.allCases {
            let sizes = ["compact", "standard", "large"].map {
                PanelLayout.frame(in: screen, placement: placement, heightPreference: $0)
            }
            let dimensions = sizes.map { placement.isVertical ? $0.width : $0.height }
            try check(dimensions[0] < dimensions[1] && dimensions[1] < dimensions[2],
                      "\(placement.title)的三个布局尺寸应依次增大")
            let cardSizes = sizes.map { frame in
                PanelLayout.cardSize(
                    in: CGSize(width: frame.width - 32, height: frame.height - 100),
                    placement: placement
                )
            }
            try check(cardSizes[0].width < cardSizes[1].width && cardSizes[1].width < cardSizes[2].width,
                      "\(placement.title)卡片宽度应随布局自适应")
            try check(cardSizes[0].height < cardSizes[1].height && cardSizes[1].height < cardSizes[2].height,
                      "\(placement.title)卡片高度应随布局自适应")
            for frame in sizes {
                try check(screen.insetBy(dx: 10, dy: 10).contains(frame),
                          "\(placement.title)面板超出屏幕")
                let offscreen = PanelLayout.offscreenFrame(from: frame, placement: placement)
                try check(!screen.intersects(offscreen), "\(placement.title)的弹出动画起点应在屏幕外")
            }
            let frame = sizes[1]
            switch placement {
            case .bottom: try check(frame.minY == 10 && frame.width == 1420, "底部位置错误")
            case .top: try check(frame.maxY == 890 && frame.width == 1420, "顶部位置错误")
            case .left: try check(frame.minX == 10 && frame.height == 880, "左侧位置错误")
            case .right: try check(frame.maxX == 1430 && frame.height == 880, "右侧位置错误")
            }
        }

        for placement in PanelPlacement.allCases {
            let frame = PanelLayout.frame(in: secondScreen, placement: placement, heightPreference: "large")
            try check(secondScreen.insetBy(dx: 10, dy: 10).contains(frame),
                      "\(placement.title)在副屏上超出边界")
        }

        for placement in PanelPlacement.allCases {
            let shelf = PanelLayout.frame(in: desktopScreen, placement: placement,
                                          heightPreference: "standard")
            let detail = PanelLayout.detailPreviewFrame(
                in: desktopScreen, avoiding: shelf, placement: placement,
                preferredSize: CGSize(width: 1240, height: 780)
            )
            try check(desktopScreen.contains(detail) && !detail.intersects(shelf),
                      "\(placement.title)布局中的预览不应遮挡剪贴板面板")
        }

        print("Panel layout smoke test passed")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw PanelLayoutTestError.failed(message) }
    }
}
