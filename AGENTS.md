# Repository Guidelines

<!-- Author: Renogy_YX -->

## Project Structure & Module Organization

`LocalizationWorkbench.xcodeproj` is the macOS app project and exposes the `LocalizationWorkbench` scheme. SwiftUI application code lives in `LocalizationWorkbench/`: `LocalizationWorkbenchApp.swift` starts the app, `ContentView.swift` owns the top-level shell, `WorkflowViews.swift` contains workflow-specific screens, and `SharedViews.swift` contains reusable UI. Process execution and project-path helpers belong in `AppSupport.swift`; workflow metadata belongs in `Workflow.swift`. Bundle resources are under `LocalizationWorkbench/Resources/`, including app assets in `Assets.xcassets` and Python localization utilities in `Resources/Python/`. Treat `build/` as generated Xcode output; do not hand-edit or commit new artifacts from it.

## Build, Test, and Development Commands

- `open LocalizationWorkbench.xcodeproj` — open the project in Xcode for local development and UI inspection.
- `chmod +x ./build_with_xcode.sh && ./build_with_xcode.sh` — perform the repository's release build using Xcode, without code signing, and write derived data to `build/`.
- `xcodebuild -project LocalizationWorkbench.xcodeproj -scheme LocalizationWorkbench -configuration Debug build` — run a Debug build when iterating from the terminal.
- `python3 LocalizationWorkbench/Resources/Python/excel_to_localizations.py --help` — smoke-test a bundled script's CLI; use disposable fixtures for behavior changes.

## Coding Style & Naming Conventions

Use four-space indentation in Swift and Python. Follow Swift API conventions: types and views use `PascalCase`; functions, properties, enum cases, and local values use `camelCase`. Keep SwiftUI views small and place reusable components in `SharedViews.swift`; keep a workflow's state and controls together in `WorkflowViews.swift`. Use descriptive Python function names and type annotations where the surrounding script does. Add concise Chinese comments only for non-obvious logic; avoid comments that merely restate code. No formatter or linter is currently configured, so match nearby code and let Xcode re-indent edited Swift files.

## Testing Guidelines

The project has no XCTest target today. Every change must at least build successfully. For UI changes, launch the app and exercise the affected workflow, including an invalid-path or failed-process case where relevant. For Python changes, run the affected script against a disposable sample and verify both generated files and console errors. Add a focused XCTest target when introducing logic that is difficult to validate manually.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commits with scoped, concise subjects, for example `feat(filter): 默认勾选仅导出app值为真的行`. Use `<type>(<scope>): <subject>` and keep the scope tied to the affected workflow or component. Keep commits focused. Pull requests should explain the user-visible change, list build/manual-test evidence, link relevant issues, and include screenshots for SwiftUI changes. Do not include unrelated `xcuserdata`, `.DS_Store`, or generated `build/` changes.
