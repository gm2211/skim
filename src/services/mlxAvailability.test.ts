import { describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import { fmAvailability, mlxAvailability } from "./commands";

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

describe("fmAvailability", () => {
  it("reports a helper failure instead of claiming the platform lacks support", async () => {
    vi.mocked(invoke).mockRejectedValueOnce("macOS AI bridge exited before replying (killed by signal 5)");
    expect(await fmAvailability()).toEqual({
      available: false,
      status: "runtime-error",
      message: "Apple Intelligence could not start: macOS AI bridge exited before replying (killed by signal 5)",
    });
  });
});
