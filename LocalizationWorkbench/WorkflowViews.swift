import SwiftUI
import UniformTypeIdentifiers

private let xlsxType = UTType(filenameExtension: "xlsx") ?? .data
private let stringsType = UTType(filenameExtension: "strings") ?? .plainText
private let markdownType = UTType(filenameExtension: "md") ?? .plainText
private let csvType = UTType(filenameExtension: "csv") ?? .commaSeparatedText

private enum ExcelOutputFormat: String, CaseIterable, Identifiable {
    case strings
    case xcstrings
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strings:
            return "仅 .strings"
        case .xcstrings:
            return "仅 .xcstrings"
        case .both:
            return "双格式"
        }
    }
}

private enum ExcelConflictPolicy: String, CaseIterable, Identifiable {
    case error
    case keepFirst = "keep-first"
    case keepLast = "keep-last"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .error:
            return "报错"
        case .keepFirst:
            return "首次值"
        case .keepLast:
            return "最新值"
        }
    }
}

private enum MissingCommentFallback: String, CaseIterable, Identifiable {
    case empty
    case key

    var id: String { rawValue }

    var title: String {
        switch self {
        case .empty:
            return "空注释"
        case .key:
            return "使用 key"
        }
    }
}

struct ExcelConversionView: View {
    private let workflow = Workflow.excelConversion
    @Binding var selection: Workflow?

    @StateObject private var runner = ProcessRunner()

    @State private var inputFiles: [String] = []
    @State private var outputDirectory = ""
    @State private var format: ExcelOutputFormat = .both
    @State private var tableName = "Localizable"
    @State private var developmentLanguage = ""
    @State private var headerRow = "1"
    @State private var keyColumn = "A"
    @State private var keyHeader = ""
    @AppStorage("LocalizationWorkbench.ExcelConversion.extraKeyHeader")
    private var extraKeyHeader = ""
    @AppStorage("LocalizationWorkbench.ExcelConversion.sheetName")
    private var sheetName = ""
    @AppStorage("LocalizationWorkbench.ExcelConversion.sheetIndex")
    private var sheetIndex = "0"
    @AppStorage("LocalizationWorkbench.ExcelConversion.appColumn")
    private var appColumn = "App"
    @AppStorage("LocalizationWorkbench.ExcelConversion.appTrueValues")
    private var appTrueValues = "TRUE,true,1,yes,y"
    @AppStorage("LocalizationWorkbench.ExcelConversion.appTrueOnly")
    private var appTrueOnly = true
    @AppStorage("LocalizationWorkbench.ExcelConversion.allSheetsWithApp")
    private var allSheetsWithApp = false
    @State private var conflictPolicy: ExcelConflictPolicy = .keepFirst
    @State private var logFile = ""

    private var canRun: Bool {
        !inputFiles.isEmpty && !outputDirectory.trimmed.isEmpty && !runner.isRunning
    }

    private var metrics: [WorkflowMetric] {
        [
            WorkflowMetric(title: "Inputs", value: "\(inputFiles.count)", caption: "当前选中的工作簿数量"),
            WorkflowMetric(title: "Output", value: format.title, caption: "本次导出的资源格式"),
            WorkflowMetric(title: "Mode", value: allSheetsWithApp ? "Workbook Scan" : "Single Sheet", caption: "解析范围"),
        ]
    }

    private var readinessItems: [ChecklistItem] {
        [
            ChecklistItem(title: "已选择 Excel", detail: inputFiles.isEmpty ? "至少需要 1 个 .xlsx 文件。" : "已选择 \(inputFiles.count) 个输入文件。", isReady: !inputFiles.isEmpty),
            ChecklistItem(title: "输出目录", detail: outputDirectory.trimmed.isEmpty ? "请指定一个输出目录。" : outputDirectory.trimmed, isReady: !outputDirectory.trimmed.isEmpty),
            ChecklistItem(title: "执行模式", detail: allSheetsWithApp ? "工作簿扫描 + App 过滤" : "单 sheet 解析", isReady: true),
        ]
    }

    private var parameterColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 250), spacing: 16, alignment: .top),
            GridItem(.flexible(minimum: 250), spacing: 16, alignment: .top),
        ]
    }

    var body: some View {
        WorkflowPage(workflow: workflow, selection: $selection, metrics: metrics) {
            ReadinessCard(accent: workflow.tint, items: readinessItems)

            TipsCard(
                title: "建议",
                accent: workflow.tint,
                tips: [
                    "工作簿比较复杂时，优先使用“扫描整个工作簿并只处理带 App 列的 sheet”。",
                    "如果不同文件里有重名 key，建议先用“保留首次值”避免意外覆盖。",
                    "遇到 `名称（英文）` / `排障建议（英文）` 这种双翻译分组时，优先填写 Key 表头而不是只填列字母。",
                    "如果只是初始化 String Catalog，可以直接导出双格式，后续再在 Xcode 里继续维护。",
                ]
            )

            ConsoleCard(accent: workflow.tint, runner: runner)
        } content: {
            SectionCard(
                title: "输入与输出",
                subtitle: "支持一次选择多个工作簿并合并输出。",
                accent: workflow.tint
            ) {
                PathListEditor(
                    title: "Excel 文件",
                    subtitle: "按选择顺序合并多个工作簿。",
                    addLabel: "选择 Excel",
                    emptyText: "尚未选择任何 .xlsx 文件。",
                    items: $inputFiles
                ) {
                    let selection = OpenPanelHelper.chooseFiles(
                        title: "选择一个或多个 Excel 文件",
                        allowedTypes: [xlsxType]
                    )
                    guard !selection.isEmpty else {
                        return
                    }
                    inputFiles = UserPath.deduplicated(inputFiles + selection)
                    if outputDirectory.trimmed.isEmpty, let first = inputFiles.first {
                        let base = URL(fileURLWithPath: first).deletingLastPathComponent()
                        outputDirectory = base.appendingPathComponent("output").path
                    }
                }

                PathField(
                    title: "输出目录",
                    prompt: "/path/to/output",
                    text: $outputDirectory,
                    browseLabel: "选择目录"
                ) {
                    outputDirectory = OpenPanelHelper.chooseDirectory(title: "选择输出目录") ?? outputDirectory
                }

                PathField(
                    title: "日志文件",
                    prompt: "留空时输出到 <output>/conversion_issues.log",
                    text: $logFile,
                    browseLabel: "保存到"
                ) {
                    logFile = OpenPanelHelper.saveFile(
                        title: "选择日志文件位置",
                        suggestedName: "conversion_issues.log",
                        allowedTypes: [.plainText]
                    ) ?? logFile
                }
            }

            SectionCard(
                title: "转换参数",
                subtitle: "这些参数决定导出文件长什么样，以及脚本从表里按什么规则取数据。",
                accent: workflow.tint
            ) {
                LazyVGrid(columns: parameterColumns, alignment: .leading, spacing: 16) {
                    ParameterFieldCard(
                        title: "输出格式",
                        description: "控制脚本生成 .strings、.xcstrings 或两种都生成。旧工程通常选 .strings，用 String Catalog 的工程选 .xcstrings。",
                        example: "双格式会同时输出 Localizable.strings 和 Localizable.xcstrings"
                    ) {
                        Picker("输出格式", selection: $format) {
                            ForEach(ExcelOutputFormat.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    ParameterFieldCard(
                        title: "冲突策略",
                        description: "当多个 Excel 或多个 sheet 里出现同一个 key，但文案内容不一致时，脚本按这里决定报错还是保留哪一条。",
                        example: "首次值 = 第一条生效；最新值 = 后面的覆盖前面"
                    ) {
                        Picker("冲突策略", selection: $conflictPolicy) {
                            ForEach(ExcelConflictPolicy.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    ParameterFieldCard(
                        title: "输出文件基名",
                        description: "决定生成文件的名字，不带扩展名。填写后脚本会用它去拼出 .strings / .xcstrings 文件名。",
                        example: "填 Auth 会生成 Auth.strings 或 Auth.xcstrings"
                    ) {
                        TextField("Localizable", text: $tableName)
                            .textFieldStyle(.roundedBorder)
                    }

                    ParameterFieldCard(
                        title: "开发语言",
                        description: "主要影响 .xcstrings 的 source language。留空时，脚本会使用表头里识别到的第一个语言列。",
                        example: "常见填写：en"
                    ) {
                        TextField("例如 en", text: $developmentLanguage)
                            .textFieldStyle(.roundedBorder)
                    }

                    ParameterFieldCard(
                        title: "Header 行号",
                        description: "告诉脚本哪一行是表头行。这个行里需要包含 key 列、语言列，以及可选的 App 列。这里按 Excel 的行号填写，从 1 开始。",
                        example: "1 表示第一行，3 表示第三行"
                    ) {
                        TextField("1", text: $headerRow)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    ParameterFieldCard(
                        title: "Key 列",
                        description: "哪一列存放国际化 key。这里填的是 Excel 列名，不是数字；脚本会从这列取 login_title 这类 key。",
                        example: "可填 A、B、AA"
                    ) {
                        TextField("A", text: $keyColumn)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    ParameterFieldCard(
                        title: "Key 表头（可选）",
                        description: "复杂 Excel 建议直接按表头定位 key 列。填写后会覆盖上面的 Key 列配置。",
                        example: "例如 AppDevKey、AppDevKey（排障建议）"
                    ) {
                        TextField("留空则按列字母", text: $keyHeader)
                            .textFieldStyle(.roundedBorder)
                    }

                    ParameterFieldCard(
                        title: "额外 Key 表头（可选）",
                        description: "如果同一个 sheet 里还有第二套 key，可在这里再指定一个表头，脚本会把这套 key 连同对应翻译一起并入同一份输出。",
                        example: "例如 AppDevKey（排障建议）"
                    ) {
                        TextField("会记住上次填写的值", text: $extraKeyHeader)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Text("补充：当语言列表头是 `名称（英文）`、`排障建议（英文）` 这种格式时，脚本会按 Key 表头自动挑选对应那一组语言列。`AppDevKey` 默认取“名称”组，`AppDevKey（排障建议）` 会取“排障建议”组，然后两套 key 会合并进同一份 `.strings` / `.xcstrings`。")
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.56))
            }

            SectionCard(
                title: "Sheet / App 过滤",
                subtitle: "决定脚本读哪个 sheet，以及是否只导出属于 App 的那部分文案。",
                accent: workflow.tint
            ) {
                LazyVGrid(columns: parameterColumns, alignment: .leading, spacing: 16) {
                    ParameterToggleCard(
                        title: "扫描整个工作簿并只处理带 App 列的 sheet",
                        description: "适合一个 workbook 里拆了多个业务 sheet 的场景。开启后，脚本会遍历整本工作簿，只合并那些同时具备 key 列和 App 列的 sheet。",
                        note: "常用于第一张是说明页、后面才是业务 sheet 的 Excel。",
                        isOn: $allSheetsWithApp
                    )

                    ParameterToggleCard(
                        title: "仅导出 App 为真值的行",
                        description: "只保留 App 列命中真值集合的行，适合同一张表里混着 App / Web / Android 文案的情况。",
                        note: allSheetsWithApp ? "开启整本扫描后，这个过滤会由脚本自动启用。" : "关闭时会导出所有行，不看 App 列真假。",
                        isOn: $appTrueOnly,
                        isDisabled: allSheetsWithApp
                    )

                    ParameterFieldCard(
                        title: "Sheet 名称",
                        description: "精确指定要读取的 sheet 名。填了这里以后，下面的 Sheet 索引会被忽略。",
                        example: "例如 Common、登录页、Sheet1"
                    ) {
                        TextField("留空则使用索引", text: $sheetName)
                            .textFieldStyle(.roundedBorder)
                    }

                    ParameterFieldCard(
                        title: "Sheet 索引",
                        description: "按 workbook 里的顺序读取 sheet，0 表示第一个。只有在没填 Sheet 名称时才生效。",
                        example: "0 = 第一个，1 = 第二个"
                    ) {
                        TextField("0", text: $sheetIndex)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(!sheetName.trimmed.isEmpty)
                    }

                    ParameterFieldCard(
                        title: "App 列名",
                        description: "哪一列表头用来标记“这行是不是 App 文案”。脚本按表头名字匹配，不是按列号匹配。",
                        example: "默认是 App，也可以填 iOS、客户端 等自定义表头"
                    ) {
                        TextField("App", text: $appColumn)
                            .textFieldStyle(.roundedBorder)
                    }

                    ParameterFieldCard(
                        title: "App 真值",
                        description: "哪些值会被当成“是 App 文案”。多个值用英文逗号分隔，脚本会拿 App 列内容和这组值比较。",
                        example: "TRUE,true,1,yes,y"
                    ) {
                        TextField("TRUE,true,1,yes,y", text: $appTrueValues)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                Text("补充：当你保持默认“第一个 sheet”、没有填写 Sheet 名称，且没有手动开启整本扫描时，脚本会尝试自动识别当前 Excel 是单 sheet 还是多 sheet App 模式。")
                    .font(.system(size: 11, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.56))
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingExecutionDock(
                accent: workflow.tint,
                primaryTitle: "开始转换",
                primarySystemImage: "play.fill",
                canRun: canRun,
                runner: runner,
                primaryAction: run,
                accessoryActions: [
                    DockAction(
                        title: "打开输出目录",
                        systemImage: "folder",
                        isEnabled: !outputDirectory.trimmed.isEmpty
                    ) {
                        OpenPanelHelper.open(outputDirectory)
                    },
                ]
            )
        }
    }

    private func run() {
        guard !inputFiles.isEmpty else {
            runner.presentSetupError("请至少选择一个 Excel 文件。")
            return
        }
        guard !outputDirectory.trimmed.isEmpty else {
            runner.presentSetupError("请先选择输出目录。")
            return
        }

        let normalizedOutputDirectory = UserPath.normalize(outputDirectory)
        var isDirectory: ObjCBool = false
        let outputExists = FileManager.default.fileExists(
            atPath: normalizedOutputDirectory,
            isDirectory: &isDirectory
        )
        if outputExists && !isDirectory.boolValue {
            runner.presentSetupError("输出路径已存在，但它不是目录：\(normalizedOutputDirectory)")
            return
        }
        if !outputExists {
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: normalizedOutputDirectory),
                    withIntermediateDirectories: true
                )
            } catch {
                runner.presentSetupError("创建输出目录失败：\(error.localizedDescription)")
                return
            }
        }

        var args = inputFiles.map(UserPath.normalize)
        args.append(normalizedOutputDirectory)
        args += ["--format", format.rawValue]
        args += ["--header-row", headerRow.trimmedOr("1")]
        args += ["--key-column", keyColumn.trimmedOr("A")]
        args += ["--table-name", tableName.trimmedOr("Localizable")]
        args += ["--app-column", appColumn.trimmedOr("App")]
        args += ["--app-true-values", appTrueValues.trimmedOr("TRUE,true,1,yes,y")]
        args += ["--conflict-policy", conflictPolicy.rawValue]
        if !keyHeader.trimmed.isEmpty {
            args += ["--key-header", keyHeader.trimmed]
        }
        if !extraKeyHeader.trimmed.isEmpty {
            args += ["--extra-key-header", extraKeyHeader.trimmed]
        }

        if !sheetName.trimmed.isEmpty {
            args += ["--sheet-name", sheetName.trimmed]
        } else {
            args += ["--sheet-index", sheetIndex.trimmedOr("0")]
        }
        if !developmentLanguage.trimmed.isEmpty {
            args += ["--development-language", developmentLanguage.trimmed]
        }
        if !allSheetsWithApp && sheetName.trimmed.isEmpty && sheetIndex.trimmedOr("0") == "0" {
            args.append("--auto-detect-workbook-mode")
        }
        if appTrueOnly {
            args.append("--app-true-only")
        }
        if allSheetsWithApp {
            args.append("--all-sheets-with-app")
        }
        if !logFile.trimmed.isEmpty {
            args += ["--log-file", UserPath.normalize(logFile)]
        }

        let workingDirectory = URL(fileURLWithPath: normalizedOutputDirectory)

        do {
            let request = try PythonBridge.request(
                scriptName: "excel_to_localizations.py",
                arguments: args,
                workingDirectory: workingDirectory
            )
            runner.run(request)
        } catch {
            runner.presentSetupError(error.localizedDescription)
        }
    }
}

struct NewlineCheckView: View {
    private let workflow = Workflow.newlineCheck
    @Binding var selection: Workflow?

    @StateObject private var runner = ProcessRunner()

    @State private var workbookPath = ""
    @State private var outputMarkdown = ""
    @State private var outputCSV = ""
    @State private var headerSearchRows = "20"

    private var canRun: Bool {
        !workbookPath.trimmed.isEmpty &&
        !outputMarkdown.trimmed.isEmpty &&
        !outputCSV.trimmed.isEmpty &&
        !runner.isRunning
    }

    private var metrics: [WorkflowMetric] {
        [
            WorkflowMetric(title: "Workbook", value: workbookPath.trimmed.isEmpty ? "未选择" : "已选择", caption: "当前是否已经指定待扫描工作簿"),
            WorkflowMetric(title: "Reports", value: "2", caption: "会生成 Markdown 和 CSV 两份报告"),
            WorkflowMetric(title: "Header Scan", value: headerSearchRows.trimmedOr("20"), caption: "头部扫描行数"),
        ]
    }

    private var readinessItems: [ChecklistItem] {
        [
            ChecklistItem(title: "Excel 工作簿", detail: workbookPath.trimmed.isEmpty ? "请选择一个 .xlsx 文件。" : workbookPath.trimmed, isReady: !workbookPath.trimmed.isEmpty),
            ChecklistItem(title: "Markdown 报告", detail: outputMarkdown.trimmed.isEmpty ? "请选择 .md 输出位置。" : outputMarkdown.trimmed, isReady: !outputMarkdown.trimmed.isEmpty),
            ChecklistItem(title: "CSV 报告", detail: outputCSV.trimmed.isEmpty ? "请选择 .csv 输出位置。" : outputCSV.trimmed, isReady: !outputCSV.trimmed.isEmpty),
        ]
    }

    var body: some View {
        WorkflowPage(workflow: workflow, selection: $selection, metrics: metrics) {
            ReadinessCard(accent: workflow.tint, items: readinessItems)

            TipsCard(
                title: "检查逻辑",
                accent: workflow.tint,
                tips: [
                    "英文列含有显式 \\n 时，翻译列需要保留同样数量的 \\n。",
                    "英文列只有实际换行时，翻译列可以是实际换行或转义后的 \\n，但总数要匹配。",
                    "这个流程适合在导出资源前先清一遍 Excel 质量问题。",
                ]
            )

            ConsoleCard(accent: workflow.tint, runner: runner)
        } content: {
            SectionCard(
                title: "工作簿与输出",
                subtitle: "会为同一个工作簿生成两份检查报告。",
                accent: workflow.tint
            ) {
                PathField(
                    title: "Excel 工作簿",
                    prompt: "/path/to/workbook.xlsx",
                    text: $workbookPath,
                    browseLabel: "选择文件"
                ) {
                    guard let selection = OpenPanelHelper.chooseFile(
                        title: "选择需要检查的 Excel 工作簿",
                        allowedTypes: [xlsxType]
                    ) else {
                        return
                    }
                    workbookPath = selection
                    seedNewlineOutputs(from: selection)
                }

                HStack(spacing: 16) {
                    PathField(
                        title: "Markdown 报告",
                        prompt: "newline_check_report.md",
                        text: $outputMarkdown,
                        browseLabel: "保存到"
                    ) {
                        outputMarkdown = OpenPanelHelper.saveFile(
                            title: "选择 Markdown 报告位置",
                            suggestedName: "newline_check_report.md",
                            allowedTypes: [markdownType]
                        ) ?? outputMarkdown
                    }

                    PathField(
                        title: "CSV 报告",
                        prompt: "newline_check_report.csv",
                        text: $outputCSV,
                        browseLabel: "保存到"
                    ) {
                        outputCSV = OpenPanelHelper.saveFile(
                            title: "选择 CSV 报告位置",
                            suggestedName: "newline_check_report.csv",
                            allowedTypes: [csvType]
                        ) ?? outputCSV
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Header 搜索行数")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    TextField("20", text: $headerSearchRows)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingExecutionDock(
                accent: workflow.tint,
                primaryTitle: "开始检查",
                primarySystemImage: "play.fill",
                canRun: canRun,
                runner: runner,
                primaryAction: run,
                accessoryActions: [
                    DockAction(
                        title: "打开 Markdown",
                        systemImage: "doc.text",
                        isEnabled: !outputMarkdown.trimmed.isEmpty
                    ) {
                        OpenPanelHelper.open(outputMarkdown)
                    },
                    DockAction(
                        title: "打开 CSV",
                        systemImage: "tablecells",
                        isEnabled: !outputCSV.trimmed.isEmpty
                    ) {
                        OpenPanelHelper.open(outputCSV)
                    },
                ]
            )
        }
    }

    private func seedNewlineOutputs(from workbook: String) {
        let baseDirectory = URL(fileURLWithPath: workbook).deletingLastPathComponent()
        outputMarkdown = baseDirectory.appendingPathComponent("newline_check_report.md").path
        outputCSV = baseDirectory.appendingPathComponent("newline_check_report.csv").path
    }

    private func run() {
        guard !workbookPath.trimmed.isEmpty else {
            runner.presentSetupError("请先选择一个 Excel 工作簿。")
            return
        }
        guard !outputMarkdown.trimmed.isEmpty, !outputCSV.trimmed.isEmpty else {
            runner.presentSetupError("请先指定 Markdown 和 CSV 报告路径。")
            return
        }

        let workbookURL = UserPath.url(from: workbookPath)
        let workingDirectory = workbookURL?.deletingLastPathComponent()
        let args = [
            UserPath.normalize(workbookPath),
            "--output-md", UserPath.normalize(outputMarkdown),
            "--output-csv", UserPath.normalize(outputCSV),
            "--header-search-rows", headerSearchRows.trimmedOr("20"),
        ]

        do {
            let request = try PythonBridge.request(
                scriptName: "check_excel_newlines.py",
                arguments: args,
                workingDirectory: workingDirectory
            )
            runner.run(request)
        } catch {
            runner.presentSetupError(error.localizedDescription)
        }
    }
}

struct CleanStringsView: View {
    private let workflow = Workflow.cleanStrings
    @Binding var selection: Workflow?

    @StateObject private var runner = ProcessRunner()

    @State private var targetPaths: [String] = []
    @State private var writeChanges = false

    private var canRun: Bool {
        !targetPaths.isEmpty && !runner.isRunning
    }

    private var metrics: [WorkflowMetric] {
        [
            WorkflowMetric(title: "Targets", value: "\(targetPaths.count)", caption: "当前加入的文件或目录数量"),
            WorkflowMetric(title: "Mode", value: writeChanges ? "Apply" : "Dry-run", caption: "是否直接写回目标文件"),
            WorkflowMetric(title: "Scope", value: "Localizable.strings", caption: "主要面向 strings 规范化场景"),
        ]
    }

    private var readinessItems: [ChecklistItem] {
        [
            ChecklistItem(title: "目标路径", detail: targetPaths.isEmpty ? "请先选择至少一个文件或目录。" : "已选择 \(targetPaths.count) 个目标。", isReady: !targetPaths.isEmpty),
            ChecklistItem(title: "执行模式", detail: writeChanges ? "会直接写回磁盘。" : "仅报告，不改文件。", isReady: true),
        ]
    }

    var body: some View {
        WorkflowPage(workflow: workflow, selection: $selection, metrics: metrics) {
            ReadinessCard(accent: workflow.tint, items: readinessItems)

            TipsCard(
                title: "适用场景",
                accent: workflow.tint,
                tips: [
                    "历史 strings 里存在裸字符串、重复 key/value 或格式不一致时，先跑这个流程很合适。",
                    "建议第一次先 dry-run，看冲突数量和日志结果，再决定是否写回。",
                    "如果多个目录一起处理，最好先确保这些路径都属于同一份工程，避免误改。",
                ]
            )

            ConsoleCard(accent: workflow.tint, runner: runner)
        } content: {
            SectionCard(
                title: "目标范围",
                subtitle: "可以同时选择 .strings 文件和目录，脚本会递归匹配 Localizable.strings。",
                accent: workflow.tint
            ) {
                PathListEditor(
                    title: "文件或目录",
                    subtitle: "适合批量清理整个 Localizables 目录。",
                    addLabel: "选择目标",
                    emptyText: "尚未选择任何文件或目录。",
                    items: $targetPaths
                ) {
                    let selection = OpenPanelHelper.chooseFileSystemItems(title: "选择 .strings 文件或目录")
                    targetPaths = UserPath.deduplicated(targetPaths + selection)
                }

                Toggle("直接写回文件", isOn: $writeChanges)

                Text("关闭时只做 dry-run，控制台会输出扫描结果，不改动磁盘内容。")
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.56))
            }
        }
        .safeAreaInset(edge: .bottom) {
            FloatingExecutionDock(
                accent: workflow.tint,
                primaryTitle: writeChanges ? "执行并写回" : "开始 dry-run",
                primarySystemImage: writeChanges ? "wand.and.stars.inverse" : "play.fill",
                canRun: canRun,
                runner: runner,
                primaryAction: run,
                accessoryActions: [
                    DockAction(
                        title: "打开首个目标",
                        systemImage: "folder",
                        isEnabled: targetPaths.first != nil
                    ) {
                        if let firstPath = targetPaths.first {
                            OpenPanelHelper.open(firstPath)
                        }
                    },
                ]
            )
        }
    }

    private func run() {
        guard !targetPaths.isEmpty else {
            runner.presentSetupError("请先选择至少一个 .strings 文件或目录。")
            return
        }

        var args = targetPaths.map(UserPath.normalize)
        if writeChanges {
            args.append("--write")
        }

        let workingDirectory = UserPath.url(from: targetPaths.first ?? "")?.deletingLastPathComponent()

        do {
            let request = try PythonBridge.request(
                scriptName: "clean_localizable_strings.py",
                arguments: args,
                workingDirectory: workingDirectory
            )
            runner.run(request)
        } catch {
            runner.presentSetupError(error.localizedDescription)
        }
    }
}

struct MigrateLocalizedLiteralsView: View {
    private let workflow = Workflow.migrateLocalizedLiterals
    @Binding var selection: Workflow?
    @EnvironmentObject private var projectRootStore: ProjectRootStore

    @StateObject private var runner = ProcessRunner()

    @State private var projectRoot = ""
    @State private var lastSeededProjectRoot = ""
    @State private var sourceRoot = ""
    @State private var sourcePaths: [String] = []
    @State private var commentsFile = ""
    @State private var secondaryCommentsFile = ""
    @State private var reportDirectory = ""
    @State private var fallback: MissingCommentFallback = .empty
    @State private var applyChanges = false

    private var canRun: Bool {
        UserPath.isDirectory(projectRoot) &&
        !commentsFile.trimmed.isEmpty &&
        !reportDirectory.trimmed.isEmpty &&
        !runner.isRunning
    }

    private var projectRootBinding: Binding<String> {
        Binding(
            get: { projectRoot },
            set: { setProjectRoot($0, applyDefaults: false) }
        )
    }

    private var projectRootDetail: String {
        if projectRoot.trimmed.isEmpty {
            return "请先设置项目根目录。"
        }
        if !UserPath.isDirectory(projectRoot) {
            return "目录不存在：\(projectRoot.trimmed)"
        }
        return projectRoot.trimmed
    }

    private var metrics: [WorkflowMetric] {
        [
            WorkflowMetric(title: "Scope", value: sourcePaths.isEmpty ? "Source Root" : "\(sourcePaths.count) Paths", caption: "处理范围"),
            WorkflowMetric(title: "Mode", value: applyChanges ? "Apply" : "Dry-run", caption: "是否直接改源码"),
            WorkflowMetric(title: "Fallback", value: fallback.title, caption: "注释缺失时的回退策略"),
        ]
    }

    private var readinessItems: [ChecklistItem] {
        [
            ChecklistItem(title: "项目根目录", detail: projectRootDetail, isReady: UserPath.isDirectory(projectRoot)),
            ChecklistItem(title: "Primary 注释文件", detail: commentsFile.trimmed.isEmpty ? "请选择用于 comment 的 strings 文件。" : commentsFile.trimmed, isReady: !commentsFile.trimmed.isEmpty),
            ChecklistItem(title: "报告目录", detail: reportDirectory.trimmed.isEmpty ? "请选择报告输出目录。" : reportDirectory.trimmed, isReady: !reportDirectory.trimmed.isEmpty),
        ]
    }

    var body: some View {
        WorkflowPage(workflow: workflow, selection: $selection, metrics: metrics) {
            ReadinessCard(accent: workflow.tint, items: readinessItems)

            TipsCard(
                title: "迁移建议",
                accent: workflow.tint,
                tips: [
                    "第一次建议只跑 dry-run，看 missing comments 和 english fallback 的报告结果。",
                    "如果你只想处理某几个模块，不要依赖 source root，直接添加显式处理路径更稳。",
                    "primary comments 建议用 zh-Hans，secondary comments 建议用 en，方便保留更可读的 comment。",
                ]
            )

            ConsoleCard(accent: workflow.tint, runner: runner)
        } content: {
            SectionCard(
                title: "项目定位",
                subtitle: "把源码里的 \"key\".localized 批量改写成 NSLocalizedString。",
                accent: workflow.tint
            ) {
                HStack(alignment: .top, spacing: 16) {
                    PathField(
                        title: "项目根目录",
                        prompt: "/path/to/project",
                        text: projectRootBinding,
                        browseLabel: "选择目录"
                    ) {
                        if let selection = OpenPanelHelper.chooseDirectory(title: "选择项目根目录") {
                            setProjectRoot(selection, applyDefaults: true)
                        }
                    }

                    PathField(
                        title: "默认源码根目录",
                        prompt: "Renogy",
                        text: $sourceRoot,
                        browseLabel: "选择目录"
                    ) {
                        sourceRoot = OpenPanelHelper.chooseDirectory(title: "选择默认源码根目录") ?? sourceRoot
                    }
                }

                HStack {
                    Button("按项目根目录填充默认路径") {
                        applyLocalizedLiteralDefaults()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                PathListEditor(
                    title: "显式处理路径",
                    subtitle: "留空时脚本会扫描默认源码根目录；也可以指定多个局部目录或文件。",
                    addLabel: "添加路径",
                    emptyText: "当前未指定显式路径，将回落到默认源码根目录。",
                    items: $sourcePaths
                ) {
                    let selection = OpenPanelHelper.chooseFileSystemItems(title: "选择源码目录或文件")
                    sourcePaths = UserPath.deduplicated(sourcePaths + selection)
                }
            }

            SectionCard(
                title: "注释与报告",
                subtitle: "primary comments 一般指 zh-Hans，secondary comments 一般指英文回退。",
                accent: workflow.tint
            ) {
                HStack(alignment: .top, spacing: 16) {
                    PathField(
                        title: "Primary 注释文件",
                        prompt: "zh-Hans.lproj/Localizable.strings",
                        text: $commentsFile,
                        browseLabel: "选择文件"
                    ) {
                        commentsFile = OpenPanelHelper.chooseFile(
                            title: "选择 Primary 注释文件",
                            allowedTypes: [stringsType]
                        ) ?? commentsFile
                    }

                    PathField(
                        title: "Secondary 注释文件",
                        prompt: "en.lproj/Localizable.strings",
                        text: $secondaryCommentsFile,
                        browseLabel: "选择文件"
                    ) {
                        secondaryCommentsFile = OpenPanelHelper.chooseFile(
                            title: "选择 Secondary 注释文件",
                            allowedTypes: [stringsType]
                        ) ?? secondaryCommentsFile
                    }
                }

                PathField(
                    title: "报告目录",
                    prompt: "/path/to/reports",
                    text: $reportDirectory,
                    browseLabel: "选择目录"
                ) {
                    reportDirectory = OpenPanelHelper.chooseDirectory(title: "选择报告目录") ?? reportDirectory
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("缺失注释回退策略")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Picker("缺失注释回退策略", selection: $fallback) {
                        ForEach(MissingCommentFallback.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("直接写回源码", isOn: $applyChanges)
            }
        }
        .onAppear {
            syncProjectRootFromStoreIfNeeded()
        }
        .onChange(of: projectRootStore.path) { _ in
            syncProjectRootFromStoreIfNeeded()
        }
        .safeAreaInset(edge: .bottom) {
            FloatingExecutionDock(
                accent: workflow.tint,
                primaryTitle: applyChanges ? "执行并写回" : "开始 dry-run",
                primarySystemImage: applyChanges ? "wand.and.stars.inverse" : "play.fill",
                canRun: canRun,
                runner: runner,
                primaryAction: run,
                accessoryActions: [
                    DockAction(
                        title: "打开报告目录",
                        systemImage: "folder",
                        isEnabled: !reportDirectory.trimmed.isEmpty
                    ) {
                        OpenPanelHelper.open(reportDirectory)
                    },
                ]
            )
        }
    }

    private func applyLocalizedLiteralDefaults() {
        guard !projectRoot.trimmed.isEmpty else {
            return
        }

        let root = URL(fileURLWithPath: UserPath.normalize(projectRoot))
        sourceRoot = root.appendingPathComponent("Renogy").path
        commentsFile = root.appendingPathComponent("Renogy/Localizables/zh-Hans.lproj/Localizable.strings").path
        secondaryCommentsFile = root.appendingPathComponent("Renogy/Localizables/en.lproj/Localizable.strings").path
        reportDirectory = root.appendingPathComponent("reports").path
    }

    private func syncProjectRootFromStoreIfNeeded() {
        let normalized = UserPath.normalize(projectRootStore.path)
        guard !normalized.isEmpty else {
            if projectRoot.trimmed.isEmpty {
                lastSeededProjectRoot = ""
            }
            return
        }

        let shouldReseed = projectRoot.trimmed.isEmpty || normalized != lastSeededProjectRoot
        guard shouldReseed else {
            return
        }

        projectRoot = normalized
        applyLocalizedLiteralDefaults()
        lastSeededProjectRoot = normalized
    }

    private func setProjectRoot(_ newPath: String, applyDefaults: Bool) {
        let normalized = UserPath.normalize(newPath)
        projectRoot = normalized
        projectRootStore.setPath(normalized)

        guard !normalized.isEmpty else {
            lastSeededProjectRoot = ""
            return
        }

        if applyDefaults || normalized != lastSeededProjectRoot {
            applyLocalizedLiteralDefaults()
            lastSeededProjectRoot = normalized
        }
    }

    private func run() {
        guard UserPath.isDirectory(projectRoot) else {
            runner.presentSetupError(projectRoot.trimmed.isEmpty ? "请先设置项目根目录。" : "项目根目录不存在：\(projectRoot.trimmed)")
            return
        }
        guard !commentsFile.trimmed.isEmpty else {
            runner.presentSetupError("请先指定 Primary 注释文件。")
            return
        }
        guard !reportDirectory.trimmed.isEmpty else {
            runner.presentSetupError("请先指定报告目录。")
            return
        }

        var args = [
            "--project-root", UserPath.normalize(projectRoot),
            "--source-root", UserPath.normalize(sourceRoot.trimmedOr("Renogy")),
            "--comments-file", UserPath.normalize(commentsFile),
            "--report-dir", UserPath.normalize(reportDirectory),
            "--missing-comment-fallback", fallback.rawValue,
        ]
        if !secondaryCommentsFile.trimmed.isEmpty {
            args += ["--secondary-comments-file", UserPath.normalize(secondaryCommentsFile)]
        }
        if applyChanges {
            args.append("--apply")
        }
        args += sourcePaths.map(UserPath.normalize)

        do {
            let request = try PythonBridge.request(
                scriptName: "migrate_localized_literals_to_nslocalizedstring.py",
                arguments: args,
                workingDirectory: UserPath.url(from: projectRoot)
            )
            runner.run(request)
        } catch {
            runner.presentSetupError(error.localizedDescription)
        }
    }
}

struct MigrateI18nKeysView: View {
    private let workflow = Workflow.migrateI18nKeys
    @Binding var selection: Workflow?
    @EnvironmentObject private var projectRootStore: ProjectRootStore

    @StateObject private var runner = ProcessRunner()

    @State private var projectRoot = ""
    @State private var lastSeededProjectRoot = ""
    @State private var mapFile = ""
    @State private var localizableDirectory = ""
    @State private var englishLocalizable = ""
    @State private var reportDirectory = ""
    @State private var sourceDirectory = ""
    @State private var applyChanges = false

    private var canRun: Bool {
        UserPath.isDirectory(projectRoot) &&
        !mapFile.trimmed.isEmpty &&
        !localizableDirectory.trimmed.isEmpty &&
        !reportDirectory.trimmed.isEmpty &&
        !sourceDirectory.trimmed.isEmpty &&
        !runner.isRunning
    }

    private var projectRootBinding: Binding<String> {
        Binding(
            get: { projectRoot },
            set: { setProjectRoot($0, applyDefaults: false) }
        )
    }

    private var projectRootDetail: String {
        if projectRoot.trimmed.isEmpty {
            return "请先设置项目根目录。"
        }
        if !UserPath.isDirectory(projectRoot) {
            return "目录不存在：\(projectRoot.trimmed)"
        }
        return projectRoot.trimmed
    }

    private var metrics: [WorkflowMetric] {
        [
            WorkflowMetric(title: "Mode", value: applyChanges ? "Apply" : "Report Only", caption: "是否真正执行替换"),
            WorkflowMetric(title: "Map", value: mapFile.trimmed.isEmpty ? "未配置" : "已配置", caption: "map.strings 是否就绪"),
            WorkflowMetric(title: "Reports", value: "CSV + JSON", caption: "会输出多份迁移分析报告"),
        ]
    }

    private var readinessItems: [ChecklistItem] {
        [
            ChecklistItem(title: "项目根目录", detail: projectRootDetail, isReady: UserPath.isDirectory(projectRoot)),
            ChecklistItem(title: "map.strings", detail: mapFile.trimmed.isEmpty ? "请选择映射文件。" : mapFile.trimmed, isReady: !mapFile.trimmed.isEmpty),
            ChecklistItem(title: "Localizables 目录", detail: localizableDirectory.trimmed.isEmpty ? "请选择目录。" : localizableDirectory.trimmed, isReady: !localizableDirectory.trimmed.isEmpty),
            ChecklistItem(title: "源码目录", detail: sourceDirectory.trimmed.isEmpty ? "请选择源码目录。" : sourceDirectory.trimmed, isReady: !sourceDirectory.trimmed.isEmpty),
        ]
    }

    var body: some View {
        WorkflowPage(workflow: workflow, selection: $selection, metrics: metrics) {
            ReadinessCard(accent: workflow.tint, items: readinessItems)

            TipsCard(
                title: "迁移提示",
                accent: workflow.tint,
                tips: [
                    "这个流程依赖 value 对齐逻辑，所以英文 Localizable.strings 的质量会直接影响结果。",
                    "先看 deterministic / ambiguous / missing 三类报告，再决定是否开启 apply。",
                    "如果 strings 里已经存在 old_key 和 new_key 同时出现的情况，脚本会把它们单独记为冲突。",
                ]
            )

            ConsoleCard(accent: workflow.tint, runner: runner)
        } content: {
            SectionCard(
                title: "项目配置",
                subtitle: "这个工作流依赖 map.strings、英文 Localizable.strings 和源码目录。",
                accent: workflow.tint
            ) {
                HStack(alignment: .top, spacing: 16) {
                    PathField(
                        title: "项目根目录",
                        prompt: "/path/to/project",
                        text: projectRootBinding,
                        browseLabel: "选择目录"
                    ) {
                        if let selection = OpenPanelHelper.chooseDirectory(title: "选择项目根目录") {
                            setProjectRoot(selection, applyDefaults: true)
                        }
                    }

                    PathField(
                        title: "源码目录",
                        prompt: "/path/to/source",
                        text: $sourceDirectory,
                        browseLabel: "选择目录"
                    ) {
                        sourceDirectory = OpenPanelHelper.chooseDirectory(title: "选择源码目录") ?? sourceDirectory
                    }
                }

                HStack {
                    Button("按项目根目录填充默认路径") {
                        applyI18nDefaults()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                HStack(alignment: .top, spacing: 16) {
                    PathField(
                        title: "map.strings",
                        prompt: "/path/to/map.strings",
                        text: $mapFile,
                        browseLabel: "选择文件"
                    ) {
                        mapFile = OpenPanelHelper.chooseFile(
                            title: "选择 map.strings",
                            allowedTypes: [stringsType]
                        ) ?? mapFile
                    }

                    PathField(
                        title: "Localizables 目录",
                        prompt: "/path/to/Localizables",
                        text: $localizableDirectory,
                        browseLabel: "选择目录"
                    ) {
                        localizableDirectory = OpenPanelHelper.chooseDirectory(title: "选择 Localizables 目录") ?? localizableDirectory
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    PathField(
                        title: "英文 Localizable.strings",
                        prompt: "/path/to/en.lproj/Localizable.strings",
                        text: $englishLocalizable,
                        browseLabel: "选择文件"
                    ) {
                        englishLocalizable = OpenPanelHelper.chooseFile(
                            title: "选择英文 Localizable.strings",
                            allowedTypes: [stringsType]
                        ) ?? englishLocalizable
                    }

                    PathField(
                        title: "报告目录",
                        prompt: "/path/to/reports/i18n_key_migration",
                        text: $reportDirectory,
                        browseLabel: "选择目录"
                    ) {
                        reportDirectory = OpenPanelHelper.chooseDirectory(title: "选择报告目录") ?? reportDirectory
                    }
                }

                Toggle("直接应用替换", isOn: $applyChanges)
            }
        }
        .onAppear {
            syncProjectRootFromStoreIfNeeded()
        }
        .onChange(of: projectRootStore.path) { _ in
            syncProjectRootFromStoreIfNeeded()
        }
        .safeAreaInset(edge: .bottom) {
            FloatingExecutionDock(
                accent: workflow.tint,
                primaryTitle: applyChanges ? "执行并应用迁移" : "仅生成报告",
                primarySystemImage: applyChanges ? "wand.and.stars.inverse" : "play.fill",
                canRun: canRun,
                runner: runner,
                primaryAction: run,
                accessoryActions: [
                    DockAction(
                        title: "打开报告目录",
                        systemImage: "folder",
                        isEnabled: !reportDirectory.trimmed.isEmpty
                    ) {
                        OpenPanelHelper.open(reportDirectory)
                    },
                ]
            )
        }
    }

    private func applyI18nDefaults() {
        guard !projectRoot.trimmed.isEmpty else {
            return
        }

        let root = URL(fileURLWithPath: UserPath.normalize(projectRoot))
        mapFile = root.appendingPathComponent("map.strings").path
        localizableDirectory = root.appendingPathComponent("Renogy/Localizables").path
        englishLocalizable = root.appendingPathComponent("Renogy/Localizables/en.lproj/Localizable.strings").path
        sourceDirectory = root.appendingPathComponent("Renogy").path
        reportDirectory = root.appendingPathComponent("reports/i18n_key_migration").path
    }

    private func syncProjectRootFromStoreIfNeeded() {
        let normalized = UserPath.normalize(projectRootStore.path)
        guard !normalized.isEmpty else {
            if projectRoot.trimmed.isEmpty {
                lastSeededProjectRoot = ""
            }
            return
        }

        let shouldReseed = projectRoot.trimmed.isEmpty || normalized != lastSeededProjectRoot
        guard shouldReseed else {
            return
        }

        projectRoot = normalized
        applyI18nDefaults()
        lastSeededProjectRoot = normalized
    }

    private func setProjectRoot(_ newPath: String, applyDefaults: Bool) {
        let normalized = UserPath.normalize(newPath)
        projectRoot = normalized
        projectRootStore.setPath(normalized)

        guard !normalized.isEmpty else {
            lastSeededProjectRoot = ""
            return
        }

        if applyDefaults || normalized != lastSeededProjectRoot {
            applyI18nDefaults()
            lastSeededProjectRoot = normalized
        }
    }

    private func run() {
        guard UserPath.isDirectory(projectRoot) else {
            runner.presentSetupError(projectRoot.trimmed.isEmpty ? "请先设置项目根目录。" : "项目根目录不存在：\(projectRoot.trimmed)")
            return
        }
        guard !mapFile.trimmed.isEmpty else {
            runner.presentSetupError("请先选择 map.strings。")
            return
        }
        guard !localizableDirectory.trimmed.isEmpty else {
            runner.presentSetupError("请先选择 Localizables 目录。")
            return
        }
        guard !sourceDirectory.trimmed.isEmpty else {
            runner.presentSetupError("请先选择源码目录。")
            return
        }
        guard !reportDirectory.trimmed.isEmpty else {
            runner.presentSetupError("请先选择报告目录。")
            return
        }

        var args = [
            "--project-root", UserPath.normalize(projectRoot),
            "--map-file", UserPath.normalize(mapFile),
            "--localizable-dir", UserPath.normalize(localizableDirectory),
            "--report-dir", UserPath.normalize(reportDirectory),
            "--source-dir", UserPath.normalize(sourceDirectory),
        ]
        if !englishLocalizable.trimmed.isEmpty {
            args += ["--en-localizable", UserPath.normalize(englishLocalizable)]
        }
        if applyChanges {
            args.append("--apply")
        }

        do {
            let request = try PythonBridge.request(
                scriptName: "migrate_i18n_keys.py",
                arguments: args,
                workingDirectory: UserPath.url(from: projectRoot)
            )
            runner.run(request)
        } catch {
            runner.presentSetupError(error.localizedDescription)
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trimmedOr(_ fallback: String) -> String {
        let value = trimmed
        return value.isEmpty ? fallback : value
    }
}
