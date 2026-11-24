// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it, vi } from "vitest";
vi.mock("../auth/authManager", () => ({ authManager: {} }));
vi.mock("../../store", () => ({ useStore: {} }));
import { cloudEntries } from "../cloudDrive";

describe("team cloud sync", () => {
  const board = {
    folders: [{ id: "team", path: "Team", color: null }],
    notes: [{ id: "a", relPath: "A.md" }, { id: "b", relPath: "B.md" }],
    files: [{ id: "c", path: "C.pdf" }], modes: "mevn", complete: true,
  };
  it("uses the note and file modes after the folder prefix", () => {
    expect(cloudEntries(board)).toEqual([
      { id: "a", path: "A.md", writable: true }, { id: "b", path: "B.md", writable: false },
    ]);
  });
  it("refuses unavailable or incomplete permission listings", () => {
    for (const invalid of [null, { ...board, complete: false }, { ...board, modes: "me" }]) {
      expect(() => cloudEntries(invalid)).toThrow();
    }
  });
});
