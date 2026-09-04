//
//  CloudImportViews.swift
//  LocalizationWorkbench
//
//  Author: Renogy_YX
//

import AppKit
import SwiftUI

struct CloudImportSection: View {
    let accent: Color
    @ObservedObject var sourceStore: CloudWorkbookSourceStore
    @ObservedObject var connectionStore: DingTalkMCPConnectionStore
    @ObservedObject var downloadCoordinator: CloudDownloadCoordinator
    @Binding var downloadDirectory: String
    let didImport: ([String]) -> Void
    let didImportAndConvert: ([String]) -> Void
    let didImportAndMerge: ([String]) -> Void
    let canRunImportedFiles: Bool
    let canMergeImportedFiles: Bool

    @State private var isShowingCloudImportSheet = false

    private var connectionTint: Color {
        switch connectionStore.state {
        case .connected:
            return .green
        case .verifying:
            return .orange
        case .disconnected, .failed:
            return .orange
        }
    }

    private var canDownloadSavedSources: Bool {
        !sourceStore.sources.isEmpty &&
            !downloadCoordinator.isDownloading &&
            connectionStore.isConnected
    }

    var body: some View {
        SectionCard(
            title: "云端 Excel",
            subtitle: "钉钉链接会经由每位用户自己的 MCP 连接导出为 Excel，再自动加入当前转换任务。",
            accent: accent
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: connectionStore.isConnected ? "checkmark.icloud.fill" : "icloud.slash")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(connectionTint)
                        .frame(width: 36, height: 36)
                        .background(connectionTint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("钉钉 MCP：\(connectionStore.statusTitle)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppTheme.primaryText)
                        Text(connectionStore.statusDetail)
                            .font(.system(size: 11, weight: .medium, design: .serif))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(sourceStore.sources.count) 个已保存链接")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.primaryText)
                        Text("支持勾选多个链接批量下载")
                            .font(.system(size: 10, weight: .medium, design: .serif))
                            .foregroundStyle(AppTheme.tertiaryText)
                    }

                    Button("管理云端链接") {
                        isShowingCloudImportSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                }

                if !sourceStore.sources.isEmpty {
                    Divider()

                    HStack(spacing: 10) {
                        Text("快捷操作会处理全部 \(sourceStore.sources.count) 个已保存链接")
                            .font(.system(size: 11, weight: .medium, design: .serif))
                            .foregroundStyle(AppTheme.secondaryText)

                        Spacer(minLength: 8)

                        Button {
                            startDownloadAllAndConvert()
                        } label: {
                            Label("下载并一键转换", systemImage: "arrow.down.to.line.compact")
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                        .help("下载全部已保存链接，完成后自动开始转换")
                        .disabled(!canDownloadSavedSources || !canRunImportedFiles)

                        Button {
                            startDownloadAllAndMerge()
                        } label: {
                            Label("下载并合并到项目", systemImage: "arrow.triangle.merge")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .help(
                            canMergeImportedFiles
                                ? "下载全部已保存链接，转换后合并到项目翻译资源目录"
                                : "请先选择有效的项目翻译资源目录"
                        )
                        .disabled(!canDownloadSavedSources || !canMergeImportedFiles)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCloudImportSheet) {
            CloudImportSheet(
                sourceStore: sourceStore,
                connectionStore: connectionStore,
                downloadCoordinator: downloadCoordinator,
                downloadDirectory: $downloadDirectory,
                didImport: didImport,
                didImportAndConvert: didImportAndConvert,
                canRunImportedFiles: canRunImportedFiles
            )
        }
        .onAppear {
            if downloadDirectory.cloudImportTrimmed.isEmpty {
                downloadDirectory = CloudDownloadLocation.defaultDirectoryPath
            }
        }
    }

    private func startDownloadAllAndConvert() {
        startDownloadAll(onImported: didImportAndConvert)
    }

    private func startDownloadAllAndMerge() {
        startDownloadAll(onImported: didImportAndMerge)
    }

    private func startDownloadAll(onImported: @escaping ([String]) -> Void) {
        if downloadDirectory.cloudImportTrimmed.isEmpty {
            downloadDirectory = CloudDownloadLocation.defaultDirectoryPath
        }
        downloadCoordinator.download(
            sources: sourceStore.sources,
            destinationPath: downloadDirectory,
            connectionStore: connectionStore,
            onImported: onImported
        )
    }
}

struct CloudImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var sourceStore: CloudWorkbookSourceStore
    @ObservedObject var connectionStore: DingTalkMCPConnectionStore
    @ObservedObject var downloadCoordinator: CloudDownloadCoordinator
    @Binding var downloadDirectory: String
    let didImport: ([String]) -> Void
    let didImportAndConvert: ([String]) -> Void
    let canRunImportedFiles: Bool

    @State private var selectedSourceIDs = Set<UUID>()
    @State private var isShowingConnectionSheet = false
    @State private var isAddingSource = false
    @State private var sourceBeingEdited: CloudWorkbookSource?

    private var selectedSources: [CloudWorkbookSource] {
        sourceStore.sources.filter { selectedSourceIDs.contains($0.id) }
    }

    private var canDownloadSelectedSources: Bool {
        !selectedSources.isEmpty &&
            !downloadCoordinator.isDownloading &&
            connectionStore.isConnected
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionCard
                    sourceList

                    SectionCard(
                        title: "下载保存目录",
                        subtitle: "下载完成后会自动把校验通过的 .xlsx 文件加入本页的 Excel 输入列表。",
                        accent: .blue
                    ) {
                        PathField(
                            title: "Excel 保存目录",
                            prompt: CloudDownloadLocation.defaultDirectoryPath,
                            text: $downloadDirectory,
                            browseLabel: "选择目录"
                        ) {
                            downloadDirectory = OpenPanelHelper.chooseDirectory(title: "选择云端 Excel 保存目录") ?? downloadDirectory
                        }
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 650)
        .onAppear {
            synchronizeSelection()
            if downloadDirectory.cloudImportTrimmed.isEmpty {
                downloadDirectory = CloudDownloadLocation.defaultDirectoryPath
            }
        }
        .onChange(of: sourceStore.sources.map(\.id)) { _ in
            synchronizeSelection()
        }
        .sheet(isPresented: $isShowingConnectionSheet) {
            DingTalkMCPConnectionSheet(connectionStore: connectionStore)
        }
        .sheet(isPresented: $isAddingSource) {
            DingTalkSourceEditorSheet(source: nil) { source in
                sourceStore.save(source)
                selectedSourceIDs.insert(source.id)
            }
        }
        .sheet(item: $sourceBeingEdited) { source in
            DingTalkSourceEditorSheet(source: source) { updatedSource in
                sourceStore.save(updatedSource)
                selectedSourceIDs.insert(updatedSource.id)
            }
        }
        .overlay {
            if downloadCoordinator.isDownloading {
                CloudDownloadLoadingHub(downloadCoordinator: downloadCoordinator, accent: .blue)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: downloadCoordinator.isDownloading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "icloud.and.arrow.down.fill")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 3) {
                Text("云端下载链接")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("保存多个钉钉在线文档链接，按需勾选并批量导入。")
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(AppTheme.secondaryText)
            }

            Spacer()

            Button("完成") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
    }

    private var connectionCard: some View {
        SectionCard(
            title: "钉钉 AI 表格 MCP",
            subtitle: "MCP 连接地址含个人访问凭据，只保存在当前 macOS 用户的系统钥匙串中。",
            accent: .blue
        ) {
            HStack(spacing: 12) {
                Image(systemName: connectionStore.isConnected ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark")
                    .foregroundStyle(connectionStore.isConnected ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(connectionStore.statusTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(connectionStore.statusDetail)
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(AppTheme.secondaryText)
                }

                Spacer()

                Button(connectionStore.isConnected ? "管理连接" : "连接钉钉") {
                    isShowingConnectionSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
    }

    private var sourceList: some View {
        SectionCard(
            title: "钉钉下载链接",
            subtitle: "一个链接对应一个可复用数据源；链接本身不保存登录凭据。",
            accent: .blue
        ) {
            HStack {
                Text("已选择 \(selectedSources.count) / \(sourceStore.sources.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryText)

                Spacer()

                Button {
                    isAddingSource = true
                } label: {
                    Label("新增钉钉链接", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(downloadCoordinator.isDownloading)
            }

            if sourceStore.sources.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.blue.opacity(0.75))
                    Text("尚未保存下载链接")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text("添加钉钉 AI 表格在线文档链接后，即可批量下载 Excel。")
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 10) {
                    ForEach(sourceStore.sources) { source in
                        CloudWorkbookSourceRow(
                            source: source,
                            isSelected: selectedBinding(for: source),
                            status: downloadCoordinator.status(for: source.id),
                            isDisabled: downloadCoordinator.isDownloading,
                            editAction: {
                                sourceBeingEdited = source
                            },
                            deleteAction: {
                                selectedSourceIDs.remove(source.id)
                                sourceStore.delete(source)
                            }
                        )
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if downloadCoordinator.isDownloading {
                ProgressView()
                    .controlSize(.small)
                Text("正在处理钉钉导出任务…")
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                Text("同名云端工作簿会覆盖旧下载文件；其他已下载工作簿会保留。")
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(AppTheme.tertiaryText)
            }

            Spacer()

            if downloadCoordinator.isDownloading {
                Button("取消下载") {
                    downloadCoordinator.cancel()
                }
                .buttonStyle(.bordered)
            }

            Button {
                startDownload()
            } label: {
                Label(
                    "仅下载 \(selectedSources.count) 个链接",
                    systemImage: "arrow.down.circle.fill"
                )
                .frame(minWidth: 155)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .disabled(!canDownloadSelectedSources)

            Button {
                startDownloadAndConvert()
            } label: {
                Label(
                    "下载并一键转换",
                    systemImage: "arrow.down.to.line.compact"
                )
                .frame(minWidth: 155)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(!canDownloadSelectedSources || !canRunImportedFiles)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private func selectedBinding(for source: CloudWorkbookSource) -> Binding<Bool> {
        Binding(
            get: { selectedSourceIDs.contains(source.id) },
            set: { isSelected in
                if isSelected {
                    selectedSourceIDs.insert(source.id)
                } else {
                    selectedSourceIDs.remove(source.id)
                }
            }
        )
    }

    private func synchronizeSelection() {
        let currentIDs = Set(sourceStore.sources.map(\.id))
        selectedSourceIDs.formIntersection(currentIDs)
        if selectedSourceIDs.isEmpty, !currentIDs.isEmpty {
            selectedSourceIDs = currentIDs
        }
    }

    private func startDownload() {
        startDownload(thenConvert: false)
    }

    private func startDownloadAndConvert() {
        startDownload(thenConvert: true)
    }

    private func startDownload(thenConvert: Bool) {
        if downloadDirectory.cloudImportTrimmed.isEmpty {
            downloadDirectory = CloudDownloadLocation.defaultDirectoryPath
        }
        downloadCoordinator.download(
            sources: selectedSources,
            destinationPath: downloadDirectory,
            connectionStore: connectionStore,
            onImported: { files in
                if thenConvert {
                    didImportAndConvert(files)
                } else {
                    didImport(files)
                }
            }
        )
    }
}

struct CloudDownloadLoadingHub: View {
    @ObservedObject var downloadCoordinator: CloudDownloadCoordinator
    let accent: Color

    @State private var isOrbiting = false

    private var statusDetail: String {
        if downloadCoordinator.isCancelling {
            return "正在取消当前下载，请稍候…"
        }
        return downloadCoordinator.activeStatus?.detail ?? "正在准备云端下载任务…"
    }

    private var progressText: String {
        let total = downloadCoordinator.totalSourceCount
        guard total > 0 else {
            return "正在准备下载任务"
        }
        return "已处理 \(downloadCoordinator.completedSourceCount) / \(total) 个链接"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.13))
                        .frame(width: 92, height: 92)

                    Circle()
                        .trim(from: 0.08, to: 0.78)
                        .stroke(
                            AngularGradient(
                                colors: [accent.opacity(0.24), accent, .cyan.opacity(0.82), accent.opacity(0.24)],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .frame(width: 76, height: 76)
                        .rotationEffect(.degrees(isOrbiting ? 360 : 0))
                        .animation(
                            .linear(duration: 1.18).repeatForever(autoreverses: false),
                            value: isOrbiting
                        )

                    Image(systemName: "icloud.and.arrow.down.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(spacing: 7) {
                    Text("正在下载云端 Excel")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.primaryText)

                    Text(statusDetail)
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    Text(progressText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                }

                ProgressView()
                    .controlSize(.small)
                    .tint(accent)

                Divider()

                Button {
                    downloadCoordinator.cancel()
                } label: {
                    Label(
                        downloadCoordinator.isCancelling ? "正在取消…" : "取消下载",
                        systemImage: "xmark"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(downloadCoordinator.isCancelling)
            }
            .padding(28)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(accent.opacity(0.32), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 28, x: 0, y: 15)
        }
        .onAppear {
            isOrbiting = true
        }
        .onDisappear {
            isOrbiting = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("正在下载云端 Excel")
    }
}

private struct CloudWorkbookSourceRow: View {
    let source: CloudWorkbookSource
    @Binding var isSelected: Bool
    let status: CloudDownloadStatus?
    let isDisabled: Bool
    let editAction: () -> Void
    let deleteAction: () -> Void

    private var statusColor: Color {
        guard let status else {
            return AppTheme.tertiaryText
        }
        switch status.phase {
        case .queued, .exporting:
            return .blue
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private var statusSymbol: String {
        guard let status else {
            return "circle.dashed"
        }
        switch status.phase {
        case .queued:
            return "clock"
        case .exporting:
            return "arrow.triangle.2.circlepath"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 3)

            Image(systemName: source.provider.symbolName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 30, height: 30)
                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                Text(source.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.primaryText)
                Text(source.summary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                if let status {
                    Label(status.detail, systemImage: statusSymbol)
                        .font(.system(size: 10, weight: .medium, design: .serif))
                        .foregroundStyle(statusColor)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 7) {
                Text(source.provider.title)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.blue.opacity(0.1), in: Capsule())

                HStack(spacing: 6) {
                    Button("编辑", action: editAction)
                        .buttonStyle(.bordered)
                    Button(role: .destructive, action: deleteAction) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 16))
        .disabled(isDisabled)
    }
}

struct DingTalkMCPConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var connectionStore: DingTalkMCPConnectionStore

    @State private var draftEndpoint = ""
    @State private var localCandidates: [LocalDingTalkMCPConnectionCandidate] = []
    @State private var validationMessage = ""
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接钉钉 AI 表格 MCP")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("导入或粘贴自己的 MCP 连接地址，应用仅保存到本机钥匙串。")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            GroupBox("当前状态") {
                HStack(spacing: 10) {
                    Image(systemName: connectionStore.isConnected ? "checkmark.shield.fill" : "shield.slash")
                        .foregroundStyle(connectionStore.isConnected ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionStore.statusTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(connectionStore.statusDetail)
                            .font(.system(size: 11, weight: .medium, design: .serif))
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                    Spacer()
                    if connectionStore.isConnected {
                        Button("断开") {
                            connectionStore.disconnect()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("使用已有 Agent 配置") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("若你已在 Claude、Qoder、Codex 等客户端连接官方钉钉 AI 表格 MCP，可从本机配置导入，无需再次复制访问 Key。")
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(AppTheme.secondaryText)

                    if localCandidates.isEmpty {
                        Text("尚未发现本机已配置的钉钉 AI 表格 MCP。")
                            .font(.system(size: 11, weight: .medium, design: .serif))
                            .foregroundStyle(AppTheme.tertiaryText)
                    } else {
                        ForEach(localCandidates) { candidate in
                            HStack {
                                Label("来自 \(candidate.title)", systemImage: "desktopcomputer")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                Spacer()
                                Button("使用此连接") {
                                    draftEndpoint = candidate.endpoint
                                    validationMessage = ""
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    Button("重新检测本机配置") {
                        localCandidates = connectionStore.findLocalCandidates()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }

            GroupBox("手动连接") {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("粘贴完整 MCP 连接地址", text: $draftEndpoint)
                        .textFieldStyle(.roundedBorder)
                    Text("连接地址通常包含个人访问 Key。保存前会调用 initialize 和 tools/list 验证 export_data 能力。")
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(AppTheme.secondaryText)

                    if !validationMessage.isEmpty {
                        Text(validationMessage)
                            .font(.system(size: 11, weight: .medium, design: .serif))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()

            HStack {
                Spacer()
                Button {
                    saveConnection()
                } label: {
                    Label(isSaving ? "正在验证" : "保存并验证", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(draftEndpoint.cloudImportTrimmed.isEmpty || isSaving)
            }
        }
        .padding(22)
        .frame(width: 640, height: 570)
        .onAppear {
            localCandidates = connectionStore.findLocalCandidates()
        }
    }

    private func saveConnection() {
        validationMessage = ""
        isSaving = true
        Task {
            let connected = await connectionStore.connect(endpoint: draftEndpoint)
            isSaving = false
            if connected {
                draftEndpoint = ""
                dismiss()
            } else {
                validationMessage = connectionStore.statusDetail
            }
        }
    }
}

struct DingTalkSourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let source: CloudWorkbookSource?
    let didSave: (CloudWorkbookSource) -> Void

    @State private var name: String
    @State private var link: String
    @State private var baseID: String
    @State private var scope: DingTalkExportScope
    @State private var tableID: String
    @State private var viewID: String
    @State private var validationMessage = ""
    @State private var usesInferredScope: Bool

    init(source: CloudWorkbookSource?, didSave: @escaping (CloudWorkbookSource) -> Void) {
        self.source = source
        self.didSave = didSave

        let configuration = source.flatMap { try? DingTalkExportConfiguration(source: $0) }
        _name = State(initialValue: source?.name ?? "")
        _link = State(initialValue: source?.link ?? "")
        _baseID = State(initialValue: configuration?.baseID ?? "")
        _scope = State(initialValue: configuration?.scope ?? .all)
        _tableID = State(initialValue: configuration?.tableID ?? "")
        _viewID = State(initialValue: configuration?.viewID ?? "")
        // 新建链接默认跟随 URL 中的 Sheet / View；编辑已有链接时保留用户已选范围。
        _usesInferredScope = State(initialValue: source == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source == nil ? "新增钉钉下载链接" : "编辑钉钉下载链接")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("链接只用于识别导出目标，钉钉账号凭据不会保存在此处。")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(AppTheme.secondaryText)
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            Form {
                TextField("显示名称", text: $name, prompt: Text("例如：多端文案翻译表"))

                TextField("钉钉在线文档链接", text: $link, prompt: Text("https://alidocs.dingtalk.com/i/nodes/..."))

                HStack {
                    Button("从链接解析 Base / Sheet / View") {
                        parseLink()
                    }
                    .buttonStyle(.bordered)

                    if !baseID.isEmpty {
                        Text("已识别 Base ID：\(baseID)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Picker("导出范围", selection: scopeSelection) {
                    ForEach(DingTalkExportScope.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }

                Text(scope.detail)
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(AppTheme.secondaryText)

                if let reference = try? DingTalkDocumentReference.parse(link),
                   !usesInferredScope,
                   reference.inferredScope != scope
                {
                    Text("当前链接指向\(reference.inferredScope.title)。如需按该 Sheet / View 导出，请点击上方“从链接解析”。")
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(.orange)
                }

                TextField("Base ID", text: $baseID, prompt: Text("从在线文档链接自动解析"))

                if scope == .table || scope == .view {
                    TextField("Sheet ID", text: $tableID, prompt: Text("从 sheetId 自动解析"))
                }
                if scope == .view {
                    TextField("View ID", text: $viewID, prompt: Text("从 viewId 自动解析"))
                }
            }
            .formStyle(.grouped)

            if !validationMessage.isEmpty {
                Text(validationMessage)
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Spacer()
                Button(source == nil ? "保存链接" : "保存修改") {
                    saveSource()
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(link.cloudImportTrimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 680, height: 510)
        .onChange(of: link) { _ in
            applyInferredReferenceIfNeeded()
        }
    }

    private func parseLink() {
        do {
            let reference = try DingTalkDocumentReference.parse(link)
            baseID = reference.baseID
            tableID = reference.tableID
            viewID = reference.viewID
            scope = reference.inferredScope
            usesInferredScope = true
            validationMessage = ""
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func applyInferredReferenceIfNeeded() {
        guard usesInferredScope,
              let reference = try? DingTalkDocumentReference.parse(link)
        else {
            return
        }
        baseID = reference.baseID
        tableID = reference.tableID
        viewID = reference.viewID
        scope = reference.inferredScope
    }

    private func saveSource() {
        do {
            let reference = try DingTalkDocumentReference.parse(link)
            if usesInferredScope {
                scope = reference.inferredScope
            }
            if baseID.cloudImportTrimmed.isEmpty {
                baseID = reference.baseID
            }
            if tableID.cloudImportTrimmed.isEmpty {
                tableID = reference.tableID
            }
            if viewID.cloudImportTrimmed.isEmpty {
                viewID = reference.viewID
            }

            let configuration = try DingTalkExportConfiguration(
                baseID: baseID,
                scope: scope,
                tableID: tableID,
                viewID: viewID
            )
            let displayName = name.cloudImportTrimmed.isEmpty
                ? "钉钉表格 \(String(configuration.baseID.prefix(8)))"
                : name.cloudImportTrimmed
            let savedSource = CloudWorkbookSource(
                id: source?.id ?? UUID(),
                name: displayName,
                provider: .dingTalkMCP,
                link: link.cloudImportTrimmed,
                settings: configuration.settings,
                createdAt: source?.createdAt ?? Date()
            )
            didSave(savedSource)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private var scopeSelection: Binding<DingTalkExportScope> {
        Binding(
            get: { scope },
            set: { selectedScope in
                scope = selectedScope
                usesInferredScope = false
            }
        )
    }
}
