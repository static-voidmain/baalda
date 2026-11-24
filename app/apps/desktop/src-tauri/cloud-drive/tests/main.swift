// SPDX-License-Identifier: Apache-2.0
// Compile alongside TransferDirection.swift; no Apple account or device needed.
precondition(transferDirection(local: "a", remote: nil, base: nil, writable: false) == .upload)
precondition(transferDirection(local: "a", remote: "a", base: nil, writable: false) == .equal)
precondition(transferDirection(local: "b", remote: "a", base: "a", writable: true) == .upload)
precondition(transferDirection(local: "a", remote: "b", base: "a", writable: true) == .download)
precondition(transferDirection(local: "a", remote: "b", base: "a", writable: false) == .conflict)
precondition(transferDirection(local: "a", remote: nil, base: "a", writable: true) == .conflict)
precondition(transferDirection(local: "a", remote: "b", base: "c", writable: true) == .conflict)
precondition(transferDirection(local: "a", remote: "b", base: nil, writable: true) == .conflict)
