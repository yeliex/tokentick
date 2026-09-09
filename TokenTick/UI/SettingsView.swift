import TokenTickCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("TokenTick") {
                LabeledContent("版本", value: ApplicationInfo.version)
                LabeledContent("系统要求", value: "macOS \(ApplicationInfo.minimumMacOSVersion) 或更新版本")
                LabeledContent("金额单位", value: "美元（USD）")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 220)
    }
}
