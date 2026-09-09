import TokenTickCore
import SwiftUI

struct ContentView: View {
    @SceneStorage("navigation.selection") private var selectedSection = NavigationSection.overview.rawValue

    private var selection: Binding<NavigationSection?> {
        Binding(
            get: { NavigationSection(rawValue: selectedSection) },
            set: { if let section = $0 { selectedSection = section.rawValue } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("用量") {
                    ForEach([NavigationSection.overview, .daily, .threads, .projects]) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
                Section("记录") {
                    ForEach([NavigationSection.limits, .data]) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(ApplicationInfo.name)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            let section = NavigationSection(rawValue: selectedSection) ?? .overview
            if section == .overview {
                OverviewView()
                    .navigationTitle(section.title)
            } else {
                ContentUnavailableView(
                    section.emptyTitle,
                    systemImage: section.symbol,
                    description: Text(section.emptyDescription)
                )
                .navigationTitle(section.title)
            }
        }
        .frame(minWidth: 860, minHeight: 580)
    }
}

#Preview {
    ContentView()
}
