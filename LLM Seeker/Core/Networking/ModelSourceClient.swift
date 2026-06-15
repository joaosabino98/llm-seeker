//
//  ModelSourceClient.swift
//  LLM Seeker
//

import Foundation

protocol ModelSourceClient {
    func search(query: String, filters: SearchFilters, cursor: String?, limit: Int) async throws -> SearchPage
    func fetchDetails(repoId: String) async throws -> ModelDetails
    func fetchFileTree(repoId: String, revision: String) async throws -> [RemoteFile]
    func downloadURL(for repoId: String, filePath: String, revision: String) -> URL
}

enum ModelSourceClientError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case notFound
    case unauthorized
    case gated
    case rateLimited
    case serverError(Int)
    case invalidResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError(let e): return "Decoding error: \(e.localizedDescription)"
        case .notFound: return "Model not found"
        case .unauthorized: return "Unauthorized — sign in to HuggingFace in Settings"
        case .gated: return "This model is gated. Accept the license on HuggingFace, then retry."
        case .rateLimited: return "Rate limited by HuggingFace. Try again shortly."
        case .serverError(let c): return "Server error: \(c)"
        case .invalidResponse: return "Invalid response from server"
        case .cancelled: return "Request was cancelled"
        }
    }
}

// MARK: - URLSession Factory
struct URLSessionFactory {
    static let backgroundIdentifier = "com.joaosabino.LLM-Seeker.background.download"

    static var ephemeral: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    static func background(delegate: (any URLSessionDelegate)?) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 86400 * 7
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}
