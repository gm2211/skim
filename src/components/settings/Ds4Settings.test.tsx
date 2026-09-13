import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { Ds4Settings } from "./Ds4Settings";

const state = vi.hoisted(() => ({
  models: [] as Array<{ filename: string; path: string; size_bytes: number; is_partial: boolean; download_repo_id: string | null }>,
  system: { total_memory_gb: 128, available_memory_gb: 120, max_model_size_gb: 96 },
  progress: null as { filename: string; downloaded: number; total: number; percent: number } | null,
}));
vi.mock("../../hooks/useModels", () => ({
  useLocalModels: () => ({ data: state.models, refetch: vi.fn() }),
  useSystemInfo: () => ({ data: state.system }),
  useDownloadModel: () => ({ isPending: false, mutateAsync: vi.fn().mockResolvedValue("/tmp/ds4.gguf") }),
  useCancelDownload: () => ({ mutate: vi.fn() }),
  useDownloadProgress: () => state.progress,
}));
vi.mock("../../services/commands", () => ({
  ds4Status: vi.fn().mockResolvedValue({ runtime_available: true, running: false, model_path: null, error: null }),
  ds4Start: vi.fn(), ds4Stop: vi.fn(), downloadModel: vi.fn(),
}));

describe("Ds4Settings", () => {
  it("shows the pinned model download and runtime state without API key fields", async () => {
    render(<Ds4Settings ai={{ provider: "ds4", api_key: null, endpoint: null, model: null, local_model_path: null } as any} updateAi={vi.fn()} />);
    expect(await screen.findByRole("heading", { name: "DeepSeek (DS4)" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Download model" })).toBeInTheDocument();
    expect(screen.queryByLabelText("API Key")).not.toBeInTheDocument();
  });

  it("selects a complete installed model into the draft without starting it", async () => {
    state.models = [{ filename: "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf", path: "/models/ds4.gguf", size_bytes: 1, is_partial: false, download_repo_id: null }];
    const updateAi = vi.fn();
    render(<Ds4Settings ai={{ provider: "ds4", api_key: null, endpoint: null, model: null, local_model_path: null } as any} updateAi={updateAi} />);
    await waitFor(() => expect(updateAi).toHaveBeenCalledWith({ model: "deepseek-v4-flash", local_model_path: "/models/ds4.gguf" }));
    expect(screen.queryByRole("button", { name: "Start DS4" })).toBeInTheDocument();
    state.models = [];
  });

  it("offers resume for partial downloads and disables download below the memory recommendation", () => {
    state.models = [{ filename: "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf", path: "/models/ds4.gguf.part", size_bytes: 1, is_partial: true, download_repo_id: "antirez/deepseek-v4-gguf" }];
    state.system = { total_memory_gb: 64, available_memory_gb: 60, max_model_size_gb: 48 };
    render(<Ds4Settings ai={{ provider: "ds4", api_key: null, endpoint: null, model: null, local_model_path: null } as any} updateAi={vi.fn()} />);
    expect(screen.getByRole("button", { name: "Resume download" })).toBeDisabled();
    expect(screen.queryByRole("button", { name: "Start DS4" })).not.toBeInTheDocument();
    state.models = [];
    state.system = { total_memory_gb: 128, available_memory_gb: 120, max_model_size_gb: 96 };
  });

  it("shows progress and cancel while the pinned file downloads", () => {
    state.progress = { filename: "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf", downloaded: 40_000_000_000, total: 80_000_000_000, percent: 50 };
    render(<Ds4Settings ai={{ provider: "ds4", api_key: null, endpoint: null, model: null, local_model_path: null } as any} updateAi={vi.fn()} />);
    expect(screen.getByRole("status")).toHaveTextContent("50%");
    expect(screen.getByRole("button", { name: "Cancel download" })).toBeInTheDocument();
    state.progress = null;
  });

  it("returns to resume state when cancellation settles", () => {
    state.models = [{ filename: "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf", path: "/models/ds4.gguf.part", size_bytes: 1, is_partial: true, download_repo_id: "antirez/deepseek-v4-gguf" }];
    state.progress = { filename: "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf", downloaded: 40, total: 80, percent: 50 };
    render(<Ds4Settings ai={{ provider: "ds4", api_key: null, endpoint: null, model: null, local_model_path: null } as any} updateAi={vi.fn()} />);
    fireEvent.click(screen.getByRole("button", { name: "Cancel download" }));
    expect(screen.getByRole("button", { name: "Resume download" })).toBeInTheDocument();
    state.models = [];
    state.progress = null;
  });
});
