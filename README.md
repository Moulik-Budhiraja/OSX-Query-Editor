# OSX Query Editor

OSX Query Editor is a native macOS app for running AXorcist selector queries against live app accessibility trees and inspecting results in real time.

## Features

- Target apps by bundle identifier, app name, PID, or `focused`
- Run OXQ selector queries with live stats
- Inspect matched element metadata and hierarchy details
- Filter results locally
- Run actions on selected elements:
  - `click`
  - `press`
  - `focus`
  - `set-value`
  - `set-value-submit`
  - `send-keystrokes-submit`

## Screenshot

![OSX Query Editor](docs/osx-query-editor.png)

## Open In Xcode

```bash
open OSXQueryEditor.xcodeproj
```

## Build From CLI

```bash
xcodebuild -project OSXQueryEditor.xcodeproj -scheme OSXQueryEditor -configuration Debug build
```
