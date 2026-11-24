// SPDX-License-Identifier: Apache-2.0
enum TransferDirection { case equal, upload, download, conflict }

func transferDirection(local: String, remote: String?, base: String?, writable: Bool) -> TransferDirection {
    if remote == local { return .equal }
    if remote == base { return .upload }
    if remote != nil && writable && local == base { return .download }
    return .conflict
}
