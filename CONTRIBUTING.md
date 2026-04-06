# Contributing to Macbot

Thanks for taking the time to contribute. Macbot is a native macOS AI agent
that runs models locally — contributions that protect that privacy posture
and keep the project approachable to new contributors are most welcome.

## Prerequisites

- macOS 14 (Sonoma) or newer, on Apple Silicon (M-series)
- Xcode 15+ or the matching Swift toolchain (Swift 5.10+)
- [Ollama](https://ollama.com) for the inference backend
- ~20 GB free disk for the default model set

Pull the default models once Ollama is running:

```bash
ollama pull qwen3.5:9b
ollama pull qwen3-embedding:0.6b
ollama pull gemma4:e4b   # vision; optional
```

## Build

```bash
git clone https://github.com/matthewbmerino/macbot-swift
cd macbot-swift
swift build
```

To run the app from the command line:

```bash
swift run Macbot
```

## Run the tests

```bash
swift test
```

The test target uses `@testable import Macbot` and a `MockInferenceProvider`
so the suite runs fully offline — Ollama does not need to be running. Tests
that touch persistence use `DatabaseManager.makeTestPool()`, which creates a
fresh temp-file-backed `DatabasePool` and applies migrations. Cleanup happens
in each test's `tearDown`.

## Pull request expectations

- `swift build` and `swift test` must pass on `macos-14` (the same target CI
  uses). Both run automatically against your PR.
- Keep changes focused. If you find unrelated issues, open them separately or
  add an entry to `TODO.md`.
- Don't force-push to `main`. Force-pushing your own PR branch is fine.
- New behavior should have a test. Bug fixes should have a regression test
  that fails without the fix.
- Match the existing code style. We use SwiftLint with the config in
  `.swiftlint.yml`; CI runs it as a non-blocking advisory until the project's
  baseline is clean.
- Don't introduce hardcoded paths, API keys, or anything that requires a
  specific machine. Secrets belong in the user's Keychain via
  `KeychainManager`.

## Reporting issues

Please include:

1. macOS version and chip (e.g. macOS 14.4, M3 Pro)
2. Output of `ollama list`
3. Steps to reproduce
4. Relevant log output — `log show --predicate 'subsystem == "com.macbot"' --last 5m`
