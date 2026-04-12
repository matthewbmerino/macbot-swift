# macbot Architecture

This document describes the architecture of macbot-swift, a local-first
multi-agent AI assistant for macOS. macbot runs entirely on-device using
Ollama-served models on Apple Silicon, with no cloud dependencies for
inference.

The codebase targets macOS 15+ and uses Swift 6.0 tools with the Swift 5
language mode. The remaining Swift 6 strict-concurrency blockers are
tracked in TODO.md.

---

## 1. System Overview

macbot is a menu-bar macOS app that provides a conversational AI assistant
backed by locally-running language models. It supports tool use (file I/O,
web search, shell commands, calendar, email, media control, screen OCR,
code execution, image generation, and more), persistent memory, RAG over
user documents, and a learning loop that improves routing and behavior
over time based on interaction history.

All inference flows through Ollama's llama.cpp Metal backend. An MLX
integration exists in the codebase but is not in the active inference
path. The default model family is Qwen 3.5 (9B for chat, 0.8B for
routing/summarization, 0.6B for embeddings), with Gemma 4 used for
vision tasks.

---

## 2. Agent Architecture

### Categories

Five agent specializations are defined in `AgentCategory` (an enum in
`Macbot/Models/AgentCategory.swift`):

| Agent    | Purpose                                               |
|----------|-------------------------------------------------------|
| General  | Conversation, writing, web research, summarization    |
| Coder    | Code generation, debugging, technical implementation  |
| Reasoner | Math, logic, step-by-step analysis                    |
| Vision   | Image understanding (activated when images are sent)  |
| RAG      | Questions grounded in user-ingested documents         |

Each agent is an instance of `BaseAgent` (`Macbot/Services/Agents/BaseAgent.swift`),
configured with a category-specific system prompt, model, temperature,
and context window size. Specialized subclasses (`GeneralAgent`,
`CoderAgent`, `ReasonerAgent`, `VisionAgent`, `RAGAgent`) register
category-specific tools on initialization.

### BaseAgent

`BaseAgent` implements the core agent loop:

1. Inject ambient context (frontmost app, idle time, battery).
2. Optionally generate a multi-step plan using the primary model.
3. Enter the tool loop (up to 10 iterations):
   - Filter tools to a relevant subset via keyword matching and learned hints.
   - Call the model with the filtered tool set.
   - If the model returns tool calls, execute them in parallel, compress
     large results, and append to history.
   - After 3+ tool calls, run a ReAct reflection (tiny model) to decide
     whether to continue or synthesize.
   - On the final (10th) iteration, force a synthesis with no tools to
     prevent dead-end "max iterations" responses.
4. After the model produces a final text response:
   - Run `CitationGuard` to verify numeric claims against tool outputs.
   - Run a self-verification pass (tiny model) to check completeness.
   - If either check fails, regenerate with a corrective nudge.

Temperature is adaptive: once any tool has been called in a turn, sampling
temperature is clamped to 0.2 to discourage creative paraphrasing of
grounded data.

History is trimmed when token count exceeds 75% of the context window.
Trimming summarizes the middle of the conversation using a tiny model
and preserves the system prompt plus the last 4 messages.

### Orchestrator

`Orchestrator` (`Macbot/Services/Orchestrator.swift`) is the top-level
coordinator. It owns the inference client, router, memory stores, and
per-user conversation state. Its responsibilities:

- **Routing**: Classify each incoming message to an agent category using
  a three-tier cascade: (1) deterministic regex patterns for code/math,
  (2) `EmbeddingRouter` cosine similarity against category centroids,
  (3) LLM-based `Router` as fallback. Routing affinity keeps the same
  agent for short bursts of consecutive messages.
- **Shared transcript**: Each `ConversationState` holds a canonical
  `transcript` array (user/assistant/tool messages only, no transient
  system messages). Before each turn, the chosen agent's history is
  rebuilt as `[systemPrompt] + transcript` via `loadHistoryFromTranscript`.
  After the turn, new messages are captured back. This eliminates context
  loss across routing changes.
- **Trace lifecycle**: Creates a `TraceBuilder` at turn start, commits it
  to `TraceStore` at turn end, and fires skill distillation asynchronously.
- **Skill and routing injection**: Embeds the user message once, then
  runs skill retrieval and learned routing concurrently over that shared
  embedding vector (`injectSkillsAndLearnedRouting`).
- **Parallel / MoA execution**: Optional modes where multiple agents
  answer the same query; results are aggregated or synthesized.

---

## 3. Learning Loop

The learning loop is the system that makes macbot improve with use. It
follows the "bitter lesson" philosophy: hand-coded keyword routing will
eventually lose to a learned model trained on actual interaction history.

### Data flow

```
User turn
  |
  v
Orchestrator.handleMessage()
  |
  +---> TraceStore.commit(trace)         # persist the interaction
  |
  +---> scheduleSkillDistillation(trace) # fire-and-forget on detached task
          |
          v
        SkillStore.distill()             # tiny model extracts a lesson
          |
          v
        Skill row in SQLite              # embedded, deduped, retrievable
```

### TraceStore

`TraceStore` (`Macbot/Services/TraceStore.swift`) persists every
user-assistant turn as an `InteractionTrace` row. Each trace records the
user message, routed agent, route reason, model used, tool calls (with
args, results, latency), assistant response, ambient context snapshot,
and timing. User message embeddings are backfilled lazily in the
background.

### LearnedRouter

`LearnedRouter` (`Macbot/Services/LearnedRouter.swift`) performs k-NN
(k=8) over the trace store's user-message embeddings using vDSP cosine
similarity. It votes on agent category and tool selection, weighted by
similarity. The predictions are injected as `learnedToolHints` on the
agent before each turn, biasing the tool filter without overriding the
keyword router.

### SkillStore

`SkillStore` (`Macbot/Services/Memory/SkillStore.swift`) stores distilled
behavioral lessons. Each `Skill` has a situation/action/lesson triple
(e.g., "When user asks for stock comparison, use comparison_chart tool
and include percentage changes"). Skills are:

- **Distilled** from traces by a tiny model after each turn.
- **Deduplicated** by cosine similarity (threshold 0.85); duplicates
  bump `useCount` on the existing skill instead of creating a new row.
- **Retrieved** by embedding similarity (floor 0.55) and injected into
  agent system prompts before each turn.

---

## 4. Memory Hierarchy

macbot has four complementary persistence layers, all backed by SQLite
via GRDB.

### MemoryStore (key-value facts)

`MemoryStore` (`Macbot/Services/Memory/MemoryStore.swift`) stores
user-saved facts ("remember that my API key is X", "my dog's name is
Max"). Each memory has a category, content, and optional embedding.
Search is hybrid: semantic (vector similarity via `VectorIndex`) with
keyword fallback. Embeddings are generated asynchronously through a
serial `EmbeddingQueue` actor. Memories are formatted into agent prompts
with `[YYYY-MM-DD]` timestamps so the model can discount stale facts.

### EpisodicMemory (conversation summaries)

`EpisodicMemory` (`Macbot/Services/Memory/EpisodicMemory.swift`) records
session-level summaries as `Episode` rows. At session end, a tiny model
summarizes the transcript into a title, summary, and topic list. Episodes
give macbot continuity across sessions ("what did we discuss last
Tuesday"). Old episodes are prunable via `pruneOlderThan(days:)`.

### ChunkStore (RAG chunks)

`ChunkStore` (`Macbot/Services/RAG/ChunkStore.swift`) stores embedded
document chunks for retrieval-augmented generation. Documents are
ingested by `DocumentIngester`, split into chunks, embedded, and stored.
Search supports pure vector similarity and hybrid (vector + keyword with
reciprocal rank fusion, RRF constant = 60). File-level change detection
uses SHA-256 hashes to avoid redundant re-ingestion.

### VectorIndex (in-memory embeddings)

`VectorIndex` (`Macbot/Services/Inference/VectorIndex.swift`) is a
lightweight in-memory vector store used by both `MemoryStore` and
`ChunkStore`. It uses Apple's Accelerate framework (vDSP) for
SIMD-optimized cosine similarity on the AMX coprocessor. Thread-safe
via `NSLock`. Supports insert, remove, search with threshold, and batch
search.

---

## 5. Grounding Pipeline

Small models hallucinate. macbot has a layered defense:

### Anti-fabrication clause

Every agent's system prompt is appended with `BaseAgent.antiFabricationClause`,
a strict grounding rule: only state facts from tool outputs, retrieved
memory, or the user's message. No rounding, no paraphrasing, no hedging
to disguise a guess.

### GroundedResponse envelope

`GroundedResponse` (`Macbot/Services/Tools/GroundedResponse.swift`) wraps
tool outputs with a "Data from <source> (use these exact values in your
response):" header. This syntactic forcing function steers the model to
quote tool data verbatim. Supports UTC timestamps for time-sensitive data
and a `searchResults` variant that tells the model to only cite URLs that
appear in the results.

### CitationGuard

`CitationGuard` (`Macbot/Services/Agents/CitationGuard.swift`) is a
deterministic post-generation checker. It extracts all numeric tokens
(dollar amounts, percentages, decimals, integers with thousands
separators) from the model's draft response and checks each against the
concatenated tool-result text. Numbers below a small-integer threshold
(default 10) are exempt. If unsourced numbers are found, the agent
appends a corrective nudge listing the offending values and regenerates.
No LLM cost -- pure regex.

### Adaptive temperature

After any tool call in a turn, `adaptiveTemperature` clamps sampling to
0.2, reducing creative variation when the model should be quoting
grounded data.

### Self-verification

After the tool loop, a tiny model (`qwen3.5:0.8b`) checks whether the
response actually answers the original question. If it returns
`INCOMPLETE` or `WRONG`, one retry is attempted with a corrective nudge.

---

## 6. Tool System

### ToolRegistry

`ToolRegistry` (`Macbot/Services/Tools/ToolRegistry.swift`) is an actor
that holds tool specs and handlers. Tools are registered by each agent
subclass at initialization.

**Deterministic pre-filtering**: Rather than sending all tools to the
model (which degrades small-model tool selection), `filteredSpecsAsJSON`
matches the user message against keyword groups (finance, web, files,
macos, git, calendar, email, media, etc.) and only sends relevant tools.
Co-occurring groups (e.g., finance + chart) are automatically included.
Learned tool hints from `LearnedRouter` are merged into the filter.

**Per-category timeouts**: Tools are classified into three tiers:

| Tier   | Timeout | Examples                                      |
|--------|---------|-----------------------------------------------|
| Fast   | 5s      | calculator, memory_save, read_file, git_status|
| Medium | 15s     | weather, stock price, web_search, screen_ocr  |
| Slow   | 30s     | run_python, browse_url, generate_image         |

Unrecognized tools default to medium. Execution includes retry with
exponential backoff (up to 2 retries).

**Parallel execution**: `executeAll` runs multiple tool calls concurrently
via `withTaskGroup`.

### ToolCache

`ToolCache` (`Macbot/Services/Tools/ToolCache.swift`) is a TTL-based
cache for network-bound tools (weather, web search). Bounded to 64
entries by default; evicts by earliest expiry. Thread-safe via `NSLock`.

### Tool categories

Tools are organized in `Macbot/Services/Tools/`:

| File              | Tools                                           |
|-------------------|-------------------------------------------------|
| CalendarTools     | calendar_today, calendar_create, calendar_week, reminder_create |
| ChartTools        | stock_chart, comparison_chart, generate_chart   |
| EmailTools        | email_draft, email_read                         |
| ExecutorTools     | run_python, run_command, run_applescript         |
| FileTools         | read_file, write_file, list_directory, search_files |
| FinanceTools      | get_stock_price, get_stock_history, get_market_summary |
| GitTools          | git_status, git_log, git_diff                   |
| ImageGenTools     | generate_image (via MLX StableDiffusion)        |
| MacOSTools        | open_app, screenshot, system_info, process management |
| MediaTools        | now_playing, media_control, search_play         |
| NetworkTools      | ping, dns_lookup, port_check, http_check        |
| QRTools           | generate_qr                                     |
| ScreenTools       | screen_ocr, screen_region_ocr                   |
| SkillTools        | weather, calculator, unit_convert, date_calc, define_word |
| SummarizeTools    | summarize_url                                   |
| TextTools         | json_format, encode_decode, regex_extract        |
| WebTools          | web_search, fetch_page, browse_url              |

---

## 7. Inference Backends

### OllamaClient

`OllamaClient` (`Macbot/Services/Inference/OllamaClient.swift`) is the
primary inference provider. It communicates with a local Ollama instance
over HTTP. Features:

- Non-streaming and streaming chat endpoints.
- Embedding endpoint (batch).
- Model listing and warm-up.
- `keep_alive` set to 5 minutes to free RAM on 18GB machines.
- Optional `draft_model` parameter for speculative decoding.

### InferenceProvider protocol

`InferenceProvider` (`Macbot/Services/Inference/InferenceProvider.swift`)
defines the interface: `chat`, `chatStream`, `embed`, `listModels`,
`warmModel`. Both `OllamaClient` and the MLX implementation conform.

### MLX (experimental, not in active path)

The `Macbot/Services/Inference/MLX/` directory contains an alternative
inference backend using Apple's MLX framework directly:

- `MLXClient.swift` -- inference provider using MLX Swift bindings.
- `MistralModel.swift`, `GemmaModel.swift` -- model implementations.
- `SpeculativeDecoder.swift` -- speculative decoding (Leviathan et al.,
  2023) with adaptive K and acceptance-rate tracking.
- `PromptCacheManager.swift` -- KV cache reuse for prompt prefixes.
- `LoRATrainer.swift` -- on-device LoRA fine-tuning.

### Speculative decoding (Ollama path)

When `ModelConfig.speculativeDecoding` is enabled, the Orchestrator
passes the router model (qwen3.5:0.8b) as `draftModel` to
`OllamaClient`. Ollama uses it for fast next-token proposals verified by
the main model. On qwen-family pairs the agreement rate is high enough
for 1.5-2.5x generation speedup.

---

## 8. Key Directories

```
Macbot/
  MacbotApp.swift                -- App entry point, menu bar setup
  Models/                        -- AgentCategory, ChatMessage, ModelConfig, StreamEvent, ToolSpec
  Services/
    Orchestrator.swift           -- Top-level coordinator, routing, transcript management
    Router.swift                 -- LLM-based message classifier (fallback)
    EmbeddingRouter.swift        -- Embedding-based fast classifier (~50ms)
    LearnedRouter.swift          -- k-NN over trace embeddings
    TraceStore.swift             -- Interaction trace persistence
    CommandHandler.swift         -- Slash-command parsing (/clear, /model, etc.)
    PromptModules.swift          -- Dynamic system-prompt injection
    EvalHarness.swift            -- Automated evaluation framework
    HookSystem.swift             -- Pre/post tool-call hooks
    Agents/                      -- BaseAgent + 5 specialized subclasses + CitationGuard
    Memory/                      -- MemoryStore, EpisodicMemory, SkillStore
    RAG/                         -- ChunkStore, DocumentIngester
    Inference/                   -- InferenceProvider protocol, OllamaClient, VectorIndex, MLX/
    Tools/                       -- ToolRegistry, ToolCache, GroundedResponse, 17 category files
  Utilities/                     -- Logger, TokenEstimator, ThinkingStripper, KeychainManager, etc.
  Views/                         -- ChatView, SettingsView, MenuBarView, QuickPanel, OnboardingView, etc.
  Database/DatabaseManager.swift -- GRDB setup, migrations, shared pool

Tests/MacbotTests/               -- 31 test files covering core subsystems
```
