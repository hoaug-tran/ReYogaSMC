import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum ReleaseCheckResult {
    case transportFailure(String)
    case noPublicRelease
    case httpFailure(Int)
    case available(tag: String, url: URL)
    case upToDate
    case unversioned(tag: String, url: URL)
    case invalidResponse

    var succeeded: Bool {
        switch self {
        case .transportFailure, .httpFailure, .invalidResponse: return false
        default: return true
        }
    }
}

// Request and response policy; observable preferences and HUD updates stay on main.
enum ReleaseService {
    static func request(repository: String?) -> URLRequest? {
        guard let repository = repository, UInt64(repository) != nil,
              let url = URL(string: "https://api.github.com/repositories/\(repository)/releases/latest") else { return nil }
        // Repository IDs survive GitHub renames.
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ReYogaSMC", forHTTPHeaderField: "User-Agent")
        return request
    }

    @discardableResult
    static func check(request: URLRequest, currentVersion: String, completion: @escaping (ReleaseCheckResult) -> Void) -> URLSessionDataTask {
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            completion(parse(data: data, response: response, error: error, currentVersion: currentVersion))
        }
        task.resume()
        return task
    }

    static func parse(data: Data?, response: URLResponse?, error: Error?, currentVersion: String) -> ReleaseCheckResult {
        if let error = error { return .transportFailure(error.localizedDescription) }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return .noPublicRelease }
        guard code == 200 else { return .httpFailure(code) }
        guard let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let link = json["html_url"] as? String,
              let url = URL(string: link), url.scheme == "https", url.host == "github.com",
              url.pathComponents.count >= 5, url.pathComponents[3] == "releases" else { return .invalidResponse }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        let numeric = !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }
        guard numeric else { return .unversioned(tag: tag, url: url) }
        return version.compare(currentVersion, options: .numeric) == .orderedDescending
            ? .available(tag: tag, url: url) : .upToDate
    }
}
