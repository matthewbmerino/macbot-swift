# TODO

Items flagged during the quality elevation pass. These are not silently
rewritten because they touch behavior; they live here so a human can
prioritize them.

## Bugs

_(All previously listed bugs in this section have been fixed. See git
log for `MutablePersistableRecord` and `OllamaClient.embed` decoding
fixes — both were silently disabling semantic memory and RAG.)_

## Refactor candidates

These files exceed 200 lines and are flagged here per the elevation plan.
Splitting any of them is a behavior-preserving change that should land in
a focused PR, not a quality pass.

| File | Lines | Suggested split |
|---|---|---|
| `Services/Inference/MLX/MLXClient.swift` | 1162 | Extract model loader, KV cache wiring, and quantization paths into separate files |
| `Services/Orchestrator.swift` | 898 | Extract trace builder, learned-routing merge, and skill injection into helpers |
| `Services/Tools/ChartTools.swift` | 652 | Group by chart type (stock, comparison, generic) into peer files |
| `Services/Tools/MacOSTools.swift` | 626 | Group by capability (apps, processes, screen, system) |
| `Services/Agents/BaseAgent.swift` | 582 | Extract ReAct reflection loop and history compaction |
| `Services/Tools/SkillTools.swift` | 577 | Each tool (`weather_lookup`, `calculator`, etc.) is independent — peer files |

## Concurrency

### Resolved (Wave 2 D)
- ~~`HookContext.toolArgs: [String: Any]` non-Sendable field.~~ Field is
  now a JSON-encoded `String` (`toolArgsJSON`) with a `toolArgsDict`
  decoding accessor for handlers that need the live dict. The single
  writer in `ToolRegistry.execute` uses the existing `.make(toolArgs:)`
  factory unchanged.
- ~~`MemoryStore.search()` DispatchSemaphore bridge.~~ Already fixed in
  an earlier pass — `search()` is async end-to-end.
- ~~`TraceStore` captured-var warnings.~~ Already fixed — `commit()`
  captures `[trace]` immutably and shadows with `var local = trace`
  inside the detached task.
- ~~`SkillStore` line 163 captured-var warning.~~ Already fixed — same
  `var local = newSkill` shadow pattern inside `dbPool.write`.

### Remaining (blockers to `swiftLanguageModes: [.v6]`)
- **NSLock-in-async** — `EmbeddingRouter.swift` (12 call sites) and
  `Services/Inference/MLX/MLXClient.swift` (5 call sites) use `NSLock`
  from async functions, which is a hard error in Swift 6. Migrate to
  an actor or to scoped `withLock {}` replacements.
- **`static let shared` singletons** that hold non-`Sendable` state:
  `DatabaseManager`, `TraceStore`, `SkillStore`, `EpisodicMemory`,
  `ActivityLog`, `HotkeyManager`, `KeychainManager`, `SystemMonitor`,
  `QuickPanelController`. Each needs either `@MainActor`, actor
  conformance, or a `Sendable` conformance with a real justification.
- **`Orchestrator` self-captures** — six `Task.detached { ... }` blocks
  in `Orchestrator.swift` capture `self` as a non-`Sendable` class.
  Likely fix: mark `Orchestrator` `@MainActor` or split the async
  paths that don't need `self` out of the detached tasks.
- **Captured-var warnings** in `ChatViewModel.swift` (12 sites) and
  `Services/Tools/ImageGenTools.swift:94`. Mechanical — use an actor
  or rewrite with immutable accumulators.
- **Global POSIX variables** — `vm_kernel_page_size` referenced from
  `MacOSTools.swift`, `SkillTools.swift`, and `SystemMonitor.swift`.
  Capture the value once at startup or import into a `@MainActor`
  helper.
- **Other**: `RAGAgent.swift:76` sending-closure data-race,
  `CompositeToolStore.swift:164` executor self-capture,
  `GroundedResponse.swift:81` static ISO8601 formatter,
  `KeychainManager` static `Keychain` properties,
  `PromptModules.swift:26` static `modules`.

The Wave 2 D target (Debt 1) is resolved; the other three named
debts were already fixed in earlier passes. Flipping to `.v6`
surfaces ~40 additional errors listed above — none are inside the
Wave 2 D charter, so the migration is deferred.

## Testing gaps

Phase 1 covers core non-UI logic. Areas still without tests, in priority
order:

- `EpisodicMemory` summarization trigger and retrieval
- `LearnedRouter` k-NN tool prediction from traces (existing
  `LearnedRouterTests` only cover the degenerate empty-embedding /
  no-traces cases — the real nearest-neighbor path is not exercised)
- `TraceStore` write/read round trip
- `CommandHandler` parser (`/code`, `/think`, `/see`, etc.)
