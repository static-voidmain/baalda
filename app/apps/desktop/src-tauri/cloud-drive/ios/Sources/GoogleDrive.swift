// SPDX-License-Identifier: Apache-2.0
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

private func driveError(_ message: String) -> NSError {
    NSError(domain: "Baalda.GoogleDrive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func base64URL(_ bytes: Data) -> String {
    bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func randomVerifier() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw driveError("Cannot start secure sign-in")
    }
    return base64URL(Data(bytes))
}

// Only an access token lives in memory. Reconnect after expiry or an app restart.
final class GoogleDriveAccount: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private weak var window: UIWindow?
    private(set) var accessToken: String?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window ?? ASPresentationAnchor()
    }

    func connect(window: UIWindow, completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard session == nil else { throw driveError("Google sign-in is already open") }
        guard let client = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              client.hasSuffix(".apps.googleusercontent.com") else {
            throw driveError("This build needs a Google Drive iOS OAuth client ID")
        }
        self.window = window
        let scheme = client.components(separatedBy: ".").reversed().joined(separator: ".")
        let redirect = scheme + ":/oauth2redirect"
        let verifier = try randomVerifier()
        let state = try randomVerifier()
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        let query = ["client_id": client, "redirect_uri": redirect, "response_type": "code",
                     "scope": "https://www.googleapis.com/auth/drive.file", "state": state,
                     "code_challenge": challenge, "code_challenge_method": "S256", "prompt": "select_account"]
        auth.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        session = ASWebAuthenticationSession(url: auth.url!, callbackURLScheme: scheme) { url, error in
            self.session = nil
            do {
                if let error = error { throw error }
                let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
                guard items.first(where: { $0.name == "state" })?.value == state,
                      let code = items.first(where: { $0.name == "code" })?.value else {
                    throw driveError("Google authorization was declined")
                }
                var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                var form = URLComponents()
                form.queryItems = ["client_id": client, "redirect_uri": redirect, "code": code,
                                   "grant_type": "authorization_code", "code_verifier": verifier]
                    .map { URLQueryItem(name: $0.key, value: $0.value) }
                request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
                URLSession.shared.dataTask(with: request) { data, response, error in
                    DispatchQueue.main.async {
                        do {
                            if let error = error { throw error }
                            guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let token = json["access_token"] as? String else {
                                throw driveError("Google could not authorize this app")
                            }
                            self.accessToken = token
                            completion(.success(()))
                        } catch { completion(.failure(error)) }
                    }
                }.resume()
            } catch { completion(.failure(error)) }
        }
        session?.presentationContextProvider = self
        guard session?.start() == true else { session = nil; throw driveError("Cannot open Google sign-in") }
    }
}

private final class Reply: @unchecked Sendable {
    var result: Result<(Data, HTTPURLResponse), Error>?
}

// All calls run on the serial transfer queue. Never send credentials to a URL
// supplied by a document or a response from Drive.
final class GoogleFiles {
    private let token: String
    private var folders = [String: String]()
    init(token: String) { self.token = token }

    private func request(_ method: String, _ route: String, query: [String: String] = [:],
                         body: Data? = nil, mime: String = "application/json", etag: String? = nil)
        throws -> (Data, HTTPURLResponse) {
        var parts = URLComponents(string: "https://www.googleapis.com" + route)!
        parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: parts.url!)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let etag = etag { req.setValue(etag, forHTTPHeaderField: "If-Match") }
        if let body = body { req.httpBody = body; req.setValue(mime, forHTTPHeaderField: "Content-Type") }
        let signal = DispatchSemaphore(value: 0)
        let reply = Reply()
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { signal.signal() }
            reply.result = Result {
                if let error = error { throw error }
                guard let http = response as? HTTPURLResponse else { throw driveError("No response from Google Drive") }
                guard (200..<300).contains(http.statusCode) else {
                    throw driveError(http.statusCode == 401 ? "Reconnect Google Drive" : "Drive request failed (HTTP " + String(http.statusCode) + ")")
                }
                return (data ?? Data(), http)
            }
        }.resume()
        signal.wait()
        return try reply.result!.get()
    }

    private func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func find(name: String, parent: String) throws -> [String: String]? {
        let filter = "trashed = false and '" + escape(parent) + "' in parents and name = '" + escape(name) + "'"
        let (data, _) = try request("GET", "/drive/v3/files", query: ["q": filter, "pageSize": "2", "fields": "nextPageToken,files(id,mimeType)"])
        struct Page: Decodable { let files: [[String: String]]; let nextPageToken: String? }
        let page = try JSONDecoder().decode(Page.self, from: data)
        guard page.files.count <= 1, page.nextPageToken == nil else { throw driveError("Duplicate names in Google Drive: " + name) }
        return page.files.first
    }

    func folder(_ path: [String]) throws -> String {
        var parent = "root"
        for part in path {
            let cacheKey = parent + "/" + part
            if let cached = folders[cacheKey] { parent = cached; continue }
            let mime = "application/vnd.google-apps.folder"
            if let found = try find(name: part, parent: parent) {
                guard found["mimeType"] == mime, let id = found["id"] else { throw driveError("Expected a Drive folder") }
                parent = id
            } else {
                let body = try JSONSerialization.data(withJSONObject: ["name": part, "mimeType": mime, "parents": [parent]])
                let (data, _) = try request("POST", "/drive/v3/files", body: body)
                struct Created: Decodable { let id: String }
                parent = try JSONDecoder().decode(Created.self, from: data).id
            }
            folders[cacheKey] = parent
        }
        return parent
    }

    func read(name: String, parent: String) throws -> (String, Data, String?)? {
        guard let file = try find(name: name, parent: parent), let id = file["id"] else { return nil }
        guard !(file["mimeType"] ?? "").hasPrefix("application/vnd.google-apps.") else { throw driveError("A native Google document occupies " + name) }
        let (data, response) = try request("GET", "/drive/v3/files/" + id, query: ["alt": "media"])
        return (id, data, response.value(forHTTPHeaderField: "ETag"))
    }

    func update(id: String, data: Data, etag: String?) throws {
        guard let etag = etag else { throw driveError("Drive did not return a version for a safe update") }
        _ = try request("PATCH", "/upload/drive/v3/files/" + id, query: ["uploadType": "media"],
                        body: data, mime: "application/octet-stream", etag: etag)
    }

    func create(name: String, parent: String, data: Data) throws {
        let boundary = UUID().uuidString
        let metadata = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent]])
        var body = Data(("--" + boundary + "\r\nContent-Type: application/json\r\n\r\n").utf8)
        body.append(metadata)
        body.append(Data(("\r\n--" + boundary + "\r\nContent-Type: application/octet-stream\r\n\r\n").utf8))
        body.append(data)
        body.append(Data(("\r\n--" + boundary + "--\r\n").utf8))
        _ = try request("POST", "/upload/drive/v3/files", query: ["uploadType": "multipart"],
                        body: body, mime: "multipart/related; boundary=" + boundary)
    }
}
