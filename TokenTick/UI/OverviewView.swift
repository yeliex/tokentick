import TokenTickCore
import SwiftUI

struct OverviewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 16) {
                    Image("BrandIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(ApplicationInfo.name)
                            .font(.largeTitle.weight(.semibold))
                        Text("Codex 用量与成本统计")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }

                ContentUnavailableView(
                    "暂无用量数据",
                    systemImage: "chart.bar.xaxis",
                    description: Text("采集后可按任务、日期和项目查看 token 用量与已知金额。")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(.primary.opacity(0.06), lineWidth: 1)
                }

                Label("金额按模型公开价格换算为美元。", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
