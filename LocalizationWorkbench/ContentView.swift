import SwiftUI

struct ContentView: View {
    @State private var selection: Workflow? = .excelConversion
    @StateObject private var projectRootStore = ProjectRootStore()
    @State private var isShowingProjectRootSheet = false
    @State private var didEvaluateLaunchPrompt = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .autocorrectionDisabled()
        .disableWritingToolsIfAvailable()
        .sheet(isPresented: $isShowingProjectRootSheet) {
            ProjectRootSetupSheet(projectRootStore: projectRootStore, allowsSkipping: true)
        }
        .onAppear {
            guard !didEvaluateLaunchPrompt else {
                return
            }
            didEvaluateLaunchPrompt = true
            if projectRootStore.shouldPromptAtLaunch {
                isShowingProjectRootSheet = true
            }
        }
    }

    private var sidebar: some View {
        List {
            Section("工作流") {
                ForEach(Workflow.toolCases) { workflow in
                    sidebarSelectionRow(workflow)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) {
            SidebarHeader(
                projectRootTitle: projectRootStore.titleText,
                projectRootDetail: projectRootStore.detailText,
                isProjectRootReady: projectRootStore.hasValidPath
            ) {
                isShowingProjectRootSheet = true
            }
        }
    }

    private func sidebarSelectionRow(_ workflow: Workflow) -> some View {
        Button {
            selection = workflow
        } label: {
            sidebarRow(workflow, isSelected: selection == workflow)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        .listRowBackground(Color.clear)
    }

    private func sidebarRow(_ workflow: Workflow, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 11)
                .fill(isSelected ? workflow.tint.opacity(0.2) : workflow.tint.opacity(0.13))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: workflow.symbolName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(workflow.tint)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(isSelected ? 0.92 : 0.82))
                Text(workflow.outputSummary)
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(isSelected ? 0.7 : 0.48))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? workflow.tint.opacity(0.16) : Color.white.opacity(0.001))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? workflow.tint.opacity(0.35) : Color.black.opacity(0.05), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var detail: some View {
        let workflow = selection ?? .excelConversion

        ZStack {
            AppBackdrop(tint: workflow.tint)

            switch workflow {
            case .excelConversion:
                ExcelConversionView(selection: $selection)
            case .newlineCheck:
                NewlineCheckView(selection: $selection)
            case .cleanStrings:
                CleanStringsView(selection: $selection)
            case .migrateLocalizedLiterals:
                MigrateLocalizedLiteralsView(selection: $selection)
            case .migrateI18nKeys:
                MigrateI18nKeysView(selection: $selection)
            }
        }
        .environmentObject(projectRootStore)
    }
}

private extension View {
    @ViewBuilder
    func disableWritingToolsIfAvailable() -> some View {
        if #available(macOS 15.0, *) {
            self.writingToolsBehavior(.disabled)
        } else {
            self
        }
    }
}

private struct SidebarHeader: View {
    let projectRootTitle: String
    let projectRootDetail: String
    let isProjectRootReady: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.92), Color(red: 0.35, green: 0.42, blue: 0.48)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "globe.badge.chevron.backward")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Localization Workbench")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("把散落脚本收成一套可视化本地化工作台。")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text("SwiftUI App")
                Text("Python Toolchain")
                Text("macOS")
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.48))

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("项目根目录")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.46))
                    Text(projectRootTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isProjectRootReady ? Color.black.opacity(0.82) : Color.orange.opacity(0.92))
                        .lineLimit(1)
                    Text(projectRootDetail)
                        .font(.system(size: 10, weight: .medium, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.48))
                        .lineLimit(2)
                }

                Spacer()

                Button(isProjectRootReady ? "更换" : "设置") {
                    action()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.black.opacity(0.8))
            }
            .padding(12)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isProjectRootReady ? Color.black.opacity(0.08) : Color.orange.opacity(0.28), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial)
    }
}
