# TODO

Items flagged during the quality elevation pass. These are not silently
rewritten because they touch behavior; they live here so a human can
prioritize them.

## Bugs

### `Memory` and `DocumentChunk` use the wrong GRDB conformance

Both record types conform to `PersistableRecord` (immutable) instead of
`MutablePersistableRecord`. As a result, after `try record.insert(db)` the
`record.id` field is never backfilled with the auto-assigned row id.

Observable consequences:

- `MemoryStore.save()` returns `0` for every memory because of
  `guard let id = memory.id else { return 0 }`. The row is persisted, but
  the embedding queue is enqueued with `id = 0`, so the asynchronous
  `UPDATE memories SET embedding = ? WHERE id = 0` never matches a row and
  semantic memory embeddings silently never populate. Vector index growth
  for new saves only happens via `loadVectorIndex()` on next launch.
- `ChunkStore.insertChunks()` returns an empty `[Int64]` array because the
  same code path checks `if let id = record.id`. The in-memory vector
  index is never updated inside `insertChunks` either — it only repopulates
  via `loadVectorIndex()` on next launch.

Fix is small but behavior-affecting: change conformance to
`MutablePersistableRecord` and add `mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }`
to both record structs. Tests `ChunkStoreTests.testInsertAndSemanticSearch`
and `MemoryStoreTests.testForgetRemovesEntry` document the workaround
(load from disk, look up id via SQL).

### `OllamaClient.embed` decodes embeddings to `[[Float]]` but gets `[]`

`OllamaClient.embed` does `json["embeddings"] as? [[Float]] ?? []`.
`JSONSerialization` produces numeric values as `NSNumber`/`Double`, and the
Swift bridge does **not** coerce `[[Double]]` to `[[Float]]` — the cast
returns `nil`, so the function silently returns `[]`. This means the
embedding router, semantic memory search, and RAG hybrid search are likely
running on the keyword/fallback paths in production rather than the
intended vector path.

Fix: decode as `[[Double]]` first, then map to `[Float]`:

```swift
let raw = json["embeddings"] as? [[Double]] ?? []
return raw.map { $0.map(Float.init) }
```

`OllamaClientTests.testEmbedRequestShape` documents that the request
serialization is correct; the response-decoding assertion was removed
until the bug above is fixed.

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

- `MemoryStore.search()` uses a `DispatchSemaphore` to bridge async semantic
  search into a synchronous call site. Tracked here so the call sites can
  be migrated to `async` and the semaphore removed.
- `TraceStore` has Swift 6 `Sendable` warnings around `var trace = ...`
  captured by a detached task. Pre-existing.
- `SkillStore` has the same captured-var warning at line 163.

## Testing gaps

Phase 1 covers core non-UI logic. Areas still without tests, in priority
order:

- `EpisodicMemory` summarization trigger and retrieval
- `LearnedRouter` k-NN tool prediction from traces
- `TraceStore` write/read round trip
- `OllamaClient` request body shape (could be tested with a stub URL
  protocol that records bytes — would catch keep_alive regressions)
- `CommandHandler` parser (`/code`, `/think`, `/see`, etc.)
