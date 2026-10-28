import Foundation

/// A separate serial delegate enforces byte limits while receiving, including chunked responses.
private final class UpdateTransfer: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var body = Data()
    private var completion: ((Result<Data, Error>) -> Void)?
    private var session: URLSession?
    init(limit: Int, completion: @escaping (Result<Data, Error>) -> Void) {
        self.limit = limit; self.completion = completion
    }
    func start(_ url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Mr-Tab-D-Updater", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        session.dataTask(with: request).resume()
    }
    private func finish(_ result: Result<Data, Error>) {
        guard let callback = completion else { return }
        completion = nil
        callback(result)
        session?.invalidateAndCancel()
        session = nil
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(UpdateCheckError.invalidResponse)); return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            completionHandler(.cancel); finish(.failure(UpdateCheckError.tooLarge)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard completion != nil else { return }
        guard data.count <= limit - body.count else { finish(.failure(UpdateCheckError.tooLarge)); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(body)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let hosts = ["github.com", "api.github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"]
        guard let url = request.url, url.scheme == "https", hosts.contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil else {
            completionHandler(nil); finish(.failure(UpdateCheckError.invalidResponse)); return
        }
        completionHandler(request)
    }
}

enum UpdateHTTP {
    static func fetch(_ url: URL, limit: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            UpdateTransfer(limit: limit) { result in continuation.resume(with: result) }.start(url)
        }
    }
}
