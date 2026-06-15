//
//  ModelDetailViewModel.swift
//  LLM Seeker
//

import Foundation
import Combine
import SwiftData

@MainActor
final class ModelDetailViewModel: ObservableObject {
    @Published var details: ModelDetails?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isDownloading = false

    let summary: ModelSummary
    private let client = HuggingFaceClient()

    init(summary: ModelSummary) { self.summary = summary }

    func load() async {
        guard details == nil, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            details = try await client.fetchDetails(repoId: summary.repoId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        details = nil
        await load()
    }

    var resolvedDetails: ModelDetails {
        details ?? ModelDetails(
            repoId: summary.repoId,
            displayName: summary.displayName,
            author: summary.author,
            description: summary.description,
            downloads: summary.downloads,
            likes: summary.likes,
            tags: summary.tags,
            totalBytes: summary.totalBytes,
            readme: nil,
            files: [],
            benchmarks: nil,
            paramCountB: summary.paramCountB,
            quantization: nil,
            framework: nil,
            pipelineTag: summary.pipelineTag,
            isAdapter: summary.isAdapter
        )
    }

    var quantizationLabel: String {
        if let q = details?.quantization { return q }
        let s = "\(summary.repoId) \(summary.displayName) \(summary.tags.joined(separator: " "))".lowercased()
        if s.contains("mxfp4") { return "MXFP4" }
        if s.contains("q4_k_m") { return "Q4_K_M" }
        if s.contains("4bit") || s.contains("4-bit") { return "4-bit" }
        if s.contains("8bit") || s.contains("8-bit") { return "8-bit" }
        if s.contains("fp16") || s.contains("bf16") { return "16-bit" }
        return "—"
    }

    var frameworkLabel: String {
        if let f = details?.framework { return f }
        let s = "\(summary.repoId) \(summary.displayName) \(summary.tags.joined(separator: " "))".lowercased()
        if s.contains("mlx") { return "MLX" }
        if s.contains("gguf") { return "GGUF" }
        if s.contains("safetensors") { return "safetensors" }
        return "—"
    }

    func macFitEstimate(profile: MacProfile?) -> MacFitEstimate? {
        guard let profile,
              let params = resolvedDetails.paramCountB ?? summary.paramCountB
                ?? MacFitEstimator.inferParamCountFromText("\(summary.repoId) \(summary.displayName)")
        else { return nil }
        let quant = resolvedDetails.quantization ?? quantizationLabel
        return MacFitEstimator.estimateFit(paramCountB: params, quantization: quant, macProfile: profile)
    }
}
