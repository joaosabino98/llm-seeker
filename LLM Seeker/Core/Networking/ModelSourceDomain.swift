//
//  ModelSourceDomain.swift
//  LLM Seeker
//

import Foundation

// MARK: - Shared Domain Models

struct SearchPage {
    let models: [ModelSummary]
    let nextCursor: String?
}

struct ModelSummary: Identifiable {
    var id: String { repoId }
    let repoId: String              // "owner/model"
    let displayName: String
    let author: String?
    let description: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]
    let totalBytes: Int64?
    let paramCountB: Double?
    let pipelineTag: String?
    let trendingScore: Double?
    let isAdapter: Bool
}

struct ModelDetails {
    let repoId: String
    let displayName: String
    let author: String?
    let description: String?
    let downloads: Int?
    let likes: Int?
    let tags: [String]
    let totalBytes: Int64?
    let readme: String?
    let files: [RemoteFile]
    let benchmarks: [BenchmarkResult]?
    let paramCountB: Double?
    let quantization: String?
    let framework: String?
    let pipelineTag: String?
    let isAdapter: Bool
}

struct RemoteFile: Hashable {
    let path: String
    let bytes: Int64
    let sha: String?
}

struct BenchmarkResult: Hashable {
    let task: String
    let metric: String
    let value: Double
}

// MARK: - Search Filters

struct SearchFilters: Codable, Equatable {
    var frameworks: [String] = []           // mlx, gguf, safetensors
    var quantizations: [String] = []        // 4bit, 8bit, q4_k_m, mxfp4
    var minSizeGB: Int? = nil
    var maxSizeGB: Int? = nil
    var mlxFriendlyOnly: Bool = false
    var pipelineTag: String? = nil          // text-generation, image-text-to-text, ...
}

// MARK: - HF DTO conversions

extension HFModel {
    func toModelSummary() -> ModelSummary {
        let repo = self.modelId ?? self.id ?? "unknown/huggingface-model"
        let bytes = self.siblings?.reduce(0) { $0 + ($1.size ?? 0) }
        let nameHint = self.name ?? repo
        let tagList = self.tags ?? []
        let paramCountB = MacFitEstimator.inferParamCount(fromRepoName: "\(repo) \(nameHint)")
        let isAdapter = tagList.contains("peft") || tagList.contains("adapter") || tagList.contains("lora")

        return ModelSummary(
            repoId: repo,
            displayName: self.name ?? repo,
            author: self.author,
            description: self.description,
            downloads: self.downloads,
            likes: self.likes,
            tags: tagList,
            totalBytes: bytes,
            paramCountB: paramCountB,
            pipelineTag: self.pipeline_tag,
            trendingScore: self.trendingScore,
            isAdapter: isAdapter
        )
    }
}

extension HFModelDetails {
    func toModelDetails(readme: String? = nil, fileTree: [RemoteFile]? = nil) -> ModelDetails {
        let repo = self.modelId ?? self.id ?? "unknown/huggingface-model"
        let tagList = self.tags ?? []

        // Prefer file-tree (LFS-aware) sizes when provided; otherwise fall back to siblings.
        let files: [RemoteFile]
        if let tree = fileTree, !tree.isEmpty {
            files = tree
        } else {
            files = (self.siblings ?? []).map {
                RemoteFile(path: $0.rfilename, bytes: $0.size ?? 0, sha: $0.blob_id)
            }
        }
        let bytes = files.reduce(0) { $0 + $1.bytes }

        // Param count: prefer safetensors metadata, fall back to repo name parsing.
        let safetensorParams = self.safetensors?.parameters?.values.reduce(0, +)
        let paramCountB: Double?
        if let p = safetensorParams, p > 0 {
            paramCountB = Double(p) / 1e9
        } else {
            paramCountB = MacFitEstimator.inferParamCount(fromRepoName: "\(repo) \(self.name ?? "")")
        }

        let quantization = inferQuantization(fromRepo: repo, tags: tagList)
        let framework = inferFramework(fromTags: tagList, files: files)
        let isAdapter = tagList.contains("peft") || tagList.contains("adapter") || tagList.contains("lora")
        let benchmarks = extractBenchmarks(from: self.cardData)

        return ModelDetails(
            repoId: repo,
            displayName: self.name ?? repo,
            author: self.author,
            description: self.description,
            downloads: self.downloads,
            likes: self.likes,
            tags: tagList,
            totalBytes: bytes > 0 ? bytes : nil,
            readme: readme,
            files: files,
            benchmarks: benchmarks,
            paramCountB: paramCountB,
            quantization: quantization,
            framework: framework,
            pipelineTag: self.pipeline_tag,
            isAdapter: isAdapter
        )
    }

    private func inferQuantization(fromRepo repo: String, tags: [String]) -> String? {
        let haystack = (repo + " " + tags.joined(separator: " ")).lowercased()
        if haystack.contains("mxfp4") { return "MXFP4" }
        if haystack.contains("q4_k_m") { return "Q4_K_M" }
        if haystack.contains("q4") || haystack.contains("4bit") || haystack.contains("4-bit") { return "4-bit" }
        if haystack.contains("q8") || haystack.contains("8bit") || haystack.contains("8-bit") { return "8-bit" }
        if haystack.contains("bf16") { return "BF16" }
        if haystack.contains("fp16") { return "FP16" }
        return nil
    }

    private func inferFramework(fromTags tags: [String], files: [RemoteFile]) -> String? {
        let tagSet = Set(tags.map { $0.lowercased() })
        if tagSet.contains("mlx") { return "MLX" }
        if tagSet.contains("gguf") || files.contains(where: { $0.path.hasSuffix(".gguf") }) { return "GGUF" }
        if files.contains(where: { $0.path.hasSuffix(".safetensors") }) { return "safetensors" }
        return nil
    }

    private func extractBenchmarks(from card: HFCardData?) -> [BenchmarkResult]? {
        guard let entries = card?.model_index else { return nil }
        var out: [BenchmarkResult] = []
        for entry in entries {
            guard case .object(let dict) = entry else { continue }
            guard case .array(let resultsArr)? = dict["results"] else { continue }
            for result in resultsArr {
                guard case .object(let resObj) = result else { continue }
                var task = "task"
                if case .object(let taskObj)? = resObj["task"], case .string(let t)? = taskObj["type"] {
                    task = t
                }
                guard case .array(let metrics)? = resObj["metrics"] else { continue }
                for metric in metrics {
                    guard case .object(let m) = metric else { continue }
                    var metricName = "metric"
                    if case .string(let n)? = m["name"] { metricName = n }
                    else if case .string(let n)? = m["type"] { metricName = n }
                    var value: Double?
                    if case .double(let v)? = m["value"] { value = v }
                    else if case .int(let v)? = m["value"] { value = Double(v) }
                    if let v = value {
                        out.append(BenchmarkResult(task: task, metric: metricName, value: v))
                    }
                }
            }
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - README YAML front-matter strip

enum ReadmeSanitizer {
    static func stripFrontMatter(_ md: String) -> String {
        let lines = md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return md }
        var idx = 1
        while idx < lines.count && lines[idx].trimmingCharacters(in: .whitespaces) != "---" {
            idx += 1
        }
        guard idx < lines.count else { return md }
        return lines[(idx + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
