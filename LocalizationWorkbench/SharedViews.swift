import AppKit
import SwiftUI

struct WorkflowMetric: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let caption: String
}

struct ChecklistItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let isReady: Bool
}

struct AppBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.95, blue: 0.92),
                    Color(red: 0.98, green: 0.97, blue: 0.94),
                    Color.white,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 520, height: 520)
                .blur(radius: 24)
                .offset(x: 340, y: -300)

            RoundedRectangle(cornerRadius: 120)
                .fill(Color.black.opacity(0.03))
                .frame(width: 430, height: 220)
                .rotationEffect(.degrees(-14))
                .offset(x: -320, y: 260)

            Circle()
                .fill(Color.white.opacity(0.7))
                .frame(width: 360, height: 360)
                .blur(radius: 24)
                .offset(x: -460, y: -240)
        }
        .ignoresSafeArea()
    }
}

struct WorkflowPage<Content: View, Sidebar: View>: View {
    let workflow: Workflow
    let selection: Binding<Workflow?>?
    let metrics: [WorkflowMetric]
    @ViewBuilder var content: Content
    @ViewBuilder var sidebar: Sidebar

    init(
        workflow: Workflow,
        selection: Binding<Workflow?>? = nil,
        metrics: [WorkflowMetric] = [],
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder content: () -> Content
    ) {
        self.workflow = workflow
        self.selection = selection
        self.metrics = metrics
        self.content = content()
        self.sidebar = sidebar()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let selection {
                    WorkflowSwitchBar(workflow: workflow, selection: selection)
                }

                HeroHeader(workflow: workflow)

                if !metrics.isEmpty {
                    MetricStrip(accent: workflow.tint, metrics: metrics)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 18) {
                            content
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 18) {
                            sidebar
                        }
                        .frame(width: 344)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        sidebar
                        content
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

struct WorkflowSwitchBar: View {
    let workflow: Workflow
    let selection: Binding<Workflow?>

    private var tools: [Workflow] {
        Workflow.toolCases
    }

    private var currentIndex: Int? {
        tools.firstIndex(of: workflow)
    }

    private var previousWorkflow: Workflow? {
        guard let currentIndex, currentIndex > 0 else {
            return nil
        }
        return tools[currentIndex - 1]
    }

    private var nextWorkflow: Workflow? {
        guard let currentIndex, currentIndex + 1 < tools.count else {
            return nil
        }
        return tools[currentIndex + 1]
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                selection.wrappedValue = previousWorkflow
            } label: {
                Label("上一个", systemImage: "arrow.left")
            }
            .buttonStyle(.bordered)
            .disabled(previousWorkflow == nil)

            Button {
                selection.wrappedValue = nextWorkflow
            } label: {
                Label("下一个", systemImage: "arrow.right")
            }
            .buttonStyle(.bordered)
            .disabled(nextWorkflow == nil)

            Menu {
                ForEach(Workflow.toolCases) { item in
                    Button {
                        selection.wrappedValue = item
                    } label: {
                        Label(item.title, systemImage: item.symbolName)
                    }
                }
            } label: {
                Label("切换功能", systemImage: "square.grid.2x2")
            }
            .menuStyle(.borderlessButton)

            Spacer()

            if let currentIndex {
                Text("功能 \(currentIndex + 1) / \(tools.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.45))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.72), in: Capsule())
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(workflow.tint.opacity(0.12), lineWidth: 1)
        )
    }
}

struct HeroHeader: View {
    let workflow: Workflow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [workflow.tint.opacity(0.22), workflow.tint.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: workflow.symbolName)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(workflow.tint)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(workflow.title)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.88))

                        CapsuleLabel(
                            text: workflow.accentName,
                            accent: workflow.tint,
                            style: .solid
                        )
                    }

                    Text(workflow.subtitle)
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.66))
                        .frame(maxWidth: 760, alignment: .leading)

                    HStack(spacing: 10) {
                        CapsuleLabel(text: "本地执行", accent: workflow.tint, style: .outline)
                        CapsuleLabel(text: "Python 驱动", accent: workflow.tint, style: .outline)
                        CapsuleLabel(text: workflow.outputSummary, accent: workflow.tint, style: .outline)
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.92),
                    workflow.tint.opacity(0.08),
                    Color.white.opacity(0.86),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(workflow.tint.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 16, x: 0, y: 12)
    }
}

private enum CapsuleStyle {
    case solid
    case outline
}

private struct CapsuleLabel: View {
    let text: String
    let accent: Color
    let style: CapsuleStyle

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(style == .solid ? Color.white : Color.black.opacity(0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background)
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .solid:
            Capsule()
                .fill(accent)
        case .outline:
            Capsule()
                .fill(Color.white.opacity(0.72))
                .overlay(
                    Capsule()
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )
        }
    }
}

struct MetricStrip: View {
    let accent: Color
    let metrics: [WorkflowMetric]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 6) {
                    Text(metric.title.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.42))

                    Text(metric.value)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.82))

                    Text(metric.caption)
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.56))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color.white.opacity(0.94), accent.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(accent.opacity(0.14), lineWidth: 1)
                )
            }
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let accent: Color
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.86))

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.56))
                }
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(accent.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 14, x: 0, y: 10)
    }
}

struct RunCard<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder var content: Content

    init(title: String = "执行控制", accent: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        SectionCard(title: title, subtitle: "先看准备状态，再执行脚本。", accent: accent) {
            content
        }
    }
}

struct ReadinessCard: View {
    let accent: Color
    let items: [ChecklistItem]

    var body: some View {
        SectionCard(title: "准备状态", subtitle: "执行前需要满足这些条件。", accent: accent) {
            VStack(spacing: 10) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isReady ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(item.isReady ? Color.green : accent.opacity(0.75))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.black.opacity(0.8))
                            Text(item.detail)
                                .font(.system(size: 11, weight: .medium, design: .serif))
                                .foregroundStyle(Color.black.opacity(0.55))
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
}

struct TipsCard: View {
    let title: String
    let accent: Color
    let tips: [String]

    var body: some View {
        SectionCard(title: title, subtitle: nil, accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(index + 1))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .frame(width: 22, height: 22)
                            .background(accent, in: Circle())

                        Text(tip)
                            .font(.system(size: 12, weight: .medium, design: .serif))
                            .foregroundStyle(Color.black.opacity(0.68))

                        Spacer()
                    }
                }
            }
        }
    }
}

struct OverviewTile: View {
    let workflow: Workflow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(workflow.tint.opacity(0.14))
                        .frame(width: 42, height: 42)
                        .overlay {
                            Image(systemName: workflow.symbolName)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .foregroundStyle(workflow.tint)
                        }

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.35))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(workflow.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.84))

                    Text(workflow.subtitle)
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.58))
                        .lineLimit(3)
                }

                CapsuleLabel(text: workflow.outputSummary, accent: workflow.tint, style: .outline)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 192, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.white.opacity(0.92), workflow.tint.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(workflow.tint.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 12, x: 0, y: 10)
        }
        .buttonStyle(.plain)
    }
}

struct ParameterFieldCard<Content: View>: View {
    let title: String
    let description: String
    let example: String?
    @ViewBuilder var content: Content

    init(
        title: String,
        description: String,
        example: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.description = description
        self.example = example
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.78))

            Text(description)
                .font(.system(size: 11, weight: .medium, design: .serif))
                .foregroundStyle(Color.black.opacity(0.58))

            if let example, !example.isEmpty {
                Text(example)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.44))
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct ParameterToggleCard: View {
    let title: String
    let description: String
    let note: String?
    @Binding var isOn: Bool
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)

            Text(description)
                .font(.system(size: 11, weight: .medium, design: .serif))
                .foregroundStyle(Color.black.opacity(0.58))

            if let note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.44))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        .disabled(isDisabled)
    }
}

struct PathField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let browseLabel: String
    let browseAction: () -> Void

    private var displayText: String {
        text.trimmed.isEmpty ? prompt : text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.7))

                Spacer()

                if !text.trimmed.isEmpty {
                    Text(UserPath.lastComponent(text))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.4))
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(displayText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(text.trimmed.isEmpty ? Color.black.opacity(0.34) : Color.black.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )

                Button(browseLabel, action: browseAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.78))

                Button("粘贴") {
                    if let pasted = NSPasteboard.general.string(forType: .string)?.trimmed,
                       !pasted.isEmpty
                    {
                        text = pasted
                    }
                }
                .buttonStyle(.bordered)

                if !text.trimmed.isEmpty {
                    Button("打开") {
                        OpenPanelHelper.open(text)
                    }
                    .buttonStyle(.bordered)

                    Button("清空") {
                        text = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

struct PathListEditor: View {
    let title: String
    let subtitle: String?
    let addLabel: String
    let emptyText: String
    @Binding var items: [String]
    let addAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.7))

                        Text("\(items.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.black.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.06), in: Capsule())
                    }

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium, design: .serif))
                            .foregroundStyle(Color.black.opacity(0.52))
                    }
                }

                Spacer()

                Button(addLabel, action: addAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.black.opacity(0.78))
            }

            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.48))
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(items, id: \.self) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(URL(fileURLWithPath: item).lastPathComponent)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.black.opacity(0.82))

                                Text(item)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Color.black.opacity(0.56))
                            }

                            Spacer()

                            Button("打开") {
                                OpenPanelHelper.open(item)
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                items.removeAll { $0 == item }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }
}

struct ConsoleCard: View {
    let accent: Color
    @ObservedObject var runner: ProcessRunner

    var body: some View {
        SectionCard(
            title: "控制台",
            subtitle: "这里显示脚本实际命令、标准输出和标准错误。",
            accent: accent
        ) {
            HStack {
                ExecutionStatusBadge(accent: accent, runner: runner)

                Spacer()

                if runner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("清空") {
                    runner.clear()
                }
                .buttonStyle(.bordered)

                if runner.isRunning {
                    Button("终止") {
                        runner.cancel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.red.opacity(0.85))
                }
            }

            if !runner.commandLine.isEmpty {
                Text(runner.commandLine)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.58))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }

            ScrollView {
                Text(runner.output.isEmpty ? "尚未执行任何脚本。" : runner.output)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 180, maxHeight: 280)
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.86), Color.black.opacity(0.74)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
    }
}

struct FloatingExecutionDock: View {
    let accent: Color
    let primaryTitle: String
    let primarySystemImage: String
    let canRun: Bool
    @ObservedObject var runner: ProcessRunner
    let primaryAction: () -> Void
    let accessoryActions: [DockAction]

    var body: some View {
        HStack(spacing: 12) {
            ExecutionStatusBadge(accent: accent, runner: runner, large: true)

            Spacer(minLength: 0)

            ForEach(accessoryActions) { item in
                Button {
                    item.action()
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
                .buttonStyle(.bordered)
                .disabled(!item.isEnabled)
            }

            if runner.isRunning {
                Button {
                    runner.cancel()
                } label: {
                    Label("终止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(Color.red.opacity(0.82))
            }

            Button {
                primaryAction()
            } label: {
                Label(runner.isRunning ? "执行中" : primaryTitle, systemImage: runner.isRunning ? "hourglass" : primarySystemImage)
                    .frame(minWidth: 138)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(!canRun)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(accent.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }
}

struct DockAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void
}

struct ExecutionStatusBadge: View {
    let accent: Color
    @ObservedObject var runner: ProcessRunner
    var large = false

    @State private var pulse = false

    private var phase: RunnerPhase {
        if runner.isRunning {
            return .running
        }
        if let exitCode = runner.lastExitCode {
            return exitCode == 0 ? .success : .failure
        }
        return .idle
    }

    private var title: String {
        switch phase {
        case .idle:
            return "待执行"
        case .running:
            return "执行中"
        case .success:
            return "执行成功"
        case .failure:
            return "执行失败"
        }
    }

    private var subtitle: String {
        switch phase {
        case .idle:
            return "准备好后可直接开始"
        case .running:
            return "脚本正在后台运行"
        case .success:
            return "本次执行已完成"
        case .failure:
            if let exitCode = runner.lastExitCode {
                return "退出码 \(exitCode)"
            }
            return "请检查控制台输出"
        }
    }

    private var symbolName: String {
        switch phase {
        case .idle:
            return "sparkles"
        case .running:
            return "bolt.fill"
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch phase {
        case .idle:
            return Color.black.opacity(0.6)
        case .running:
            return accent
        case .success:
            return Color.green
        case .failure:
            return Color.red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.14))
                    .frame(width: large ? 42 : 30, height: large ? 42 : 30)

                Circle()
                    .stroke(color.opacity(pulse ? 0.02 : 0.24), lineWidth: 2)
                    .frame(width: large ? 50 : 36, height: large ? 50 : 36)
                    .scaleEffect(pulse ? 1.12 : 0.92)

                Image(systemName: symbolName)
                    .font(.system(size: large ? 18 : 14, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .scaleEffect(pulse ? 1.08 : 1.0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: large ? 14 : 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.84))

                Text(subtitle)
                    .font(.system(size: large ? 11 : 10, weight: .medium, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.52))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.7), value: pulse)
        .onAppear {
            triggerPulse()
        }
        .onChange(of: runner.isRunning) { _ in
            triggerPulse()
        }
        .onChange(of: runner.lastExitCode) { _ in
            triggerPulse()
        }
    }

    private func triggerPulse() {
        pulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            pulse = false
        }
    }
}

private enum RunnerPhase {
    case idle
    case running
    case success
    case failure
}

struct ProjectRootSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var projectRootStore: ProjectRootStore
    let allowsSkipping: Bool

    private var projectRootBinding: Binding<String> {
        Binding(
            get: { projectRootStore.path },
            set: { projectRootStore.setPath($0) }
        )
    }

    private var statusColor: Color {
        projectRootStore.hasValidPath ? Color.green.opacity(0.82) : Color.orange.opacity(0.9)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设置项目根目录")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("迁移类功能会基于这个目录自动填充源码、注释文件和报告路径。")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if allowsSkipping {
                    Button("稍后") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.black.opacity(0.82))
                .disabled(!projectRootStore.hasValidPath)
            }
            .padding(20)
            .background(.ultraThinMaterial)

            VStack(alignment: .leading, spacing: 18) {
                PathField(
                    title: "目标项目根目录",
                    prompt: "/path/to/your/app/project",
                    text: projectRootBinding,
                    browseLabel: "选择目录"
                ) {
                    if let selection = OpenPanelHelper.chooseDirectory(title: "选择项目根目录") {
                        projectRootStore.setPath(selection)
                    }
                }

                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(projectRootStore.detailText)
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.62))
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("说明")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))

                    Text("这个设置主要影响“.localized 迁移”和“i18n key 迁移”。如果切换到另一个业务工程，只需要在这里改一次。")
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .foregroundStyle(Color.black.opacity(0.62))
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .background(
                LinearGradient(
                    colors: [Color.white, Color(red: 0.98, green: 0.97, blue: 0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .frame(minWidth: 780, minHeight: 360)
    }
}

struct ReadmeSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var markdownText: String {
        EmbeddedReadmeLoader.markdown
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("使用说明")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("README 已经打进 app 内，可直接在这里查看。")
                        .font(.system(size: 12, weight: .medium, design: .serif))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.black.opacity(0.82))
            }
            .padding(20)
            .background(.ultraThinMaterial)

            ScrollView {
                Text(markdownText)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.84))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .background(
                LinearGradient(
                    colors: [Color.white, Color(red: 0.98, green: 0.97, blue: 0.94)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .frame(minWidth: 760, minHeight: 640)
    }
}

enum EmbeddedReadmeLoader {
    static var markdown: String {
        if let bundledURL = Bundle.main.url(forResource: "README", withExtension: "md"),
           let content = try? String(contentsOf: bundledURL, encoding: .utf8)
        {
            return content
        }

        if let workspacePath = WorkspaceLocator.readmePath,
           let content = try? String(contentsOfFile: workspacePath, encoding: .utf8)
        {
            return content
        }

        return """
        # Localization Workbench

        未找到 README 资源。请检查 app bundle 是否已包含 README.md。
        """
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
