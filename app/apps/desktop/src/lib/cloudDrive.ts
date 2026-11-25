// SPDX-License-Identifier: Apache-2.0
import { invoke } from "@tauri-apps/api/core";
import { noteDocId, type AccessBoardResponse } from "./api";
import { authManager } from "./auth/authManager";
import { useStore } from "../store";
import { peekVaultStamp } from "./ipc";

export function cloudEntries(board: AccessBoardResponse | null) {
  if (!board?.complete) throw new Error("The server could not confirm current vault permissions.");
  const files = [...board.notes.map(n => ({ id: n.id, path: n.relPath })), ...board.files];
  if (board.modes.length !== board.folders.length + files.length) {
    throw new Error("The server returned an incomplete access listing.");
  }
  return files.flatMap((file, index) => {
    const mode = board.modes[board.folders.length + index];
    return mode === "e" || mode === "v" ? [{ ...file, writable: mode === "e" }] : [];
  });
}

export async function syncCloudDrive(choose: boolean, google: boolean) {
  const { vault, session, syncEnabled } = useStore.getState();
  if (!vault) throw new Error("Open a vault first.");
  const stamp = await peekVaultStamp(vault.path);
  const serverVaultId = stamp?.serverVaultId ?? null;
  let allowed = null;
  if (syncEnabled || serverVaultId || stamp?.organizationId) {
    if (!serverVaultId || !session || !syncEnabled ||
        stamp?.organizationId !== session.activeOrganizationId) {
      throw new Error("Reconnect to this team vault before syncing its files.");
    }
    // The server authorizes this request for owners and admins. Its per-document
    // view includes private rows so filter every entry by the caller's own mode.
    const [board, notes, files, blobs] = await Promise.all([
      authManager.api.getAccessBoard(serverVaultId, session.user.id),
      authManager.api.listNotes(serverVaultId),
      authManager.api.listFiles(serverVaultId),
      authManager.api.listVaultBlobs(serverVaultId),
    ]);
    const readable = new Map<string, string | undefined>([
      ...notes.map(note => [noteDocId(note), note.relPath ?? note.rel_path] as const),
      ...files.map(file => [file.docId ?? file.id, file.path] as const),
    ]);
    allowed = cloudEntries(board).filter(entry => readable.get(entry.id) === entry.path);
    for (const blob of blobs) {
      if (!blob.docId && blob.relPath?.startsWith("attachments/")) {
        allowed.push({ id: "attachment:" + blob.sha256, path: blob.relPath, writable: false });
      }
    }
  }
  const current = useStore.getState();
  if (current.vault?.epoch !== vault.epoch || current.session?.user.id !== session?.user.id) {
    throw new Error("The active vault or account changed.");
  }
  return invoke<{ selected?: boolean; copied?: number; conflicts?: number }>("cloud_drive", {
    choose, google, expectedEpoch: vault.epoch, serverVaultId, allowed,
  });
}
