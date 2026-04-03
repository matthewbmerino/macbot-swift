# Macbot

Native macOS AI agent — privacy-first, all processing on-device.

Built with SwiftUI. Runs models locally via MLX (Apple Silicon native) or Ollama, with automatic fallback. Multi-agent orchestration, semantic memory, RAG pipeline, and speculative decoding.

## Architecture

```
                    ┌─────────────────────┐
                    │    User Message      │
                    └──────────┬──────────┘
                               │
                    ┌──────────▼──────────┐
                    │  Embedding Router    │  ~50ms cosine sim
                    │  (LLM fallback)     │
                    └──────────┬──────────┘
                               │
              ┌────────┬───────┼───────┬────────┐
              ▼        ▼       ▼       ▼        ▼
          General   Coder  Reasoner  Vision    RAG
              │        │       │       │        │
              │   ┌────▼───────▼───────▼────┐   │
              │   │  MLX Client (Metal GPU) │   │
              │   │  + Speculative Decoding │   │
              │   │  + Prompt Caching       │   │
              │   │  ↓ Ollama Fallback      │   │
              │   └─────────────────────────┘   │
              │                                 │
              │  ┌─────────────────────────┐    │
              │  │  ReAct Reflection Loop  │    │
              │  │  (evaluate → continue   │    │
              │  │   or synthesize)        │    │
              │  └─────────────────────────┘    │
              │                                 │
              │  ┌─────────────────────────┐    │
              └──│  Vector Memory Store    │────┘
                 │  (Accelerate vDSP)      │
                 │  + Semantic Search       │
                 │  + Embedding Backfill    │
                 └─────────────────────────┘
                               │
                 ┌─────────────▼───────────┐
                 │  RAG Pipeline           │
                 │  Ingest → Chunk → Embed │
                 │  → Vector Store         │
                 │  → Hybrid Search        │
                 │  → Re-rank → Inject     │
                 └─────────────────────────┘

         Parallel Agents / Mixture of Agents
         (compare queries → multi-agent → synthesize)
```

## Features

- **Multi-agent system** — General, Coder, Vision, Reasoner, and Knowledge (RAG) agents with specialized models and tool access
- **MLX inference** — Native Apple Silicon GPU execution via MLX framework with Ollama fallback
- **Speculative decoding** — Draft model generates candidate tokens, target model verifies in one forward pass (2-3x speedup)
- **Embedding router** — Cosine similarity classification against category centroids (~50ms vs ~500ms for LLM routing)
- **Semantic memory** — Vector-indexed persistent memory using Accelerate vDSP with automatic embedding backfill
- **RAG pipeline** — Document ingestion with semantic chunking (markdown/code/text), hybrid search (vector + keyword with reciprocal rank fusion), LLM re-ranking
- **ReAct reflection** — Agents evaluate tool results and decide whether to continue gathering information or synthesize a response
- **Mixture of Agents** — Run multiple agents in parallel on comparison queries, synthesize outputs into a single response
- **Hardware-aware model selection** — Automatic model recommendations based on chip, RAM, GPU cores, and memory bandwidth
- **Dynamic quantization** — Q2 through F16 quantization selection based on available memory
- **Privacy-first** — Biometric authentication, Keychain-encrypted database, all processing local
- **Tool suite** — File I/O, web search, Python execution (sandboxed), macOS system control, finance data, chart generation
- **BPE-aware token estimation** — Character-class analysis for accurate context window management across code and prose

## Models

Default configuration (adjusts based on hardware):

| Role | Model | Context | Use |
|------|-------|---------|-----|
| General | qwen3.5:9b | 32k | Conversation, planning, research |
| Coder | devstral-small-2 | 65k | Code generation, debugging |
| Vision | qwen3-vl:8b | 16k | Image analysis |
| Reasoner | deepseek-r1:14b | 32k | Math, logic, step-by-step analysis |
| Router | qwen3.5:0.8b | 4k | Message classification |
| Embedding | qwen3-embedding:0.6b | 2k | Semantic search, routing |

## Commands

```
/code <msg>       — force coding agent
/think <msg>      — force reasoning agent
/see <msg>        — force vision agent
/chat <msg>       — force general agent
/knowledge <msg>  — force knowledge/RAG agent
/plan <task>      — force planning mode
/ingest <path>    — ingest file/directory into knowledge base
/remember <text>  — save to memory
/memories [cat]   — list memories
/backend [mode]   — switch inference (mlx, ollama, hybrid)
/parallel         — toggle parallel agent execution
/moa              — toggle Mixture of Agents
/clear            — reset conversation
/status           — system info
```

## Requirements

- macOS 14+
- Apple Silicon (for MLX) or Intel (Ollama only)
- [Ollama](https://ollama.com) installed (for fallback/primary inference)

## Build

```bash
swift build
swift run Macbot
```
