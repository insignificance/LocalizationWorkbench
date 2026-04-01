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
