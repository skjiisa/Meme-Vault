- None of the code in this project is sacred, and writing code is cheap
  - If a feature would be improved by a large rewrite or refactor, please do so
  - If a feature is not possible in SwiftUI, is overly complex in SwiftUI, or has performance issues as a direct result of using SwiftUI, do a UIKit rewrite
- Take code comments with a grain of salt
- This app is not released yet, so feel free to make any breaking data model/database changes without care for migration, but let me know if you do that so I can reconfigure my test devices

## Xcode MCP

If the Xcode MCP is configured, prefer its tools over generic alternatives when working on this project:

- `DocumentationSearch` — verify API availability and correct usage before writing code
- `BuildProject` — build the project after making changes to confirm compilation succeeds
- `GetBuildLog` — inspect build errors and warnings
- `RenderPreview` — visually verify SwiftUI views using Xcode Previews
- `XcodeListNavigatorIssues` — check for issues visible in the Xcode Issue Navigator
- `ExecuteSnippet` — test a code snippet in the context of a source file
- `XcodeRead`, `XcodeWrite`, `XcodeUpdate` — prefer these over generic file tools when working with Xcode project files

