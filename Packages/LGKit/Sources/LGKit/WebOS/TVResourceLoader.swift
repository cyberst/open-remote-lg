import Foundation

/// Fetches icons and other resources the TV serves on :3000 (http) / :3001 (https, self-signed).
/// Trusts the self-signed certificate only for the TV's own host. Bounded in-memory cache.
final class TVResourceLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let host: String
    private let cache = NSCache<NSURL, NSData>()
    private let lock = NSLock()
    private var session: URLSession?

    init(host: String) {
        self.host = host
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    deinit { session?.invalidateAndCancel() }

    private func tvSession() -> URLSession {
        lock.withLock {
            if let session { return session }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.urlCache = nil
            config.httpCookieStorage = nil
            let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            session = s
            return s
        }
    }

    func data(from url: URL) async throws -> Data {
        if let hit = cache.object(forKey: url as NSURL) { return hit as Data }
        // Only ever talk to the TV itself: the privacy policy promises no internet requests, so an icon URL that
        // points anywhere else is refused (the UI shows its placeholder).
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let urlHost = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              urlHost.caseInsensitiveCompare(bare) == .orderedSame else {
            throw LGError.network("Refusing to load a resource from outside the TV")
        }
        do {
            let (data, response) = try await tvSession().data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw LGError.network("HTTP \(http.statusCode)")
            }
            cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
            return data
        } catch let error as LGError {
            throw error
        } catch {
            throw LGError.network(error.localizedDescription)
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host.caseInsensitiveCompare(host) == .orderedSame, let trust = space.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
