# LLM Seeker

> Discover, download, and AirDrop LLM models from Hugging Face directly to your Mac — all from your iPhone.

[![Swift](https://img.shields.io/badge/Swift-5-orange.svg)](https://www.swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS-lightgray.svg)](https://developer.apple.com/ios)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

LLM Seeker is an iOS app that lets you search Hugging Face for ML models (MLX, GGUF, safetensors), download them on your iPhone, and AirDrop them to a nearby Mac for seamless use with [oMLX](https://github.com/Charend/omlx). Perfect for when your Mac doesn't have internet access but your iPhone does.

## ✨ Features

- **🔍 Discover** — Search Hugging Face with smart filters: MLX-only toggle, Mac-fit compatibility, and sort by trending, popularity, or downloads
- **📊 Mac-Fit Engine** — Estimates whether a model will run on your Mac and how fast, using a memory-bandwidth model calibrated to real benchmarks. Understands Mixture-of-Experts models (counts *active* params for speed, *total* for memory), real on-disk size, quantization overhead, and KV-cache growth
- **📥 Background Downloads** — Resumable downloads with progress tracking, pause/resume, byte-size verification, and automatic disk-space checks
- **📚 Library** — Manage downloaded models with swipe actions: cancel, retry, share, or delete
- **🤝 AirDrop to oMLX** — Share model folders (or a single ZIP archive) directly to your Mac; models land in the correct `~/.omlx/models/` structure, ready to use
- **🧠 Learn** — Built-in glossary covering formats, quantization, KV cache, attention, Mixture-of-Experts, memory bandwidth, sampling, and more
- **🔐 Gated Repos** — Support for private/gated models via Hugging Face token stored securely in Keychain
- **🎨 Liquid Glass UI** — Beautiful SwiftUI interface with glass morphology, supporting both light and dark modes

## 🏗️ How It Works

```
┌─────────────────────────────────────┐
│ iPhone (LLM Seeker)                 │
│                                     │
│  Discover → Hugging Face API        │
│  Download → Background URLSession   │
│  Library → AirDrop Handoff          │
└──────────────────┬──────────────────┘
                   │ AirDrop folder
                   ▼
          Mac → ~/.omlx/models/
                (loaded by oMLX)
```

The iPhone is the **only** internet-connected client. Models are downloaded to the iPhone's sandbox, then transferred via AirDrop to the Mac where oMLX loads them automatically.

## 📱 Screens

| Discover | Model Details | Library |
|----------|--------------|---------|
| Search & filter models | Quantization, benchmarks, README, download controls | Download progress, swipe actions, share sheet |

## 🏗️ Architecture

```
LLM Seeker/
├── App/                        # App entry point & tab navigation
├── Core/
│   ├── Downloads/              # Background download manager, progress tracking
│   ├── Logging/                # Diagnostics logging
│   ├── MacFit/                 # Apple Silicon catalog & fit estimator
│   ├── Networking/             # Hugging Face API client & DTOs
│   ├── Persistence/            # SwiftData models & favorites
│   ├── Security/               # Keychain token storage
│   └── Sharing/                # AirDrop & model sharing
├── DesignSystem/               # Theme, glass components
└── Features/
    ├── Discover/               # Search & browse models
    ├── Learn/                  # Glossary & educational content
    ├── Library/                # Download management
    ├── ModelDetails/           # Model info, benchmarks, download
    └── Settings/               # Mac profiles, diagnostics, auth
```

### Key Design Decisions

- **oMLX-compatible folder layout** — Models use `{owner}/{model}/` structure so they work drop-in with oMLX
- **Safetensors-first** — PyTorch `.bin` artifacts are filtered out when safetensors are present
- **Param count from metadata** — Uses `info.safetensors["parameters"]` with oMLX's byte-width map; falls back to repo-name regex when unavailable
- **Benchmark-calibrated fit estimate** — Speed is treated as memory-bandwidth-bound (tok/s ≈ ~0.8 × chip bandwidth ÷ active-bytes-per-token); the memory ceiling follows oMLX's "system RAM − headroom" rule. No per-model hardcoding
- **User-selected Mac profile** — The phone can't auto-detect the receiving Mac, so Settings lets you pick chip family + RAM
- **Temp folder downloads** — Files land in `._____temp/` during transfer, then are atomically moved to the final location

## 🚀 Getting Started

### Prerequisites

- Xcode 26+
- iOS 26.0+ deployment target
- Apple Silicon Mac running oMLX (for receiving models)

### Build & Run

1. Clone the repository
2. Open `LLM Seeker.xcodeproj` in Xcode
3. Build and run on an iPhone device (AirDrop requires a physical device)

### Using with oMLX

After AirDropping a model to your Mac:

1. Move the folder from `~/Downloads/{model}/` to `~/.omlx/models/{owner}/{model}/`
2. Launch oMLX — the model will appear automatically

> **Tip**: The app shows a one-time guidance sheet with the exact path to copy.

## 🔑 Hugging Face Token (Optional)

To access gated models:

1. Generate a token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
2. Enter it in LLM Seeker → Settings → Hugging Face Token
3. The token is stored securely in iOS Keychain

## 🧠 Learn Tab Topics

- **Formats** — MLX, GGUF, safetensors, and how each is run
- **Quantization** — 4-bit, 8-bit, MXFP4, Q4_K_M, BF16, and effective bits-per-weight
- **Core concepts** — Parameters, tokens, context window, **KV cache**, attention, embeddings
- **Architecture** — Mixture-of-Experts (total vs active params), unified memory, FP16/BF16
- **Performance** — Memory bandwidth, tokens/sec, prefill vs decode, speculative decoding, MTP
- **Behaviour** — Temperature & sampling, top-p/top-k, perplexity, RAG, fine-tuning & distillation
- **Model types** — VLM, OCR, and embedding models

## 📋 Verification

- ✅ Models download to `Application Support/Models/{owner}/{model}/`
- ✅ File structure matches `~/.omlx/models/` layout
- ✅ Byte-size checks against expected file sizes
- ✅ AirDrop folder transfer preserves directory structure
- ✅ oMLX loads models without manual modification

## 📄 License

MIT — see [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- [Hugging Face](https://huggingface.co) for the model hub and API
- [Apple MLX](https://ml-explore.github.io/mlx/) for the MLX framework
- [oMLX](https://github.com/Charend/omlx) for the Mac-side model runner
