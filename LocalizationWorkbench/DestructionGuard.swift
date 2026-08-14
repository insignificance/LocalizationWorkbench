import Foundation
import SwiftUI

// MARK: - 销毁锁（Kill Switch）

/// 在 App 启动时检测指定的 Notion 页面是否被删除。
/// 一旦确认页面被“真的删除”，就写入本地标记；此后只要标记存在，App 只显示空白页面、隐藏全部功能。
/// 网络问题（无网、超时、DNS 失败、服务器 5xx）一律忽略，不触发锁定。
@MainActor
final class DestructionGuard: ObservableObject {
    /// 是否已确认目标页面被删除（触发锁定）。
    @Published private(set) var isLocked: Bool

    /// 需要监控的 Notion 页面 ID（32 位十六进制，取自页面 URL 尾部）。
    private static let watchedPageHex = "8a1f7dfc3c0d44639d3b221aefebe1ec"

    /// Notion 公开页面数据接口，用于判断页面是否仍然存在。
    private static let apiEndpoint = URL(string: "https://full-governor-aa9.notion.site/api/v3/loadCachedPageChunk")!

    /// 本地锁标记在 UserDefaults 中的 key。
    private static let lockDefaultsKey = "DestructionGuard.isLocked"

    init() {
        // 启动时先读取历史标记：若此前已检测到删除，直接锁定，无需再等网络。
        isLocked = UserDefaults.standard.bool(forKey: Self.lockDefaultsKey)
    }

    /// 启动检测：只有页面被“真的删除”才会锁定；网络问题一律忽略。
    func check() async {
        guard !isLocked else { return }

        // 返回 nil 表示网络/服务不可用，视为未删除（忽略）。
        guard let deleted = await Self.isPageDeleted(), deleted else { return }

        UserDefaults.standard.set(true, forKey: Self.lockDefaultsKey)
        isLocked = true
    }

    /// 判断目标页面是否已被删除。
    /// - Returns: `true` 已删除；`false` 仍存在；`nil` 网络/服务不可用（无法判断，忽略）。
    private static func isPageDeleted() async -> Bool? {
        let body: [String: Any] = [
            "pageId": uuid(fromHex: watchedPageHex),
            "limit": 10,
            "cursor": ["stack": []],
            "chunkNumber": 0,
            "verticalColumns": false,
        ]

        var request = URLRequest(url: apiEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // 网络层错误（无网络、超时、DNS 失败等）：无法判断，忽略。
            return nil
        }

        guard let http = response as? HTTPURLResponse else {
            return nil
        }

        // 服务器内部错误（5xx）：视为服务不可用而非删除，忽略。
        guard http.statusCode < 500 else {
            return nil
        }

        // 4xx：Notion 对无效/已删除页面返回 400，直接视为删除。
        if http.statusCode >= 400 {
            return true
        }

        // 2xx：解析 recordMap，确认是否还包含 page 块。
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordMap = json["recordMap"] as? [String: Any],
              let blocks = recordMap["block"] as? [String: Any],
              containsPageBlock(in: blocks) else {
            // 响应虽成功但拿不到页面数据，视为页面已删除。
            return true
        }

        return false
    }

    /// 判断 block 映射里是否含有 type 为 page 的块。
    private static func containsPageBlock(in blocks: [String: Any]) -> Bool {
        for (_, raw) in blocks {
            guard let block = raw as? [String: Any],
                  let value = block["value"] as? [String: Any],
                  let inner = value["value"] as? [String: Any],
                  inner["type"] as? String == "page" else {
                continue
            }
            return true
        }
        return false
    }

    /// 把 32 位十六进制 ID 转成 Notion API 需要的 UUID（8-4-4-4-12）。
    private static func uuid(fromHex hex: String) -> String {
        let segmentLengths = [8, 4, 4, 4, 12]
        var segments: [String] = []
        var index = hex.startIndex
        for length in segmentLengths {
            let end = hex.index(index, offsetBy: length)
            segments.append(String(hex[index..<end]))
            index = end
        }
        return segments.joined(separator: "-")
    }
}

/// 锁定态空白页：目标页面被删除后，用一片空白替换全部功能。
struct DestructionLockedView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
        }
        .ignoresSafeArea()
    }
}
