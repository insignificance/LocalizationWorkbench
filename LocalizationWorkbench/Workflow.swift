import SwiftUI

enum Workflow: String, CaseIterable, Identifiable {
    case excelConversion
    case newlineCheck
    case languageAliasGuide
    case cleanStrings
    case migrateLocalizedLiterals
    case migrateI18nKeys

    var id: String { rawValue }

    static var toolCases: [Workflow] {
        allCases
    }

    var title: String {
        switch self {
        case .excelConversion:
            return "Excel 转本地化"
        case .newlineCheck:
            return "换行一致性检查"
        case .languageAliasGuide:
            return "语言别名说明"
        case .cleanStrings:
            return ".strings 清洗"
        case .migrateLocalizedLiterals:
            return ".localized 迁移"
        case .migrateI18nKeys:
            return "i18n Key 迁移"
        }
    }

    var subtitle: String {
        switch self {
        case .excelConversion:
            return "把一个或多个 Excel 工作簿转换成 iOS 可用的 .strings / .xcstrings。"
        case .newlineCheck:
            return "检查 Excel 里英文换行标记是否在多语言列中被正确保留。"
        case .languageAliasGuide:
            return "查看 Excel 表头、Locale 代码和自定义 JSON 别名的解析规则。"
        case .cleanStrings:
            return "规范化 Localizable.strings，清除裸字符串和重复键值对。"
        case .migrateLocalizedLiterals:
            return "把源码中的 .localized 字面量改写为 NSLocalizedString。"
        case .migrateI18nKeys:
            return "按 map.strings 和英文基线把旧 key 迁移到统一命名。"
        }
    }

    var symbolName: String {
        switch self {
        case .excelConversion:
            return "tablecells.badge.ellipsis"
        case .newlineCheck:
            return "text.line.first.and.arrowtriangle.forward"
        case .languageAliasGuide:
            return "book.closed.fill"
        case .cleanStrings:
            return "sparkles.rectangle.stack"
        case .migrateLocalizedLiterals:
            return "arrow.triangle.2.circlepath"
        case .migrateI18nKeys:
            return "point.3.connected.trianglepath.dotted"
        }
    }

    var tint: Color {
        switch self {
        case .excelConversion:
            return Color(red: 0.13, green: 0.48, blue: 0.86)
        case .newlineCheck:
            return Color(red: 0.08, green: 0.63, blue: 0.56)
        case .languageAliasGuide:
            return Color(red: 0.36, green: 0.31, blue: 0.82)
        case .cleanStrings:
            return Color(red: 0.83, green: 0.51, blue: 0.12)
        case .migrateLocalizedLiterals:
            return Color(red: 0.79, green: 0.29, blue: 0.22)
        case .migrateI18nKeys:
            return Color(red: 0.36, green: 0.31, blue: 0.82)
        }
    }

    var accentName: String {
        switch self {
        case .excelConversion:
            return "Excel"
        case .newlineCheck:
            return "Checks"
        case .languageAliasGuide:
            return "Guide"
        case .cleanStrings:
            return "Cleanup"
        case .migrateLocalizedLiterals:
            return "Rewrite"
        case .migrateI18nKeys:
            return "Migration"
        }
    }

    var outputSummary: String {
        switch self {
        case .excelConversion:
            return ".strings / .xcstrings / log"
        case .newlineCheck:
            return "Markdown + CSV report"
        case .languageAliasGuide:
            return "表头 / JSON / FAQ"
        case .cleanStrings:
            return "Normalized Localizable.strings"
        case .migrateLocalizedLiterals:
            return "Source rewrite + reports"
        case .migrateI18nKeys:
            return "Mapping reports + optional source update"
        }
    }

    var primaryBadge: String {
        switch self {
        case .languageAliasGuide:
            return "内置说明"
        case .excelConversion, .newlineCheck, .cleanStrings, .migrateLocalizedLiterals, .migrateI18nKeys:
            return "本地执行"
        }
    }

    var secondaryBadge: String {
        switch self {
        case .languageAliasGuide:
            return "规则 / JSON"
        case .excelConversion, .newlineCheck, .cleanStrings, .migrateLocalizedLiterals, .migrateI18nKeys:
            return "Python 驱动"
        }
    }
}
