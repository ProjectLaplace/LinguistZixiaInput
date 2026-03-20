# LaplaceIME Project Context

## Build & Test
- Engine: `cd Packages/PinyinEngine && swift build`
- DemoApp: Open `Apps/LaplaceIME-DemoApp/LaplaceIME-DemoApp.xcodeproj` in Xcode
- Format: `swift-format` (mandatory after code changes per GEMINI.md §4)

## Architecture
- `Packages/PinyinEngine` — Pure Swift engine (Foundation only, no UI)
- `Apps/LaplaceIME-DemoApp` — SwiftUI macOS simulator app
- Engine API: `PinyinEngine.process(EngineEvent) -> EngineState`

## Conventions
- Chinese text uses「」not ""
- Deterministic input is the core design principle
- No network requests, no persistent privacy data
- state_machine.ragel is a design document, not compiled code
