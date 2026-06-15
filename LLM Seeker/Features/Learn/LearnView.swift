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

private let glossary: [GlossaryEntry] = [
    .init(term: "MLX",
          summary: "Apple's array framework for Apple Silicon",
          detail: "MLX is Apple's NumPy-like framework optimized for Apple Silicon's unified memory. Models tagged `mlx` use the .safetensors layout with MLX-specific tensor names. Best run via mlx-lm or oMLX on macOS.",
          icon: "cpu"),
    .init(term: "GGUF",
          summary: "Single-file format used by llama.cpp",
          detail: "GGUF packs weights, tokenizer, and metadata into one file. Quantized variants (Q4_K_M, Q8_0, etc.) trade quality for size. Run with llama.cpp, Ollama, or LM Studio.",
          icon: "doc.fill"),
    .init(term: "safetensors",
          summary: "Safe binary tensor container",
          detail: "Drop-in replacement for PyTorch .bin pickles. No code-execution risk on load. Used by Hugging Face Transformers, MLX, and many runtimes.",
          icon: "lock.shield"),
    .init(term: "Quantization",
          summary: "Lower-precision weights to shrink models",
          detail: "Converts FP16/BF16 weights to lower bit widths (8, 4, or fewer). Common labels: Q4_K_M (good 4-bit balance), Q8_0 (near-lossless 8-bit), MXFP4 (microscaling FP4 used in MoE LLMs).",
          icon: "rectangle.compress.vertical"),
    .init(term: "MXFP4",
          summary: "Microscaling 4-bit floating point",
          detail: "FP4 variant with shared per-block scale (~4.5 bits/weight effective). Used by frontier MoE LLMs to fit in unified memory while keeping FP-style range.",
          icon: "scale.3d"),
    .init(term: "MTP (Multi-Token Prediction)",
          summary: "Predict several tokens per forward pass",
          detail: "Models trained with auxiliary heads that predict 2+ future tokens at once. Speeds up generation when the runtime supports speculative decoding (e.g. mlx-lm with --num-draft-tokens).",
          icon: "arrow.right.to.line"),
    .init(term: "Benchmarks",
          summary: "Quality scores from card_data.model_index",
          detail: "Hugging Face stores eval results inside `card_data.model_index`. Common metrics: MMLU (knowledge), GSM8K (math), HumanEval (code), perplexity (lower is better).",
          icon: "chart.bar.fill"),
    .init(term: "Adapter / LoRA",
          summary: "Small fine-tune that rides on a base model",
          detail: "LoRA / PEFT adapters add a few MB of weights on top of an unmodified base model. You must download the base model separately on your Mac.",
          icon: "puzzlepiece"),
    .init(term: "Pipeline tag",
          summary: "Primary task the model is trained for",
          detail: "Hugging Face categorizes models by `pipeline_tag`: text-generation (LLM), image-text-to-text (VLM), feature-extraction (embeddings), image-to-text (OCR/captioning).",
          icon: "tag.fill"),
    .init(term: "Mac fit",
          summary: "Will the model run on your Mac?",
          detail: "LLM Seeker estimates required memory from params × bits-per-weight, plus a KV-cache reserve and system headroom. Comfortable = fits with margin; Tight = will swap; Overflow = won't run smoothly.",
          icon: "checkmark.seal"),
]

struct LearnView: View {
    @State private var expanded: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                Text("Learn").font(Theme.Typography.title2).foregroundStyle(Theme.text)
                                Text("Quick reference for terms used across model cards.")
                                    .font(Theme.Typography.body).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        ForEach(glossary) { entry in
                            entryCard(entry)
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
