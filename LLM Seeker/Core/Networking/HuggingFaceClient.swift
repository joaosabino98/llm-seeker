//
//  HuggingFaceClient.swift
//  LLM Seeker
//

import Foundation

actor HuggingFaceClient: ModelSourceClient {
    private let baseURL = "https://huggingface.co/api"
    private let rawHost = "https://huggingface.co"
    private let session: URLSession

    private struct HFSearchEnvelope: Decodable { let models: [HFModel] }

    init(session: URLSession = URLSessionFactory.ephemeral) {
        self.session = session
    }

    // MARK: - Search
    func search(
        query: String,
        filters: SearchFilters,
        cursor: String?,
        limit: Int = 20
    ) async throws -> SearchPage {
        var components = URLComponents(string: "\(baseURL)/models")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
        ]
        if !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }
        if let cursor = cursor {
            queryItems.append(URLQueryItem(name: "skip", value: cursor))
        }
        if filters.mlxFriendlyOnly {
            queryItems.append(URLQueryItem(name: "author", value: "mlx-community"))
        }
        for fw in filters.frameworks {
            queryItems.append(URLQueryItem(name: "filter", value: fw))
        }
        if let pipeline = filters.pipelineTag {
            queryItems.append(URLQueryItem(name: "pipeline_tag", value: pipeline))
        }
        components?.queryItems = queryItems

        guard let url = components?.url else { throw ModelSourceClientError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeader(to: &request)

        let (data, response) = try await sendWithBackoff(request)

        let decoder = JSONDecoder()
        let models: [HFModel]
        if let direct = try? decoder.decode([HFModel].self, from: data) {
            models = direct
        } else if let env = try? decoder.decode(HFSearchResponse.self, from: data) {
            models = env.models ?? []
        } else if let env = try? decoder.decode(HFSearchEnvelope.self, from: data) {
            models = env.models
        } else {
            do {
                _ = try decoder.decode([HFModel].self, from: data)
                models = []
            } catch {
                logDecodeFailure(endpoint: "/models", data: data, error: error)
                throw ModelSourceClientError.decodingError(error)
            }
        }

        let next = extractNextCursor(from: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Link"))
        return SearchPage(models: models.map { $0.toModelSummary() }, nextCursor: next)
    }

    // MARK: - Details (parallel fetch of model JSON + README + tree)
    func fetchDetails(repoId: String) async throws -> ModelDetails {
        async let detailsTask = fetchRawDetails(repoId: repoId)
        async let readmeTask = fetchModelCard(repoId: repoId)
        async let treeTask: [RemoteFile] = (try? fetchFileTree(repoId: repoId, revision: "main")) ?? []

        let details = try await detailsTask
        let readme = await readmeTask
        let tree = await treeTask

        return details.toModelDetails(readme: readme, fileTree: tree.isEmpty ? nil : tree)
    }

    private func fetchRawDetails(repoId: String) async throws -> HFModelDetails {
        let url = URL(string: "\(baseURL)/models/\(repoId)")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeader(to: &request)
        let (data, _) = try await sendWithBackoff(request)
        do {
            return try JSONDecoder().decode(HFModelDetails.self, from: data)
        } catch {
            logDecodeFailure(endpoint: "/models/{repoId}", data: data, error: error)
            throw ModelSourceClientError.decodingError(error)
        }
    }

    func fetchModelCard(repoId: String) async -> String? {
        let url = URL(string: "\(rawHost)/\(repoId)/raw/main/README.md")!
        var request = URLRequest(url: url)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        addAuthHeader(to: &request)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            return ReadmeSanitizer.stripFrontMatter(raw)
        } catch {
            return nil
        }
    }

    // MARK: - File Tree
    func fetchFileTree(repoId: String, revision: String = "main") async throws -> [RemoteFile] {
        let url = URL(string: "\(baseURL)/models/\(repoId)/tree/\(revision)?recursive=true")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        addAuthHeader(to: &request)

        let (data, _) = try await sendWithBackoff(request)

        let decoder = JSONDecoder()
        let items: [HFTreeItem]
        if let direct = try? decoder.decode([HFTreeItem].self, from: data) {
            items = direct
        } else if let wrapped = try? decoder.decode(HFTreeResponse.self, from: data) {
            items = wrapped.tree
        } else {
            do {
                _ = try decoder.decode([HFTreeItem].self, from: data)
                items = []
            } catch {
                logDecodeFailure(endpoint: "/models/{repoId}/tree", data: data, error: error)
                throw ModelSourceClientError.decodingError(error)
            }
        }

        return items
            .filter { ($0.type ?? "file") == "file" }
            .filter { !$0.path.hasSuffix("/") && !$0.path.hasPrefix(".git") }
            .map { item in
                RemoteFile(
                    path: item.path,
                    bytes: item.lfs?.size ?? item.size ?? 0,
                    sha: item.lfs?.sha256 ?? item.blob_id
                )
            }
    }

    // MARK: - Download URL
    func downloadURL(for repoId: String, filePath: String, revision: String = "main") -> URL {
        let encoded = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
        let urlString = "\(rawHost)/\(repoId)/resolve/\(revision)/\(encoded)"
        return URL(string: urlString) ?? URL(fileURLWithPath: "")
    }

    // MARK: - Helpers
    private func addAuthHeader(to request: inout URLRequest) {
        if let token = KeychainService.huggingFaceToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private func sendWithBackoff(_ request: URLRequest, maxAttempts: Int = 3) async throws -> (Data, URLResponse) {
        var attempt = 0
        var lastError: Error = ModelSourceClientError.invalidResponse
        while attempt < maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                try validateResponse(response)
                return (data, response)
            } catch ModelSourceClientError.rateLimited {
                attempt += 1
                if attempt >= maxAttempts { throw ModelSourceClientError.rateLimited }
                let delayNs = UInt64(pow(2.0, Double(attempt)) * 500_000_000)
                try await Task.sleep(nanoseconds: delayNs)
                continue
            } catch ModelSourceClientError.serverError(let code) where (500..<600).contains(code) {
                attempt += 1
                if attempt >= maxAttempts { throw ModelSourceClientError.serverError(code) }
                let delayNs = UInt64(pow(2.0, Double(attempt)) * 500_000_000)
                try await Task.sleep(nanoseconds: delayNs)
                continue
            } catch {
                lastError = error
                throw error
            }
        }
        throw lastError
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ModelSourceClientError.invalidResponse }
        switch http.statusCode {
        case 200...299: break
        case 401: throw ModelSourceClientError.unauthorized
        case 403: throw ModelSourceClientError.gated
        case 404: throw ModelSourceClientError.notFound
        case 429: throw ModelSourceClientError.rateLimited
        case 500...599: throw ModelSourceClientError.serverError(http.statusCode)
        default: throw ModelSourceClientError.serverError(http.statusCode)
        }
    }

    private func extractNextCursor(from linkHeader: String?) -> String? {
        guard let link = linkHeader else { return nil }
        if let range = link.range(of: "skip=(\\d+)", options: .regularExpression) {
            return String(link[range]).replacingOccurrences(of: "skip=", with: "")
        }
        return nil
    }

    private func logDecodeFailure(endpoint: String, data: Data, error: Error) {
        let sample = String(decoding: data.prefix(600), as: UTF8.self)
        print("[HuggingFaceClient] Decode failure at \(endpoint): \(error)")
        print("[HuggingFaceClient] Payload preview: \(sample)")
    }
}
