import AppKit
import Foundation
import UniformTypeIdentifiers

struct ProcessRequest {
    let executablePath: String
    let arguments: [String]
    let workingDirectory: URL?
    let environment: [String: String]

    var commandLine: String {
        ([executablePath] + arguments).map(Self.shellEscape).joined(separator: " ")
    }

    private static func shellEscape(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else {
            return value
        }

        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum PythonBridgeError: LocalizedError {
    case pythonNotFound
    case scriptNotFound(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "找不到可用的 Python 3 解释器。"
        case .scriptNotFound(let name):
            return "找不到脚本：\(name)"
        }
    }
}

enum UserPath {
    static func normalize(_ rawValue: String) -> String {
        NSString(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
            .expandingTildeInPath
    }

    static func url(from rawValue: String) -> URL? {
        let normalized = normalize(rawValue)
        guard !normalized.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: normalized)
    }

    static func existingPath(_ rawValue: String) -> String? {
        let normalized = normalize(rawValue)
        guard !normalized.isEmpty else {
            return nil
        }
        return FileManager.default.fileExists(atPath: normalized) ? normalized : nil
    }

    static func exists(_ rawValue: String) -> Bool {
        existingPath(rawValue) != nil
    }

    static func isDirectory(_ rawValue: String) -> Bool {
        let normalized = normalize(rawValue)
        guard !normalized.isEmpty else {
            return false
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    static func lastComponent(_ rawValue: String) -> String {
        let normalized = normalize(rawValue)
        guard !normalized.isEmpty else {
            return ""
        }
        return URL(fileURLWithPath: normalized).lastPathComponent
    }

    static func deduplicated(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []

        for item in items.map(normalize).filter({ !$0.isEmpty }) {
            if seen.insert(item).inserted {
                ordered.append(item)
            }
        }

        return ordered
    }
}

final class ProjectRootStore: ObservableObject {
    private static let defaultsKey = "LocalizationWorkbench.SelectedProjectRoot"

    @Published private(set) var path: String

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        let normalized = UserPath.normalize(stored)
        path = normalized
    }

    var hasPath: Bool {
        !path.isEmpty
    }

    var hasValidPath: Bool {
        UserPath.isDirectory(path)
    }

    var shouldPromptAtLaunch: Bool {
        !hasValidPath
    }

    var titleText: String {
        hasValidPath ? UserPath.lastComponent(path) : "未设置项目根目录"
    }

    var detailText: String {
        if hasValidPath {
            return path
        }
        if hasPath {
            return "目录无效：\(path)"
        }
        return "建议先设置目标项目根目录，迁移类功能会自动带默认路径。"
    }

    func setPath(_ rawValue: String) {
        let normalized = UserPath.normalize(rawValue)
        path = normalized

        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.set(normalized, forKey: Self.defaultsKey)
        }
    }
}

enum WorkspaceLocator {
    private static let rootMarkerSets: [[String]] = [
        ["Package.swift", "README.md"],
        ["build_app.sh", "README.md"],
        ["LocalizationWorkbench.xcodeproj", "README.md"],
        ["build_with_xcode.sh", "README.md"],
    ]

    static var projectRootURL: URL? {
        if let environmentRoot = ProcessInfo.processInfo.environment["LOCALIZATION_WORKBENCH_PROJECT_ROOT"] {
            let normalized = UserPath.normalize(environmentRoot)
            if FileManager.default.fileExists(atPath: normalized) {
                return URL(fileURLWithPath: normalized, isDirectory: true)
            }
        }

        let bundleContainer = Bundle.main.bundleURL.deletingLastPathComponent()
        if let located = locateRoot(startingAt: bundleContainer) {
            return located
        }

        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        if let located = locateRoot(startingAt: sourceDirectory) {
            return located
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if let located = locateRoot(startingAt: cwd) {
            return located
        }

        return FileManager.default.fileExists(atPath: bundleContainer.path) ? bundleContainer : cwd
    }

    static var projectRootPath: String {
        projectRootURL?.path ?? FileManager.default.currentDirectoryPath
    }

    static var readmePath: String? {
        firstExistingPath(["README.md"])
    }

    static var buildScriptPath: String? {
        firstExistingPath(["build_app.sh", "build_with_xcode.sh"])
    }

    static var buildArtifactsPath: String? {
        firstExistingPath([
            "dist",
            "build/Build/Products/Release",
            "build/Build/Products/Debug",
        ])
    }

    static func projectRelativePath(_ relativePath: String) -> String {
        let normalized = UserPath.normalize(relativePath)
        guard !normalized.isEmpty else {
            return projectRootPath
        }
        guard !normalized.hasPrefix("/") else {
            return normalized
        }
        guard let root = projectRootURL else {
            return normalized
        }
        return root.appendingPathComponent(normalized).path
    }

    static func openProjectRelative(_ relativePath: String) {
        let candidate = projectRelativePath(relativePath)
        if FileManager.default.fileExists(atPath: candidate) {
            OpenPanelHelper.open(candidate)
            return
        }
        OpenPanelHelper.open(projectRootPath)
    }

    private static func firstExistingPath(_ relativePaths: [String]) -> String? {
        for relativePath in relativePaths {
            let candidate = projectRelativePath(relativePath)
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func locateRoot(startingAt startURL: URL) -> URL? {
        var current = startURL.standardizedFileURL

        while true {
            if isKnownRoot(current) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }

    private static func isKnownRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return rootMarkerSets.contains { markers in
            markers.allSatisfy { marker in
                fileManager.fileExists(atPath: url.appendingPathComponent(marker).path)
            }
        }
    }
}

enum PythonBridge {
    static func request(
        scriptName: String,
        arguments: [String],
        workingDirectory: URL? = nil
    ) throws -> ProcessRequest {
        guard let pythonPath = pythonExecutablePath() else {
            throw PythonBridgeError.pythonNotFound
        }
        guard let scriptURL = scriptURL(named: scriptName) else {
            throw PythonBridgeError.scriptNotFound(scriptName)
        }

        return ProcessRequest(
            executablePath: pythonPath,
            arguments: [scriptURL.path] + arguments,
            workingDirectory: workingDirectory,
            environment: ["PYTHONDONTWRITEBYTECODE": "1"]
        )
    }

    private static func pythonExecutablePath() -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        let fileManager = FileManager.default
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }

    private static func scriptURL(named scriptName: String) -> URL? {
        let fileManager = FileManager.default

        if let bundledRoot = Bundle.main.resourceURL?
            .appendingPathComponent("Python", isDirectory: true)
        {
            let bundledScript = bundledRoot.appendingPathComponent(scriptName)
            if fileManager.fileExists(atPath: bundledScript.path) {
                return bundledScript
            }
        }

        if let projectRoot = WorkspaceLocator.projectRootURL {
            let rootScript = projectRoot.appendingPathComponent(scriptName)
            if fileManager.fileExists(atPath: rootScript.path) {
                return rootScript
            }

            let projectResourceScript = projectRoot
                .appendingPathComponent("LocalizationWorkbench/Resources/Python", isDirectory: true)
                .appendingPathComponent(scriptName)
            if fileManager.fileExists(atPath: projectResourceScript.path) {
                return projectResourceScript
            }
        }

        return nil
    }
}

@MainActor
final class ProcessRunner: ObservableObject {
    @Published var output = ""
    @Published var commandLine = ""
    @Published var isRunning = false
    @Published var lastExitCode: Int32?
    @Published var launchError: String?

    private var process: Process?

    func clear() {
        output = ""
        commandLine = ""
        lastExitCode = nil
        launchError = nil
    }

    func presentSetupError(_ message: String) {
        clear()
        launchError = message
        output = message + "\n"
    }

    func run(_ request: ProcessRequest) {
        cancel()

        clear()
        isRunning = true
        commandLine = request.commandLine

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.executablePath)
        process.arguments = request.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, new in new }
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        attach(pipe: stdout, prefix: "")
        attach(pipe: stderr, prefix: "[stderr] ")

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.lastExitCode = process.terminationStatus
                self?.append("\n[exit] \(process.terminationStatus)\n")
                self?.process = nil
            }
        }

        do {
            try process.run()
            self.process = process
            append("[start] \(request.commandLine)\n")
        } catch {
            isRunning = false
            lastExitCode = -1
            launchError = error.localizedDescription
            append("[launch error] \(error.localizedDescription)\n")
        }
    }

    func cancel() {
        guard let process, process.isRunning else {
            return
        }
        process.terminate()
        append("\n[cancel] 用户终止了当前任务。\n")
    }

    private func attach(pipe: Pipe, prefix: String) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }

            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.append(prefix + text)
            }
        }
    }

    private func append(_ text: String) {
        output.append(text)
        if output.count > 240_000 {
            output = String(output.suffix(180_000))
        }
    }
}

enum OpenPanelHelper {
    @MainActor
    static func chooseFile(
        title: String,
        allowedTypes: [UTType] = []
    ) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = allowedTypes
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor
    static func saveFile(
        title: String,
        suggestedName: String,
        allowedTypes: [UTType] = []
    ) -> String? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = allowedTypes
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor
    static func chooseDirectory(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    @MainActor
    static func chooseFiles(
        title: String,
        allowedTypes: [UTType] = []
    ) -> [String] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = allowedTypes
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    @MainActor
    static func chooseFileSystemItems(title: String) -> [String] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }

    static func open(_ rawPath: String) {
        guard let url = UserPath.url(from: rawPath) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
