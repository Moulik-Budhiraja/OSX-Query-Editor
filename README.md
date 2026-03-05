# OSX Query Editor

Native macOS Xcode app for AXorcist selector query workflow (the same domain as `axorc` interactive selector mode).

## Scope

This app intentionally focuses on query-language features only:

- Resolve app target by bundle id, app name, PID, or `focused`
- Run OXQ selector queries
- Inspect matched results and details
- Filter results locally
- Perform interactions on selected result:
  - `click`
  - `press`
  - `focus`
  - `set-value`
  - `set-value-submit`
  - `send-keystrokes-submit`

## Open In Xcode

```bash
cd /Users/moulik/Documents/programming/axorcist-tools
open OSXQueryEditor.xcodeproj
```

## Build From CLI

```bash
cd /Users/moulik/Documents/programming/axorcist-tools
xcodebuild -project OSXQueryEditor.xcodeproj -scheme OSXQueryEditor -configuration Debug build
```
