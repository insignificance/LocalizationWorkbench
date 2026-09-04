# LocalizationWorkbench Xcode Project

这是标准的 Xcode macOS App 工程版本。

## 打开方式

直接打开：

```text
LocalizationWorkbench.xcodeproj
```

或者在终端里构建：

```bash
chmod +x ./build_with_xcode.sh
./build_with_xcode.sh
```

## 目录说明

- `LocalizationWorkbench.xcodeproj`: 标准 Xcode 工程
- `LocalizationWorkbench/*.swift`: SwiftUI 源码
- `LocalizationWorkbench/Resources/Python`: 打包到 app bundle 的 Python 脚本
- `LocalizationWorkbench/Info.plist`: 标准 app 配置

## 说明

- 这个目录是独立的 Xcode 工程版本
- 不影响根目录下原来的 Swift Package 版本
- app 仍然通过系统 `python3` 执行这些本地化脚本

## 云端钉钉 Excel 导入

“Excel 转本地化”页面提供“云端 Excel”入口，当前已支持钉钉 AI 表格 MCP：

- 每位用户在自己的 macOS 账户中连接钉钉 MCP；连接地址（含访问 Key）只保存到系统钥匙串。
- 已在 Claude、Qoder 或 Codex 中配置的 `dingtalk-ai-table` MCP 可一键从本机配置导入，也可以手动粘贴自己的连接地址。
- 可保存多个钉钉在线文档链接，按需勾选后批量下载；链接会自动解析 Base、Sheet、View，并可调整导出范围。
- 钉钉导出完成后，应用会下载临时 ZIP / XLSX、校验工作簿、提取 `.xlsx`，自动加入当前的 Excel 输入列表。

数据源模型使用“提供方 + 私有配置”的结构；后续接入其他云端下载方式时，只需新增对应 Provider，不会影响已保存的钉钉链接。

## 可扩展语言支持

转换与换行检查共用 `LocalizationWorkbench/Resources/Python/locale_aliases.json` 中的语言注册表。内置覆盖 37 个常用语言或地区 Locale，并支持直接使用符合 BCP 47 规范的表头，例如 `ar`、`vi`、`zh-Hant`、`pt-BR`。

需要补充业务自定义别名时，可在 App 的“语言别名配置（可选）”中选择一个 JSON 文件；外部配置会叠加到内置配置，不会覆盖默认语言。结构如下：

```json
{
  "version": 1,
  "locales": {
    "sw": ["斯瓦希里语", "Swahili", "Kiswahili"],
    "en": ["英文文案"]
  },
  "ignored_headers": ["业务线"]
}
```

- `locales` 的 key 是输出 Locale，数组内是 Excel 可识别的表头别名。
- 同一个别名不能映射到两个 Locale；冲突时脚本会停止并说明原因。
- `locale_aliases.example.json` 提供了可直接复制修改的样例。
