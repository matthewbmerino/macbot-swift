# Macbot

Native macOS AI agent — privacy-first, all processing on-device.

Built with SwiftUI. Runs models locally via MLX (Apple Silicon native) with Ollama fallback. Multi-agent orchestration, semantic memory, RAG pipeline, speculative decoding, and deep system introspection.

## Architecture

```
                         ┌──────────────────┐
                         │   User Message   │
                         └────────┬─────────┘
                                  │
                         ┌────────▼─────────┐
                         │ Embedding Router  │ ~50ms cosine sim
                         │ (LLM fallback)   │
                         └────────┬─────────┘
                                  │
           ┌──────────┬───────────┼───────────┬──────────┐
           ▼          ▼           ▼           ▼          ▼
       General     Coder     Reasoner     Vision      RAG
      Gemma 4    Devstral   DeepSeek-R1  Qwen-VL   Qwen+Vector
      26B MoE    (Mistral)    (Qwen2)    (Ollama)    Search
           │          │           │           │          │
           └──────────┴─────┬─────┴───────────┴──────────┘
                            │
              ┌─────────────▼──────────────┐
              │   Hybrid Inference Engine   │
              │                            │
              │  MLX Client (Metal GPU)    │
              │    Qwen2 · Gemma · Mistral │
              │    Speculative Decoding    │
              │    KV Cache Management     │
              │         ↓ fallback         │
              │  Ollama Client (HTTP)      │
              └─────────────┬──────────────┘
                            │
         ┌──────────────────┼──────────────────┐
         │                  │                  │
   ┌─────▼──────┐   ┌──────▼───────┐   ┌─────▼──────┐
   │   Tools     │   │   Memory     │   │    RAG     │
   │             │   │              │   │  Pipeline  │
   │ System:     │   │ Vector Store │   │            │
   │  processes  │   │ (vDSP SIMD)  │   │ Ingest     │
   │  memory     │   │ Semantic     │   │ Chunk      │
   │  ports      │   │  Search     │   │ Embed      │
   │  top procs  │   │ Embedding    │   │ Hybrid     │
   │             │   │  Backfill   │   │  Search    │
   │ Web:        │   │              │   │ Re-rank    │
   │  search     │   └──────────────┘   └────────────┘
   │  fetch      │
   │  browse     │          ┌──────────────────┐
   │             │          │  ReAct Reflection │
   │ Code:       │          │  evaluate results │
   │  python     │          │  continue or stop │
   │  shell      │          └──────────────────┘
   │  (sandbox)  │
   │             │          ┌──────────────────┐
   │ Finance:    │          │  Mixture of      │
   │  stocks     │          │  Agents (MoA)    │
   │  charts     │          │  parallel exec   │
   │             │          │  → synthesize    │
   │ Files:      │          └──────────────────┘
   │  read/write │
   │  search     │          ┌──────────────────┐
   │             │          │  LoRA Trainer     │
   │ macOS:      │          │  on-device finetune│
   │  apps       │          │  save/load adapters│
   │  clipboard  │          └──────────────────┘
   │  notify     │
   │  screenshot │          ┌──────────────────┐
   │             │          │  Tool Learning    │
   │ Learned:    │          │  /learn workflows │
   │  composite  │          │  variable capture │
   │  workflows  │          │  auto-register    │
   └─────────────┘          └──────────────────┘

              ┌──────────────────────────┐
              │   Response Metrics       │
              │   3.2s · 156 tok · 49/s  │
              └──────────────────────────┘
```

## Models

Default configuration (adjusts based on hardware):

| Role | Model | Architecture | Context | Backend | Use |
|------|-------|-------------|---------|---------|-----|
| General | gemma4:26b-a4b | Gemma 4 MoE (4B active / 26B total) | 128k | MLX | Conversation, planning, tools, research |
| Coder | devstral-small-2 | Mistral | 128k | MLX | Code generation, debugging, review |
| Reasoner | deepseek-r1:14b | Qwen2 (distilled) | 32k | MLX | Math, logic, step-by-step analysis |
| Vision | qwen3-vl:8b | Qwen2-VL | 16k | Ollama | Image analysis, OCR |
| Router | qwen3.5:0.8b | Qwen2 | 4k | MLX | Message classification (LLM fallback) |
| Embedding | qwen3-embedding:0.6b | Qwen2 | 2k | Ollama | Semantic search, routing centroids |

## Features

**Inference**
- Hybrid MLX/Ollama backend — MLX runs on Metal GPU, falls back to Ollama transparently
- Three model architectures: Qwen2, Gemma 4 (with MoE expert routing), Mistral
- Speculative decoding — draft model (0.8B) generates candidates, target verifies in one pass
- Automatic model download from HuggingFace Hub on first use
- Hardware-aware model selection with dynamic quantization (Q2–F16)

**Agents**
- Five specialized agents: General, Coder, Reasoner, Vision, Knowledge (RAG)
- Embedding router classifies messages in ~50ms via cosine similarity
- ReAct reflection — agents evaluate tool results before responding
- Mixture of Agents — parallel execution with synthesis for comparison queries
- Planning mode with step-by-step execution and time estimates

**Memory & Knowledge**
- Persistent vector-indexed memory with semantic search (Accelerate vDSP)
- RAG pipeline: ingest files, chunk by structure, embed, hybrid search, re-rank
- Automatic embedding backfill for existing memories

**Tools**
- System introspection: per-process memory/CPU, top processes, listening ports, detailed system info
- Web: search (DuckDuckGo), fetch pages, browse URLs
- Code: sandboxed Python execution (sandbox-exec), shell commands
- Finance: real-time stock prices, YTD/historical data, market indices, charts
- Files: read, write, search, list directories
- macOS: open apps, screenshots, clipboard, notifications
- Learned workflows: teach multi-step sequences, replay as single tools

**Privacy & Security**
- All processing local — no data leaves the machine
- Biometric authentication (Touch ID / password)
- Keychain-encrypted database
- Sandboxed code execution with restricted file system access

**UI**
- Menu bar presence with live CPU/memory/GPU monitoring
- Split-view chat with sidebar, search, chat history
- Quick panel (Cmd+Shift+Space) for rapid queries
- Response metrics under each message (time, tokens, tok/s)
- Markdown rendering, inline images, drag-drop image attachment

## Commands

```
/code <msg>                          — force coding agent
/think <msg>                         — force reasoning agent
/see <msg>                           — force vision agent
/chat <msg>                          — force general agent
/knowledge <msg>                     — force knowledge/RAG agent
/plan <task>                         — generate and execute a step-by-step plan
/ingest <path>                       — ingest file/directory into knowledge base
/remember <text>                     — save to persistent memory
/memories [category]                 — list memories
/learn <name> | <desc> | <trigger>   — create a reusable workflow
/workflows                           — list learned workflows
/backend [mlx|ollama|hybrid]         — switch inference backend
/parallel                            — toggle parallel agent execution
/moa                                 — toggle Mixture of Agents
/clear                               — reset conversation
/status                              — system and model info
```

## Requirements

- macOS 14+
- Apple Silicon (for MLX inference) or Intel (Ollama only)
- [Ollama](https://ollama.com) installed (required for vision, embeddings, and as fallback)

## Build

```bash
swift build
swift run Macbot
```
