//
//  CloudImport.swift
//  LocalizationWorkbench
//
//  Author: Renogy_YX
//

import Combine
import Foundation
import Security

/// 云端工作簿提供方。后续接入其他平台时只需新增枚举项和对应 Provider。
enum CloudWorkbookProviderKind: String, Codable, CaseIterable, Identifiable {
    case dingTalkMCP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dingTalkMCP:
            return "钉钉 AI 表格"
        }
    }

    var symbolName: String {
        switch self {
        case .dingTalkMCP:
            return "tablecells.badge.ellipsis"
        }
    }
}

enum DingTalkExportScope: String, Codable, CaseIterable, Identifiable {
    case all
    case table
    case view

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "整份 Base"
        case .table:
            return "指定 Sheet"
        case .view:
            return "指定视图"
        }
    }

    var detail: String {
        switch self {
        case .all:
            return "导出链接所属的整份 AI 表格"
        case .table:
            return "仅导出指定 Sheet"
        case .view:
            return "仅导出指定 Sheet 中的视图"
        }
    }
}

/// 统一保存数据源的公共字段，提供方私有参数收敛在 settings，避免后续扩展破坏已有数据。
struct CloudWorkbookSource: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var provider: CloudWorkbookProviderKind
    var link: String
    var settings: [String: String]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        provider: CloudWorkbookProviderKind,
        link: String,
        settings: [String: String],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.link = link
        self.settings = settings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var summary: String {
        switch provider {
        case .dingTalkMCP:
            guard let configuration = try? DingTalkExportConfiguration(source: self) else {
                return "钉钉链接配置不完整"
            }
            return "Base \(configuration.baseID) · \(configuration.scope.title)"
        }
    }
}

struct DingTalkExportConfiguration: Equatable {
    private enum SettingKey {
        static let baseID = "baseID"
        static let scope = "scope"
        static let tableID = "tableID"
        static let viewID = "viewID"
    }

    let baseID: String
    let scope: DingTalkExportScope
    let tableID: String
    let viewID: String

    init(baseID: String, scope: DingTalkExportScope, tableID: String = "", viewID: String = "") throws {
        self.baseID = baseID.cloudImportTrimmed
        self.scope = scope
        self.tableID = tableID.cloudImportTrimmed
        self.viewID = viewID.cloudImportTrimmed
        try validate()
    }

    init(source: CloudWorkbookSource) throws {
        guard source.provider == .dingTalkMCP else {
            throw CloudImportError.unsupportedProvider(source.provider.title)
        }
        guard let rawScope = source.settings[SettingKey.scope],
              let scope = DingTalkExportScope(rawValue: rawScope)
        else {
            throw CloudImportError.invalidSourceConfiguration("缺少导出范围")
        }

        try self.init(
            baseID: source.settings[SettingKey.baseID] ?? "",
            scope: scope,
            tableID: source.settings[SettingKey.tableID] ?? "",
            viewID: source.settings[SettingKey.viewID] ?? ""
        )
    }

    var settings: [String: String] {
        [
            SettingKey.baseID: baseID,
            SettingKey.scope: scope.rawValue,
            SettingKey.tableID: tableID,
            SettingKey.viewID: viewID,
        ]
    }

    /// 同一导出目标始终使用同一个键，与用户给链接取的显示名无关。
    var downloadSourceKey: String {
        ["dingTalkMCP", baseID, scope.rawValue, tableID, viewID]
            .joined(separator: "|")
    }

    /// 文件名只来自云端标识，用户修改链接显示名时仍能覆盖同一份下载文件。
    var downloadFileStem: String {
        switch scope {
        case .all:
            return "DingTalk-\(baseID)-Base"
        case .table:
            return "DingTalk-\(baseID)-Sheet-\(tableID)"
        case .view:
            return "DingTalk-\(baseID)-Sheet-\(tableID)-View-\(viewID)"
        }
    }

    func validate() throws {
        guard !baseID.isEmpty else {
            throw CloudImportError.invalidSourceConfiguration("缺少钉钉 Base ID")
        }
        if scope == .table || scope == .view, tableID.isEmpty {
            throw CloudImportError.invalidSourceConfiguration("指定 Sheet 或视图时必须填写 Sheet ID")
        }
        if scope == .view, viewID.isEmpty {
            throw CloudImportError.invalidSourceConfiguration("指定视图时必须填写 View ID")
        }
    }
}

@MainActor
final class CloudWorkbookSourceStore: ObservableObject {
    @Published private(set) var sources: [CloudWorkbookSource]

    private static let defaultsKey = "LocalizationWorkbench.CloudImport.sources"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let savedSources = try? JSONDecoder().decode([CloudWorkbookSource].self, from: data)
        else {
            sources = []
            return
        }
        sources = savedSources.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ source: CloudWorkbookSource) {
        var updatedSource = source
        updatedSource.updatedAt = Date()

        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = updatedSource
        } else {
            sources.insert(updatedSource, at: 0)
        }
        persist()
    }

    func delete(_ source: CloudWorkbookSource) {
        sources.removeAll { $0.id == source.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

enum CloudImportError: LocalizedError {
    case invalidSourceConfiguration(String)
    case invalidDingTalkLink
    case invalidMCPAddress
    case missingDingTalkConnection
    case unsupportedProvider(String)
    case downloadDirectoryUnavailable(String)
    case unsupportedDownloadPayload
    case noWorkbookExtracted

    var errorDescription: String? {
        switch self {
        case let .invalidSourceConfiguration(message):
            return "云端链接配置无效：\(message)"
        case .invalidDingTalkLink:
            return "无法从链接中识别钉钉 Base ID，请确认使用钉钉 AI 表格的在线文档链接。"
        case .invalidMCPAddress:
            return "MCP 连接地址必须是有效的 HTTPS 地址。"
        case .missingDingTalkConnection:
            return "请先连接自己的钉钉 AI 表格 MCP。"
        case let .unsupportedProvider(provider):
            return "暂不支持云端提供方：\(provider)"
        case let .downloadDirectoryUnavailable(path):
            return "无法使用下载目录：\(path)"
        case .unsupportedDownloadPayload:
            return "钉钉返回的下载内容不是可识别的 Excel 或 ZIP 文件。"
        case .noWorkbookExtracted:
            return "下载包内没有可导入的 .xlsx 文件。"
        }
    }
}

/// 钉钉在线文档链接的解析结果。链接本身不包含凭据，只用于提取 Base、Sheet 和 View 标识。
struct DingTalkDocumentReference: Equatable {
    let baseID: String
    let tableID: String
    let viewID: String

    var inferredScope: DingTalkExportScope {
        if !tableID.isEmpty, !viewID.isEmpty {
            return .view
        }
        if !tableID.isEmpty {
            return .table
        }
        return .all
    }

    static func parse(_ rawLink: String) throws -> DingTalkDocumentReference {
        let trimmedLink = rawLink.cloudImportTrimmed
        guard let components = URLComponents(string: trimmedLink),
              let host = components.host?.lowercased(),
              host == "dingtalk.com" || host.hasSuffix(".dingtalk.com")
        else {
            throw CloudImportError.invalidDingTalkLink
        }

        let pathComponents = components.path.split(separator: "/").map(String.init)
        guard let nodesIndex = pathComponents.firstIndex(of: "nodes"),
              pathComponents.indices.contains(nodesIndex + 1)
        else {
            throw CloudImportError.invalidDingTalkLink
        }

        let baseID = pathComponents[nodesIndex + 1].cloudImportTrimmed
        guard !baseID.isEmpty else {
            throw CloudImportError.invalidDingTalkLink
        }

        var values = queryValues(from: components.queryItems ?? [])
        if let iframeQuery = values["iframeQuery"]?.removingPercentEncoding ?? values["iframeQuery"],
           let iframeComponents = URLComponents(string: "https://localhost/?\(iframeQuery)")
        {
            values.merge(queryValues(from: iframeComponents.queryItems ?? [])) { current, _ in current }
        }

        return DingTalkDocumentReference(
            baseID: baseID,
            tableID: values["sheetId"]?.cloudImportTrimmed ?? "",
            viewID: values["viewId"]?.cloudImportTrimmed ?? ""
        )
    }

    private static func queryValues(from items: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in items where values[item.name] == nil {
            if let value = item.value {
                values[item.name] = value
            }
        }
        return values
    }
}

private enum KeychainStringStore {
    static func read(service: String, account: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return value
    }

    static func save(_ value: String, service: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw CloudImportError.invalidMCPAddress
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus))
        }

        var item = query
        for (key, value) in attributes {
            item[key] = value
        }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
        }
    }

    static func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

struct LocalDingTalkMCPConnectionCandidate: Identifiable, Equatable {
    let id = UUID()
    let sourceNames: [String]
    let endpoint: String

    var title: String {
        sourceNames.joined(separator: "、")
    }
}

enum DingTalkMCPConnectionState: Equatable {
    case disconnected
    case verifying
    case connected(host: String)
    case failed(String)
}

@MainActor
final class DingTalkMCPConnectionStore: ObservableObject {
    @Published private(set) var state: DingTalkMCPConnectionState

    private static let keychainService = "local.tools.LocalizationWorkbench.DingTalkMCP"
    private static let keychainAccount = "connectionURL"

    init() {
        do {
            if let rawAddress = try KeychainStringStore.read(
                service: Self.keychainService,
                account: Self.keychainAccount
            ), let url = try? Self.validatedEndpoint(from: rawAddress)
            {
                state = .connected(host: url.host ?? "钉钉 MCP")
            } else {
                state = .disconnected
            }
        } catch {
            state = .failed("无法读取本机钥匙串中的钉钉连接。")
        }
    }

    var isConnected: Bool {
        if case .connected = state {
            return true
        }
        return false
    }

    var statusTitle: String {
        switch state {
        case .disconnected:
            return "尚未连接"
        case .verifying:
            return "正在验证"
        case .connected:
            return "已连接"
        case .failed:
            return "连接失败"
        }
    }

    var statusDetail: String {
        switch state {
        case .disconnected:
            return "每位用户需要连接自己的钉钉 AI 表格 MCP。"
        case .verifying:
            return "正在确认 MCP 是否具备 Excel 导出能力。"
        case let .connected(host):
            return "已安全保存至系统钥匙串（\(host)）。"
        case let .failed(message):
            return message
        }
    }

    @discardableResult
    func connect(endpoint rawEndpoint: String) async -> Bool {
        state = .verifying
        do {
            let endpoint = try Self.validatedEndpoint(from: rawEndpoint)
            try await DingTalkMCPClient(endpoint: endpoint).validate()
            try KeychainStringStore.save(
                endpoint.absoluteString,
                service: Self.keychainService,
                account: Self.keychainAccount
            )
            state = .connected(host: endpoint.host ?? "钉钉 MCP")
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    func disconnect() {
        do {
            try KeychainStringStore.delete(service: Self.keychainService, account: Self.keychainAccount)
            state = .disconnected
        } catch {
            state = .failed("移除钉钉连接失败：\(error.localizedDescription)")
        }
    }

    func endpointURL() throws -> URL {
        guard let endpoint = try KeychainStringStore.read(
            service: Self.keychainService,
            account: Self.keychainAccount
        ) else {
            throw CloudImportError.missingDingTalkConnection
        }
        return try Self.validatedEndpoint(from: endpoint)
    }

    func findLocalCandidates() -> [LocalDingTalkMCPConnectionCandidate] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let jsonConfigurations = [
            ("Claude", homeDirectory.appendingPathComponent(".claude/.mcp.json")),
            ("Qoder", homeDirectory.appendingPathComponent(".qoder/settings.json")),
            ("Qoder-CN", homeDirectory.appendingPathComponent(".qoder-cn/settings.json")),
        ]
        let tomlConfigurations = [
            ("Codex", homeDirectory.appendingPathComponent(".codex/config.toml")),
        ]

        var namesByEndpoint: [String: [String]] = [:]
        for (name, url) in jsonConfigurations {
            for endpoint in Self.endpointsInJSONFile(at: url) {
                namesByEndpoint[endpoint, default: []].append(name)
            }
        }
        for (name, url) in tomlConfigurations {
            for endpoint in Self.endpointsInTOMLFile(at: url) {
                namesByEndpoint[endpoint, default: []].append(name)
            }
        }

        return namesByEndpoint
            .filter { _, names in !names.isEmpty }
            .map { endpoint, names in
                LocalDingTalkMCPConnectionCandidate(
                    sourceNames: Array(Set(names)).sorted(),
                    endpoint: endpoint
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func validatedEndpoint(from rawEndpoint: String) throws -> URL {
        let endpoint = rawEndpoint.cloudImportTrimmed
        guard let components = URLComponents(string: endpoint),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty
        else {
            throw CloudImportError.invalidMCPAddress
        }
        guard let url = components.url else {
            throw CloudImportError.invalidMCPAddress
        }
        return url
    }

    private static func endpointsInJSONFile(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return []
        }
        return endpointURLs(in: object)
    }

    private static func endpointURLs(in object: Any) -> [String] {
        if let dictionary = object as? [String: Any] {
            var endpoints: [String] = []
            if let configuration = dictionary["dingtalk-ai-table"] as? [String: Any],
               let endpoint = configuration["url"] as? String,
               (try? validatedEndpoint(from: endpoint)) != nil
            {
                endpoints.append(endpoint)
            }
            for value in dictionary.values {
                endpoints += endpointURLs(in: value)
            }
            return endpoints
        }
        if let array = object as? [Any] {
            return array.flatMap { endpointURLs(in: $0) }
        }
        return []
    }

    private static func endpointsInTOMLFile(at url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        var isDingTalkSection = false
        var endpoints: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmedLine = line.cloudImportTrimmed
            if trimmedLine.hasPrefix("[") && trimmedLine.hasSuffix("]") {
                isDingTalkSection = trimmedLine.lowercased().contains("dingtalk-ai-table")
                continue
            }
            guard isDingTalkSection,
                  trimmedLine.hasPrefix("url"),
                  let firstQuote = trimmedLine.firstIndex(of: "\""),
                  let lastQuote = trimmedLine.lastIndex(of: "\""),
                  firstQuote != lastQuote
            else {
                continue
            }
            let value = String(trimmedLine[trimmedLine.index(after: firstQuote)..<lastQuote])
            if (try? validatedEndpoint(from: value)) != nil {
                endpoints.append(value)
            }
        }
        return endpoints
    }
}

enum CloudDownloadLocation {
    static var defaultDirectoryPath: String {
        let fileManager = FileManager.default
        let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        return downloadsDirectory.appendingPathComponent("LocalizationWorkbench", isDirectory: true).path
    }
}

extension String {
    var cloudImportTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DingTalkMCPError: LocalizedError {
    case serverResponse(statusCode: Int, message: String)
    case protocolError(String)
    case exportUnavailable
    case exportDidNotStart
    case exportRequestFailed(String)
    case exportTimedOut
    case invalidDownloadAddress

    var errorDescription: String? {
        switch self {
        case let .serverResponse(statusCode, message):
            return "钉钉 MCP 请求失败（HTTP \(statusCode)）：\(message)"
        case let .protocolError(message):
            return "钉钉 MCP 返回错误：\(message)"
        case .exportUnavailable:
            return "当前钉钉 MCP 未提供 export_data 导出能力。"
        case .exportDidNotStart:
            return "钉钉未返回导出任务或下载地址。"
        case let .exportRequestFailed(message):
            return "钉钉未创建导出任务：\(message)"
        case .exportTimedOut:
            return "等待钉钉生成 Excel 超时，请稍后重试。"
        case .invalidDownloadAddress:
            return "钉钉返回了无效的临时下载地址。"
        }
    }
}

private struct DingTalkMCPSession {
    let identifier: String?
}

private struct DingTalkMCPHTTPResponse {
    let payload: [String: Any]
    let sessionID: String?
}

/// 仅实现本功能所需的 Streamable HTTP MCP 子集，不依赖任何 Agent 宿主进程。
struct DingTalkMCPClient {
    private static let protocolVersion = "2025-03-26"
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    let endpoint: URL

    private struct ExportFailure {
        let code: String
        let message: String

        var isTimeout: Bool {
            code.uppercased().contains("TIMEOUT") || message.uppercased().contains("TIMEOUT")
        }

        var detail: String {
            if code.isEmpty {
                return message
            }
            if message.isEmpty {
                return code
            }
            return "\(code)：\(message)"
        }
    }

    func validate() async throws {
        let session = try await openSession()
        let response = try await callTool(named: "tools/list", arguments: nil, session: session)
        let tools = toolNames(from: response)
        guard tools.contains("export_data") else {
            throw DingTalkMCPError.exportUnavailable
        }
    }

    func export(
        configuration: DingTalkExportConfiguration,
        onProgress: @escaping (String) -> Void
    ) async throws -> URL {
        onProgress("正在连接钉钉 MCP")
        let session = try await openSession()

        for creationAttempt in 1...2 {
            onProgress(
                creationAttempt == 1
                    ? "正在创建钉钉 Excel 导出任务"
                    : "导出任务超时，正在重新创建（\(creationAttempt)/2）"
            )
            let response = try await callTool(
                named: "export_data",
                arguments: exportArguments(for: configuration),
                session: session
            )
            if let downloadURL = try downloadURL(from: response) {
                return downloadURL
            }

            if let failure = exportFailure(from: response) {
                if failure.isTimeout, creationAttempt < 2 {
                    continue
                }
                throw DingTalkMCPError.exportRequestFailed(failure.detail)
            }

            guard let taskID = stringValue(for: ["taskId", "task_id"], in: response) else {
                throw DingTalkMCPError.exportDidNotStart
            }

            if let downloadURL = try await pollExport(
                baseID: configuration.baseID,
                taskID: taskID,
                session: session,
                onProgress: onProgress
            ) {
                return downloadURL
            }
        }

        throw DingTalkMCPError.exportTimedOut
    }

    private func pollExport(
        baseID: String,
        taskID: String,
        session: DingTalkMCPSession,
        onProgress: @escaping (String) -> Void
    ) async throws -> URL? {
        for attempt in 1...30 {
            try Task.checkCancellation()
            onProgress("正在等待钉钉生成 Excel（\(attempt)/30）")
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let response = try await callTool(
                named: "export_data",
                arguments: [
                    "baseId": baseID,
                    "taskId": taskID,
                    "timeoutMs": 30_000,
                ],
                session: session
            )
            if let downloadURL = try downloadURL(from: response) {
                return downloadURL
            }
            if let failure = exportFailure(from: response) {
                if failure.isTimeout {
                    return nil
                }
                throw DingTalkMCPError.exportRequestFailed(failure.detail)
            }
        }
        return nil
    }

    private func openSession() async throws -> DingTalkMCPSession {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": Self.protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "LocalizationWorkbench",
                    "version": "1.12",
                ],
            ],
        ]
        let response = try await post(payload, sessionID: nil, expectsPayload: true)
        try validateJSONRPCResponse(response.payload)

        let session = DingTalkMCPSession(identifier: response.sessionID)
        let initializedPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        _ = try await post(initializedPayload, sessionID: session.identifier, expectsPayload: false)
        return session
    }

    private func callTool(
        named name: String,
        arguments: [String: Any]?,
        session: DingTalkMCPSession
    ) async throws -> [String: Any] {
        if name == "tools/list" {
            let response = try await post(
                [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": name,
                    "params": [String: Any](),
                ],
                sessionID: session.identifier,
                expectsPayload: true
            )
            try validateJSONRPCResponse(response.payload)
            return response.payload
        }

        let response = try await post(
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": [
                    "name": name,
                    "arguments": arguments ?? [String: Any](),
                ],
            ],
            sessionID: session.identifier,
            expectsPayload: true
        )
        try validateJSONRPCResponse(response.payload)

        if let result = response.payload["result"] as? [String: Any],
           result["isError"] as? Bool == true
        {
            throw DingTalkMCPError.protocolError(message(in: result))
        }
        return response.payload
    }

    private func exportArguments(for configuration: DingTalkExportConfiguration) -> [String: Any] {
        var arguments: [String: Any] = [
            "baseId": configuration.baseID,
            "scope": configuration.scope.rawValue,
            "format": "excel_with_inline_images",
            "timeoutMs": 30_000,
        ]
        if configuration.scope == .table || configuration.scope == .view {
            arguments["tableId"] = configuration.tableID
        }
        if configuration.scope == .view {
            arguments["viewId"] = configuration.viewID
        }
        return arguments
    }

    private func post(
        _ payload: [String: Any],
        sessionID: String?,
        expectsPayload: Bool
    ) async throws -> DingTalkMCPHTTPResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(Self.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID, !sessionID.isEmpty {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await Self.session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DingTalkMCPError.protocolError("无法连接钉钉 MCP，请检查网络和连接地址。")
        }

        guard let response = urlResponse as? HTTPURLResponse else {
            throw DingTalkMCPError.protocolError("钉钉 MCP 返回了无效的网络响应。")
        }
        guard (200...299).contains(response.statusCode) else {
            throw DingTalkMCPError.serverResponse(
                statusCode: response.statusCode,
                message: sanitizedServerMessage(from: data)
            )
        }

        let sessionID = headerValue(named: "Mcp-Session-Id", in: response)
        guard expectsPayload else {
            return DingTalkMCPHTTPResponse(payload: [:], sessionID: sessionID)
        }
        return DingTalkMCPHTTPResponse(
            payload: try decodeJSONRPCPayload(from: data),
            sessionID: sessionID
        )
    }

    private func decodeJSONRPCPayload(from data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        let responseText = String(decoding: data, as: UTF8.self)
        let eventPayloads = responseText
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let text = String(line)
                guard text.hasPrefix("data:") else {
                    return nil
                }
                return String(text.dropFirst(5)).cloudImportTrimmed
            }

        for payload in eventPayloads.reversed() {
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            return object
        }
        throw DingTalkMCPError.protocolError("无法解析钉钉 MCP 的响应。")
    }

    private func validateJSONRPCResponse(_ response: [String: Any]) throws {
        guard let error = response["error"] as? [String: Any] else {
            return
        }
        throw DingTalkMCPError.protocolError(message(in: error))
    }

    private func toolNames(from response: [String: Any]) -> Set<String> {
        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]]
        else {
            return []
        }
        return Set(tools.compactMap { $0["name"] as? String })
    }

    /// 钉钉将业务失败封装在 MCP 成功响应的 structuredContent / content 中。
    private func exportFailure(from response: [String: Any]) -> ExportFailure? {
        for payload in exportPayloads(from: response) {
            let status = (payload["status"] as? String)?.lowercased()
            let error = payload["error"] as? [String: Any]
            let code = textValue(error?["code"]) ?? textValue(payload["code"]) ?? ""
            let errorMessage = textValue(error?["message"])
                ?? textValue(payload["message"])
            // 钉钉成功响应也可能带 error: null，不能因字段存在而误判失败。
            guard status == "error" || !code.isEmpty || errorMessage != nil else {
                continue
            }

            let rawMessage = errorMessage
                ?? textValue(payload["summary"])
                ?? "服务端未提供详细信息"
            return ExportFailure(code: code, message: sanitizedMessage(rawMessage))
        }
        return nil
    }

    private func exportPayloads(from response: [String: Any]) -> [[String: Any]] {
        guard let result = response["result"] as? [String: Any] else {
            return []
        }

        var payloads: [[String: Any]] = []
        if let structuredContent = result["structuredContent"] as? [String: Any] {
            payloads.append(structuredContent)
        }
        if let content = result["content"] as? [[String: Any]] {
            for item in content {
                guard let text = item["text"] as? String,
                      let data = text.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }
                payloads.append(payload)
            }
        }
        return payloads
    }

    private func textValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func downloadURL(from response: [String: Any]) throws -> URL? {
        guard let rawURL = stringValue(for: ["downloadUrl", "download_url"], in: response) else {
            return nil
        }
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https"
        else {
            throw DingTalkMCPError.invalidDownloadAddress
        }
        return url
    }

    private func stringValue(for keys: [String], in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let string = dictionary[key] as? String, !string.isEmpty {
                    return string
                }
            }
            for nestedValue in dictionary.values {
                if let found = stringValue(for: keys, in: nestedValue) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for nestedValue in array {
                if let found = stringValue(for: keys, in: nestedValue) {
                    return found
                }
            }
        } else if let string = value as? String,
                  let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let found = stringValue(for: keys, in: object)
        {
            return found
        }
        return nil
    }

    private func headerValue(named name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if String(describing: key).caseInsensitiveCompare(name) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    private func sanitizedServerMessage(from data: Data) -> String {
        sanitizedMessage(String(decoding: data, as: UTF8.self))
    }

    private func sanitizedMessage(_ rawMessage: String) -> String {
        let compactMessage = rawMessage
            .cloudImportTrimmed
            .replacingOccurrences(of: "\n", with: " ")
        guard !compactMessage.isEmpty else {
            return "服务端未提供详细信息"
        }
        // 服务端错误偶尔会回显请求地址；连接地址可能包含访问 Key，不能显示原文。
        return compactMessage.replacingOccurrences(
            of: #"https?://[^\s\"']+"#,
            with: "[已隐藏连接地址]",
            options: .regularExpression
        ).replacingOccurrences(
            of: #"(?i)(access[_-]?key|token|authorization)=?[^&\s,]+"#,
            with: "$1=[已隐藏]",
            options: .regularExpression
        ).prefix(300).description
    }

    private func message(in object: [String: Any]) -> String {
        if let message = object["message"] as? String, !message.isEmpty {
            return sanitizedMessage(message)
        }
        if let content = object["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
            if !text.isEmpty {
                return sanitizedMessage(text)
            }
        }
        return "服务端未提供详细信息"
    }
}

protocol CloudWorkbookProvider {
    var kind: CloudWorkbookProviderKind { get }

    func download(
        source: CloudWorkbookSource,
        destinationDirectory: URL,
        onProgress: @escaping (String) -> Void
    ) async throws -> [URL]
}

struct DingTalkMCPWorkbookProvider: CloudWorkbookProvider {
    let endpoint: URL

    var kind: CloudWorkbookProviderKind { .dingTalkMCP }

    func download(
        source: CloudWorkbookSource,
        destinationDirectory: URL,
        onProgress: @escaping (String) -> Void
    ) async throws -> [URL] {
        let configuration = try DingTalkExportConfiguration(source: source)
        let downloadURL = try await DingTalkMCPClient(endpoint: endpoint).export(
            configuration: configuration,
            onProgress: onProgress
        )

        onProgress("正在下载钉钉生成的 Excel 文件")
        let archiveURL = try await downloadArchive(from: downloadURL)
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
        }

        onProgress("正在解压并校验 Excel 文件")
        let workbooks = try await WorkbookArchiveExtractor.extract(
            archive: archiveURL,
            sourceKey: configuration.downloadSourceKey,
            preferredName: configuration.downloadFileStem,
            destinationDirectory: destinationDirectory
        )
        guard !workbooks.isEmpty else {
            throw CloudImportError.noWorkbookExtracted
        }
        return workbooks
    }

    private func downloadArchive(from remoteURL: URL) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 120
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DingTalkMCPError.protocolError("下载钉钉生成的文件失败，请稍后重试。")
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            throw DingTalkMCPError.protocolError("下载钉钉生成的文件失败。")
        }

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalizationWorkbench-\(UUID().uuidString).zip")
        try FileManager.default.copyItem(at: temporaryURL, to: archiveURL)
        return archiveURL
    }
}

struct CloudWorkbookDownloadService {
    private let providers: [any CloudWorkbookProvider]

    init(dingTalkMCPEndpoint: URL) {
        providers = [DingTalkMCPWorkbookProvider(endpoint: dingTalkMCPEndpoint)]
    }

    func download(
        source: CloudWorkbookSource,
        destinationDirectory: URL,
        onProgress: @escaping (String) -> Void
    ) async throws -> [URL] {
        guard let provider = providers.first(where: { $0.kind == source.provider }) else {
            throw CloudImportError.unsupportedProvider(source.provider.title)
        }
        return try await provider.download(
            source: source,
            destinationDirectory: destinationDirectory,
            onProgress: onProgress
        )
    }
}

enum ProcessExecutionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

enum ProcessExecutor {
    static func run(_ request: ProcessRequest) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: request.executablePath)
                process.arguments = request.arguments
                process.environment = ProcessInfo.processInfo.environment.merging(request.environment) { _, new in new }
                process.currentDirectoryURL = request.workingDirectory

                let standardOutput = Pipe()
                let standardError = Pipe()
                process.standardOutput = standardOutput
                process.standardError = standardError

                do {
                    try process.run()
                    process.waitUntilExit()

                    let output = String(
                        decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    )
                    let error = String(
                        decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    ).cloudImportTrimmed

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: output)
                    } else {
                        continuation.resume(
                            throwing: ProcessExecutionError.failed(
                                error.isEmpty ? "处理下载文件失败。" : error
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum WorkbookArchiveExtractor {
    static func extract(
        archive: URL,
        sourceKey: String,
        preferredName: String,
        destinationDirectory: URL
    ) async throws -> [URL] {
        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw CloudImportError.downloadDirectoryUnavailable(destinationDirectory.path)
        }

        let request = try PythonBridge.request(
            scriptName: "extract_downloaded_workbooks.py",
            arguments: [archive.path, destinationDirectory.path, sourceKey, preferredName]
        )
        let output = try await ProcessExecutor.run(request)
        guard let data = output.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data)
        else {
            throw CloudImportError.unsupportedDownloadPayload
        }

        let workbooks = paths.map { URL(fileURLWithPath: $0) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard !workbooks.isEmpty else {
            throw CloudImportError.noWorkbookExtracted
        }
        return workbooks
    }
}

enum CloudDownloadPhase: Equatable {
    case queued
    case exporting
    case succeeded(fileCount: Int)
    case failed(String)
    case cancelled

    var title: String {
        switch self {
        case .queued:
            return "等待下载"
        case .exporting:
            return "处理中"
        case .succeeded:
            return "已导入"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    var isFinished: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .exporting:
            return false
        }
    }

    var isExporting: Bool {
        if case .exporting = self {
            return true
        }
        return false
    }
}

struct CloudDownloadStatus: Equatable {
    let phase: CloudDownloadPhase
    let detail: String
}

@MainActor
final class CloudDownloadCoordinator: ObservableObject {
    @Published private(set) var isDownloading = false
    @Published private(set) var isCancelling = false
    @Published private(set) var statuses: [UUID: CloudDownloadStatus] = [:]

    private var downloadTask: Task<Void, Never>?

    func status(for sourceID: UUID) -> CloudDownloadStatus? {
        statuses[sourceID]
    }

    var activeStatus: CloudDownloadStatus? {
        statuses.values.first(where: { $0.phase.isExporting }) ??
            statuses.values.first(where: { !$0.phase.isFinished })
    }

    var completedSourceCount: Int {
        statuses.values.filter { $0.phase.isFinished }.count
    }

    var totalSourceCount: Int {
        statuses.count
    }

    func download(
        sources: [CloudWorkbookSource],
        destinationPath: String,
        connectionStore: DingTalkMCPConnectionStore,
        onImported: @escaping ([String]) -> Void
    ) {
        guard !sources.isEmpty, !isDownloading else {
            return
        }

        let destinationDirectory = URL(fileURLWithPath: destinationPath.cloudImportTrimmed, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            setFailure(for: sources, detail: CloudImportError.downloadDirectoryUnavailable(destinationDirectory.path).localizedDescription)
            return
        }

        let endpoint: URL
        do {
            endpoint = try connectionStore.endpointURL()
        } catch {
            setFailure(for: sources, detail: error.localizedDescription)
            return
        }

        statuses = Dictionary(
            uniqueKeysWithValues: sources.map {
                ($0.id, CloudDownloadStatus(phase: .queued, detail: "等待开始"))
            }
        )
        isCancelling = false
        isDownloading = true

        downloadTask = Task { [weak self] in
            guard let self else {
                return
            }

            let service = CloudWorkbookDownloadService(dingTalkMCPEndpoint: endpoint)
            var importedPaths: [String] = []

            for source in sources {
                guard !Task.isCancelled else {
                    self.markRemainingSourcesCancelled(after: source, in: sources)
                    break
                }

                self.statuses[source.id] = CloudDownloadStatus(phase: .exporting, detail: "准备下载")
                do {
                    let files = try await service.download(
                        source: source,
                        destinationDirectory: destinationDirectory
                    ) { [weak self] detail in
                        Task { @MainActor [weak self] in
                            self?.statuses[source.id] = CloudDownloadStatus(
                                phase: .exporting,
                                detail: detail
                            )
                        }
                    }
                    let paths = files.map(\.path)
                    importedPaths += paths
                    self.statuses[source.id] = CloudDownloadStatus(
                        phase: .succeeded(fileCount: paths.count),
                        detail: "已导入 \(paths.count) 个 Excel 文件"
                    )
                } catch is CancellationError {
                    self.statuses[source.id] = CloudDownloadStatus(phase: .cancelled, detail: "用户取消下载")
                    self.markRemainingSourcesCancelled(after: source, in: sources)
                    break
                } catch {
                    self.statuses[source.id] = CloudDownloadStatus(
                        phase: .failed(error.localizedDescription),
                        detail: error.localizedDescription
                    )
                }
            }

            if !importedPaths.isEmpty {
                onImported(UserPath.deduplicated(importedPaths))
            }
            self.isDownloading = false
            self.isCancelling = false
            self.downloadTask = nil
        }
    }

    func cancel() {
        guard isDownloading, !isCancelling else {
            return
        }
        isCancelling = true
        downloadTask?.cancel()
    }

    private func setFailure(for sources: [CloudWorkbookSource], detail: String) {
        statuses = Dictionary(
            uniqueKeysWithValues: sources.map {
                ($0.id, CloudDownloadStatus(phase: .failed(detail), detail: detail))
            }
        )
    }

    private func markRemainingSourcesCancelled(after current: CloudWorkbookSource, in sources: [CloudWorkbookSource]) {
        guard let currentIndex = sources.firstIndex(where: { $0.id == current.id }) else {
            return
        }
        for source in sources.dropFirst(currentIndex + 1) {
            statuses[source.id] = CloudDownloadStatus(phase: .cancelled, detail: "用户取消下载")
        }
    }
}
