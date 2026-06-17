//
//  LearnView.swift
//  LLM Seeker
//

import SwiftUI

private struct GlossaryEntry: Identifiable {
    let id = UUID()
    let term: String
    let summary: String
    let detail: String
    let icon: String
}

private struct GlossarySection: Identifiable {
    let id = UUID()
    let title: String
    let entries: [GlossaryEntry]
}

private let sections: [GlossarySection] = [

    .init(title: "Fundamentals", entries: [
        .init(term: "Tokens",
              summary: "The chunks of text a model reads and writes",
              detail: "Models don't see words — they see tokens, which are sub-word pieces (~0.75 words each on average in English). Prompts, context limits, and generation speed are all measured in tokens, not characters or words.",
              icon: "textformat.abc"),
        .init(term: "Parameters",
              summary: "The learned weights of the model",
              detail: "Parameters are the numbers a model learned during training, counted in billions (e.g. 7B, 70B). More parameters generally means more capability, but also more memory and slower generation. Memory needed ≈ parameters × bits-per-weight ÷ 8.",
              icon: "number"),
        .init(term: "Context window",
              summary: "How much text the model can consider at once",
              detail: "The maximum number of tokens (prompt + generated output) the model can attend to, e.g. 8K, 32K, 128K. Everything beyond the window is forgotten. Larger windows need far more KV-cache memory, which scales linearly with context length.",
              icon: "ruler"),
        .init(term: "KV cache",
              summary: "Stored attention state that grows with context",
              detail: "As a model generates, it caches the Key and Value vectors for every previous token so it doesn't recompute them each step. This cache lives in memory on top of the weights and grows linearly with context length — at long contexts it can rival the model itself in size. It's why a model that fits at 4K may overflow at 128K.",
              icon: "tray.full"),
        .init(term: "Attention",
              summary: "How tokens decide what to focus on",
              detail: "The mechanism that lets each token weigh the relevance of every earlier token via Query/Key/Value vectors. It's the source of both the model's power and its quadratic cost: doubling context roughly quadruples attention compute. Variants like Grouped-Query Attention (GQA) shrink the KV cache by sharing keys/values across heads.",
              icon: "eye"),
        .init(term: "Embeddings",
              summary: "Text turned into vectors of numbers",
              detail: "An embedding maps a token or piece of text into a high-dimensional vector where similar meanings sit close together. LLMs embed input internally; dedicated embedding models (pipeline tag: feature-extraction) output these vectors for search, clustering, and RAG.",
              icon: "point.3.connected.trianglepath.dotted"),
    ]),

    .init(title: "Formats & Model Types", entries: [
        .init(term: "MLX",
              summary: "Apple's array framework for Apple Silicon",
              detail: "MLX is Apple's NumPy-like framework optimized for Apple Silicon's unified memory. Models tagged mlx use the .safetensors layout with MLX-specific tensor names. Best run via mlx-lm or oMLX on macOS.",
              icon: "cpu"),
        .init(term: "GGUF",
              summary: "Single-file format used by llama.cpp",
              detail: "GGUF packs weights, tokenizer, and metadata into one file. Quantized variants (Q4_K_M, Q8_0, etc.) trade quality for size. Run with llama.cpp, Ollama, or LM Studio.",
              icon: "doc.fill"),
        .init(term: "safetensors",
              summary: "Safe binary tensor container",
              detail: "Drop-in replacement for PyTorch .bin pickles. No code-execution risk on load. Used by Hugging Face Transformers, MLX, and many runtimes.",
              icon: "lock.shield"),
        .init(term: "Adapter / LoRA",
              summary: "Small fine-tune that rides on a base model",
              detail: "LoRA / PEFT adapters add a few MB of weights on top of an unmodified base model. You must download the base model separately on your Mac.",
              icon: "puzzlepiece"),
        .init(term: "Pipeline tag",
              summary: "Primary task the model is trained for",
              detail: "Hugging Face categorizes models by pipeline_tag: text-generation (LLM), image-text-to-text (VLM), feature-extraction (embeddings), image-to-text (OCR/captioning).",
              icon: "tag.fill"),
    ]),

    .init(title: "Quantization & Precision", entries: [
        .init(term: "FP16 / BF16",
              summary: "16-bit floating point — the full-precision baseline",
              detail: "Most models are released in 16-bit (FP16 or BF16) at ~2 bytes per weight. BF16 trades mantissa precision for a wider exponent range, which trains more stably. Quantization shrinks from this baseline: 4-bit is ~4× smaller than 16-bit.",
              icon: "16.circle"),
        .init(term: "Quantization",
              summary: "Lower-precision weights to shrink models",
              detail: "Converts FP16/BF16 weights to lower bit widths (8, 4, or fewer). Common labels: Q4_K_M (good 4-bit balance), Q8_0 (near-lossless 8-bit), MXFP4 (microscaling FP4 used in MoE LLMs). Less bits = smaller file, faster load, slight quality drop.",
              icon: "rectangle.compress.vertical"),
        .init(term: "MXFP4",
              summary: "Microscaling 4-bit floating point",
              detail: "FP4 variant with shared per-block scale (~4.5 bits/weight effective). Used by frontier MoE LLMs to fit in unified memory while keeping FP-style dynamic range.",
              icon: "scale.3d"),
    ]),

    .init(title: "Architecture", entries: [
        .init(term: "MoE (Mixture of Experts)",
              summary: "Many experts, only a few used per token",
              detail: "An MoE model splits its feed-forward layers into many 'expert' sub-networks and a router picks just a few per token. A model like Qwen3-30B-A3B has 30B total parameters but only ~3B active per token. You pay memory for all 30B but get the speed of a 3B — the best of both, at the cost of disk and RAM.",
              icon: "rectangle.3.group"),
        .init(term: "Active parameters",
              summary: "What actually runs for each token (MoE)",
              detail: "In MoE models the 'A' number (e.g. A3B, A22B) is the active parameter count read per token. Generation speed depends on active params; memory depends on total params. LLM Seeker uses active params for its tokens/sec estimate and total params for fit.",
              icon: "bolt"),
        .init(term: "MTP (Multi-Token Prediction)",
              summary: "Predict several tokens per forward pass",
              detail: "Models trained with auxiliary heads that predict 2+ future tokens at once. Speeds up generation when the runtime supports speculative decoding (e.g. mlx-lm with --num-draft-tokens).",
              icon: "arrow.right.to.line"),
    ]),

    .init(title: "Running on Your Mac", entries: [
        .init(term: "Unified memory",
              summary: "One memory pool shared by CPU and GPU",
              detail: "Apple Silicon uses a single pool of RAM for both CPU and GPU, so the whole chip can address the model without copying. This is why a Mac's total RAM — minus system headroom — is the real ceiling on model size, and why memory bandwidth, not raw GPU compute, sets generation speed.",
              icon: "memorychip"),
        .init(term: "Memory bandwidth",
              summary: "How fast weights can be streamed from RAM",
              detail: "Token generation is memory-bandwidth-bound: each token requires reading the active weights from RAM. A chip's GB/s (e.g. M3 Pro ~150, M3 Max ~400, M2 Ultra ~800) is the dominant factor in tokens/sec. Estimate: tok/s ≈ ~0.8 × bandwidth ÷ active-bytes-per-token.",
              icon: "speedometer"),
        .init(term: "Tokens per second",
              summary: "Generation speed you'll actually feel",
              detail: "The headline speed metric. Roughly memory bandwidth ÷ bytes read per token. A bigger model, less quantization, or longer context all lower it. ~10 tok/s is readable; 30+ feels snappy. Prefill (reading your prompt) is compute-bound and usually faster than decode.",
              icon: "gauge.with.dots.needle.67percent"),
        .init(term: "Prefill vs decode",
              summary: "Two phases with very different costs",
              detail: "Prefill processes your entire prompt in parallel (compute-bound, fast). Decode generates the answer one token at a time (memory-bandwidth-bound, slower). 'Time to first token' is dominated by prefill; sustained tokens/sec is the decode rate.",
              icon: "arrow.left.arrow.right"),
        .init(term: "Speculative decoding",
              summary: "A small model drafts, the big one verifies",
              detail: "A fast 'draft' model proposes several tokens that the large model checks in a single pass, accepting the ones it agrees with. This can multiply throughput with no quality loss. MTP-trained models can self-draft. Enable via mlx-lm (--num-draft-tokens).",
              icon: "hare"),
        .init(term: "Mac fit",
              summary: "Will the model run on your Mac?",
              detail: "LLM Seeker estimates required memory from params × bits-per-weight, plus a KV-cache reserve and system headroom. Comfortable = fits with margin; Tight = near the limit, may swap; Overflow = won't run smoothly.",
              icon: "checkmark.seal"),
    ]),

    .init(title: "Quality & Evaluation", entries: [
        .init(term: "Perplexity",
              summary: "How surprised the model is — lower is better",
              detail: "A measure of how well a model predicts text; lower means more confident and accurate. It's the standard yardstick for judging quantization damage: if a 4-bit model's perplexity is close to the 16-bit original, the quality loss is small.",
              icon: "questionmark.circle"),
        .init(term: "Benchmarks",
              summary: "Quality scores from the model card",
              detail: "Hugging Face stores eval results inside card_data.model_index. Common metrics: MMLU (knowledge), GSM8K (math), HumanEval (code), perplexity (lower is better). Treat them as relative comparisons, not absolute scores.",
              icon: "chart.bar.fill"),
        .init(term: "Temperature & sampling",
              summary: "How randomness is added to outputs",
              detail: "At each step the model produces a probability for every possible next token. Temperature scales those probabilities: low (0–0.3) is focused and deterministic, high (0.8+) is creative and varied. Set 0 for the single most likely token.",
              icon: "thermometer.medium"),
        .init(term: "Top-p / Top-k",
              summary: "Trim the candidate pool before sampling",
              detail: "Top-k keeps only the k most likely next tokens; top-p (nucleus) keeps the smallest set whose probabilities sum to p (e.g. 0.9). Both cut off the unlikely tail so output stays coherent while still allowing variety.",
              icon: "slider.horizontal.3"),
    ]),

    .init(title: "Training & Adaptation", entries: [
        .init(term: "Fine-tuning & distillation",
              summary: "Adapting or shrinking an existing model",
              detail: "Fine-tuning continues training a base model on new data to specialize it (LoRA is the lightweight form). Distillation trains a smaller 'student' model to imitate a larger 'teacher', capturing much of its quality at a fraction of the size.",
              icon: "wand.and.stars"),
        .init(term: "RAG (Retrieval-Augmented Generation)",
              summary: "Feed the model relevant documents at query time",
              detail: "Instead of relying only on training knowledge, RAG retrieves relevant text (often via embeddings) and injects it into the prompt as context. It keeps answers current and grounded without retraining — but consumes context-window tokens.",
              icon: "doc.text.magnifyingglass"),
    ]),
]

struct LearnView: View {
    @State private var expanded: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackground()
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                Text("Learn").font(Theme.Typography.title2).foregroundStyle(Theme.text)
                                Text("Quick reference for terms used across model cards.")
                                    .font(Theme.Typography.body).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        ForEach(sections) { section in
                            Text(section.title)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.text)
                                .padding(.bottom, -Theme.Spacing.sm)
                            ForEach(section.entries) { entry in
                                entryCard(entry)
                            }
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
            .navigationTitle("Learn")
        }
    }

    private func entryCard(_ entry: GlossaryEntry) -> some View {
        let isExpanded = expanded.contains(entry.id)
        return GlassCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: entry.icon).font(.headline).foregroundStyle(Theme.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.term).font(Theme.Typography.subheadline).foregroundStyle(Theme.text)
                        Text(entry.summary).font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if isExpanded {
                    Text(entry.detail)
                        .font(Theme.Typography.caption).foregroundStyle(Theme.textSecondary)
                        .padding(.top, Theme.Spacing.xs)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                }
            }
        }
    }
}

#Preview { LearnView() }

