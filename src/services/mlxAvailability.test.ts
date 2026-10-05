import { describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { mlxAvailability } from "./commands";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));

describe("mlxAvailability", () => {
  it("reports a runtime failure with its reason", async () => {
    vi.mocked(invoke).mockRejectedValueOnce("macOS AI bridge not found at /Applications/Skim.app/Contents/MacOS/skim-ai-macos-bridge");
    expect(await mlxAvailability()).toEqual({
      available: false,
      reason: "macOS AI bridge not found at /Applications/Skim.app/Contents/MacOS/skim-ai-macos-bridge",
    });
  });

  it("treats a missing plugin as plainly unsupported", async () => {
    vi.mocked(invoke).mockRejectedValueOnce("plugin skim-ai not found");
    expect(await mlxAvailability()).toEqual({ available: false });
  });

  it("passes through a working runtime", async () => {
    vi.mocked(invoke).mockResolvedValueOnce(true);
    expect(await mlxAvailability()).toEqual({ available: true });
  });
});
