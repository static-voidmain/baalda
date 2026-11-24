// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import Foundation
import Tauri
import UIKit

private struct Binding: Decodable { let key: String; let google: Bool }
private struct Request: Decodable {
    let key: String
    let google: Bool
    let staging: String
    let root: String
    let entries: [Entry]
}
private struct Entry: Decodable {
    let id: String
    let path: String
    let writable: Bool
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func failure(_ message: String) -> NSError {
    NSError(domain: "Baalda.CloudDrive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

// Refuse symbolic links in both trees, including an existing parent of a new file.
private func child(_ root: URL, _ path: String) throws -> URL {
    var url = root
    for part in path.components(separatedBy: "/") {
        guard !part.isEmpty, !part.hasPrefix("."), !part.contains("\\") else {
            throw failure("Invalid vault path")
        }
        url.appendPathComponent(part)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw failure("Symbolic links cannot be synchronized")
        }
    }
    return url
}

private func read(_ url: URL) throws -> Data? {
    do { return try Data(contentsOf: url, options: .mappedIfSafe) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
        return nil
    }
}

final class CloudDrive: Plugin, UIDocumentPickerDelegate {
    private let account = GoogleDriveAccount()
    private var pending: (Invoke, String)?
    private let queue = DispatchQueue(label: "com.baalda.cloud-drive")

    @objc func choose(_ invoke: Invoke) throws {
        let binding = try invoke.parseArgs(Binding.self)
        let key = binding.key
        DispatchQueue.main.async {
            guard self.pending == nil, let presenter = self.manager.viewController else {
                invoke.reject("Folder picker unavailable")
                return
            }
            if binding.google {
                guard let window = presenter.view.window else { invoke.reject("No active app window"); return }
                do {
                    try self.account.connect(window: window) { result in
                        switch result {
                        case .success: invoke.resolve(["selected": true])
                        case .failure(let error): invoke.reject(error.localizedDescription)
                        }
                    }
                } catch { invoke.reject(error.localizedDescription) }
                return
            }
            self.pending = (invoke, key)
            let picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
            picker.delegate = self
            presenter.present(picker, animated: true)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pending?.0.resolve(["selected": false])
        pending = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let (invoke, key) = pending else { return }
        pending = nil
        guard let url = urls.first, url.startAccessingSecurityScopedResource() else {
            invoke.reject("Access to the selected folder was denied")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "drive.folder." + key)
            invoke.resolve(["selected": true])
        } catch { invoke.reject(error.localizedDescription) }
    }

    @objc func sync(_ invoke: Invoke) throws {
        let request = try invoke.parseArgs(Request.self)
        queue.async {
            do {
                var incoming = [[String: String]]()
                let staging = URL(fileURLWithPath: request.staging)
                if request.google {
                    guard let token = DispatchQueue.main.sync(execute: { self.account.accessToken }) else {
                        throw failure("Connect Google Drive first")
                    }
                    let drive = GoogleFiles(token: token)
                    let root = URL(fileURLWithPath: request.root).resolvingSymlinksInPath()
                    let folderName = "Baalda-" + String(digest(Data(request.key.utf8)).prefix(16))
                    var copied = 0
                    var conflicts = 0
                    for entry in request.entries {
                        let source = try child(root, entry.path)
                        guard let local = try read(source) else { continue }
                        let parts = entry.path.components(separatedBy: "/")
                        let parent = try drive.folder([folderName] + Array(parts.dropLast()))
                        let name = parts.last!
                        let remote = try drive.read(name: name, parent: parent)
                        let stateKey = "drive.google." + digest(Data([parent, entry.id, name].joined(separator: "/").utf8))
                        let outcome = try self.reconcile(entry: entry, staging: staging, incoming: &incoming, local: local, remote: remote?.1,
                                                         writable: entry.writable, stateKey: stateKey) {
                            if let (id, _, etag) = remote {
                                try drive.update(id: id, data: local, etag: etag)
                            } else {
                                try drive.create(name: name, parent: parent, data: local)
                            }
                        }
                        copied += outcome.copied
                        conflicts += outcome.conflicts
                    }
                    invoke.resolve(["copied": copied, "conflicts": conflicts, "incoming": incoming])
                    return
                }
                guard let bookmark = UserDefaults.standard.data(forKey: "drive.folder." + request.key) else {
                    throw failure("Choose a cloud folder first")
                }
                var stale = false
                let folder = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
                guard !stale, folder.startAccessingSecurityScopedResource() else {
                    throw failure("Choose the cloud folder again to restore access")
                }
                defer { folder.stopAccessingSecurityScopedResource() }
                let local = URL(fileURLWithPath: request.root).resolvingSymlinksInPath()
                let destination = folder.resolvingSymlinksInPath().appendingPathComponent("Baalda-" + String(digest(Data(request.key.utf8)).prefix(16)))
                guard !(destination.path + "/").hasPrefix(local.path + "/"),
                      !(local.path + "/").hasPrefix(destination.path + "/") else {
                    throw failure("Choose a folder outside the active vault")
                }
                var copied = 0
                var conflicts = 0
                for entry in request.entries {
                    let source = try child(local, entry.path)
                    let target = try child(folder, destination.lastPathComponent + "/" + entry.path)
                    let stateKey = "drive.base." + digest(Data([request.key, destination.path, entry.id, entry.path].joined(separator: "\u{0}").utf8))
                    var coordinationError: NSError?
                    var result: Result<Void, Error>?
                    NSFileCoordinator().coordinate(writingItemAt: folder, options: [], error: &coordinationError) { _ in
                        result = Result {
                            guard let localData = try read(source) else { return }
                            let remote = try read(target)
                            let outcome = try self.reconcile(entry: entry, staging: staging, incoming: &incoming, local: localData, remote: remote,
                                                             writable: entry.writable, stateKey: stateKey) {
                                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try localData.write(to: target, options: remote == nil ? .withoutOverwriting : .atomic)
                            }
                            copied += outcome.copied
                            conflicts += outcome.conflicts
                        }
                    }
                    if let error = coordinationError { throw error }
                    try result?.get()
                }
                invoke.resolve(["copied": copied, "conflicts": conflicts, "incoming": incoming])
            } catch { invoke.reject(error.localizedDescription) }
        }
    }
    private func reconcile(entry: Entry, staging: URL, incoming: inout [[String: String]], local: Data, remote: Data?, writable: Bool,
                           stateKey: String, upload: () throws -> Void) throws -> (copied: Int, conflicts: Int) {
        let localHash = digest(local)
        let remoteHash = remote.map(digest)
        let base = UserDefaults.standard.string(forKey: stateKey)
        switch transferDirection(local: localHash, remote: remoteHash, base: base, writable: writable) {
        case .equal:
            UserDefaults.standard.set(localHash, forKey: stateKey)
            return (0, 0)
        case .upload:
            try upload()
            UserDefaults.standard.set(localHash, forKey: stateKey)
        case .download:
            guard let bytes = remote else { return (0, 1) }
            let name = UUID().uuidString
            try bytes.write(to: staging.appendingPathComponent(name), options: .withoutOverwriting)
            incoming.append(["id": entry.id, "path": entry.path, "name": name, "base": localHash])
            // Rust checks the vault epoch, stable identity and base before its atomic write.
            // The next equal pass records the new base once that write is visible.
            return (0, 0)
        case .conflict:
            return (0, 1)
        }
        return (1, 0)
    }

}

@_cdecl("init_plugin_cloud_drive")
func initCloudDrive() -> Plugin { CloudDrive() }
