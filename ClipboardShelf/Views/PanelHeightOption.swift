import AppKit
import SwiftUI

enum PanelHeightChoice: String, CaseIterable, Identifiable {
    case compact, standard, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "紧凑"
        case .standard: "标准"
        case .large: "宽敞"
        }
    }

    func exampleFrame(placement: PanelPlacement) -> CGRect {
        PanelLayout.frame(
            in: CGRect(x: 0, y: 0, width: 1440, height: 900),
            placement: placement,
            heightPreference: rawValue
        )
    }
}

struct PanelHeightOption: View {
    let choice: PanelHeightChoice
    let placement: PanelPlacement
    let isSelected: Bool
    var compact = false
    let action: () -> Void

    private var exampleFrame: CGRect { choice.exampleFrame(placement: placement) }
    private var exampleDimension: Int {
        Int(placement.isVertical ? exampleFrame.width : exampleFrame.height)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    let panelWidth = geometry.size.width * exampleFrame.width / 1440
                    let panelHeight = geometry.size.height * exampleFrame.height / 900
                    let panelX = geometry.size.width * exampleFrame.minX / 1440
                    let panelY = geometry.size.height * (900 - exampleFrame.maxY) / 900

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(.secondary.opacity(0.45), lineWidth: 1)
                            }

                        VStack {
                            HStack(spacing: 2) {
                                ForEach(0..<3) { _ in
                                    Circle()
                                        .fill(.secondary.opacity(0.45))
                                        .frame(width: 3, height: 3)
                                }
                                Spacer()
                            }
                            Spacer()
                        }
                        .padding(6)

                        miniaturePanel(width: panelWidth, height: panelHeight)
                            .offset(x: panelX, y: panelY)
                    }
                }
                .aspectRatio(1.6, contentMode: .fit)

                HStack(spacing: 4) {
                    if isSelected {
                        LucideIcon(.circleCheck, size: 15)
                            .foregroundStyle(.tint)
                    }
                    Text(choice.title)
                }
                .font((compact ? Font.caption : Font.subheadline).weight(isSelected ? .semibold : .regular))

                if !compact {
                    Text("\(placement.isVertical ? "宽" : "高") \(exampleDimension) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(placement.title)面板：\(choice.title)，示意\(placement.isVertical ? "宽度" : "高度") \(exampleDimension) 点")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private func miniaturePanel(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 1)
                .fill(.primary.opacity(0.35))
                .frame(width: min(18, max(4, width - 8)), height: 2)

            if placement.isVertical {
                VStack(spacing: 2) {
                    miniatureCard(height: max(6, min(18, (height - 14) / 3)))
                    miniatureCard(height: max(6, min(18, (height - 14) / 3)))
                }
            } else {
                HStack(spacing: 2) {
                    ForEach(0..<3) { index in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index == 0 ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.18))
                            .frame(width: max(5, (width - 14) / 4), height: max(6, height - 12))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
        }
    }

    private func miniatureCard(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor.opacity(0.65))
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

struct PanelLayoutQuickPicker: View {
    let placement: PanelPlacement
    let heightChoice: String
    let choosePlacement: (PanelPlacement) -> Void
    let chooseHeight: (PanelHeightChoice) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("面板布局")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: close) {
                    LucideIcon(.x, size: 14).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("关闭布局选择")
            }

            HStack(spacing: 5) {
                ForEach(PanelPlacement.allCases) { option in
                    Button { choosePlacement(option) } label: {
                        Text(option.title)
                            .font(.system(size: 11, weight: option == placement ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                option == placement ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(option == placement ? "已选择" : "未选择")
                }
            }

            HStack(alignment: .top, spacing: 5) {
                ForEach(PanelHeightChoice.allCases) { choice in
                    PanelHeightOption(
                        choice: choice, placement: placement,
                        isSelected: heightChoice == choice.rawValue,
                        compact: true
                    ) { chooseHeight(choice) }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 7)
        .accessibilityElement(children: .contain)
    }
}
