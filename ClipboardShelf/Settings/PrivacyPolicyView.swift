import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    private var policy: AttributedString {
        guard let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let formatted = try? AttributedString(markdown: text) else {
            return AttributedString("隐私政策暂时无法读取。请联系 584772541@qq.com。")
        }
        return formatted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ClipHoook 隐私政策")
                    .font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }

            ScrollView {
                Text(policy)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(24)
        .frame(width: 660, height: 560)
    }
}
