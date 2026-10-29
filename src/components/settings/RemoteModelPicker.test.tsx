import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactElement } from "react";
import { RemoteModelPicker } from "./RemoteModelPicker";
import { listRemoteModels } from "../../services/commands";

vi.mock("../../services/commands", () => ({
  listRemoteModels: vi.fn(),
}));

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function withClient(ui: ReactElement, qc: QueryClient) {
  return <QueryClientProvider client={qc}>{ui}</QueryClientProvider>;
}

function renderPicker(value = "", provider = "openai", onChange = vi.fn(), apiKey: string | null = "key") {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const picker = (props: { provider: string; apiKey: string | null; value: string }) => withClient(
    <RemoteModelPicker provider={props.provider} apiKey={props.apiKey} endpoint={null} value={props.value} onChange={onChange} />, qc);
  const view = render(picker({ provider, apiKey, value }));
  return { ...view, qc, rerenderWith: (props: { provider: string; apiKey: string | null; value: string }) => view.rerender(picker(props)) };
}

const MODELS = [
  { id: "claude-haiku-5-5", display_name: "Claude Haiku 5.5" },
  { id: "claude-sonnet-5-5", display_name: "Claude Sonnet 5.5" },
  { id: "claude-opus-5-5", display_name: "Claude Opus 5.5" },
];

beforeEach(() => {
  vi.mocked(listRemoteModels).mockReset();
});

describe("RemoteModelPicker", () => {
  it("loads the model list on its own, with no refresh button to press", async () => {
    const request = deferred<{ id: string; display_name: string }[]>();
    vi.mocked(listRemoteModels).mockReturnValue(request.promise);
    renderPicker();

    expect(listRemoteModels).toHaveBeenCalledWith("openai", "key", null);
    expect(screen.queryByRole("button", { name: "Load available models" })).toBeNull();
    expect(screen.getByRole("status")).toHaveTextContent("Loading models…");
    await act(async () => request.resolve(MODELS));
    expect(await screen.findByText("3 models available. Pick one or type any model ID.")).toBeInTheDocument();
  });

  it("shows friendly names first with the id beneath, marks the current model, and picks on click", async () => {
    vi.mocked(listRemoteModels).mockResolvedValue(MODELS);
    const onChange = vi.fn();
    renderPicker("claude-sonnet-5-5", "anthropic", onChange);
    await screen.findByText(/Claude Sonnet 5.5 · 3 models available/);
    const user = userEvent.setup();

    await user.click(screen.getByRole("combobox", { name: "Model" }));
    const options = screen.getAllByRole("option");
    expect(options.map((option) => option.textContent)).toEqual([
      "Claude Haiku 5.5claude-haiku-5-5",
      "Claude Sonnet 5.5claude-sonnet-5-5",
      "Claude Opus 5.5claude-opus-5-5",
    ]);
    expect(screen.getByRole("option", { selected: true })).toHaveTextContent("Claude Sonnet 5.5");

    await user.click(screen.getByRole("option", { name: /Claude Opus 5.5/ }));
    expect(onChange).toHaveBeenCalledWith("claude-opus-5-5");
    expect(screen.queryByRole("listbox")).toBeNull();
  });

  it("filters while typing and chooses with the keyboard", async () => {
    vi.mocked(listRemoteModels).mockResolvedValue(MODELS);
    const onChange = vi.fn();
    const { rerenderWith } = renderPicker("", "anthropic", onChange);
    await screen.findByText(/3 models available/);
    const user = userEvent.setup();
    const combo = screen.getByRole("combobox", { name: "Model" });

    await user.click(combo);
    await user.keyboard("o");
    rerenderWith({ provider: "anthropic", apiKey: "key", value: "o" });
    expect(screen.getAllByRole("option")).toHaveLength(2);
    await user.keyboard("{ArrowDown}{Enter}");
    expect(onChange).toHaveBeenLastCalledWith("claude-opus-5-5");
  });

  it("refetches when the provider changes and ignores the older provider's list", async () => {
    const first = deferred<{ id: string; display_name: string }[]>();
    const second = deferred<{ id: string; display_name: string }[]>();
    vi.mocked(listRemoteModels)
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    const { rerenderWith } = renderPicker("manual", "openai");
    rerenderWith({ provider: "anthropic", apiKey: "key", value: "manual" });
    expect(listRemoteModels).toHaveBeenLastCalledWith("anthropic", "key", null);

    await act(async () => first.resolve([{ id: "old-model", display_name: "Old model" }]));
    await act(async () => second.resolve([{ id: "new-model", display_name: "New model" }]));
    await screen.findByText(/1 models available/);
    await userEvent.setup().click(screen.getByRole("combobox", { name: "Model" }));
    expect(screen.getByRole("option", { name: /New model/ })).toBeInTheDocument();
    expect(screen.queryByRole("option", { name: /Old model/ })).toBeNull();
  });

  it("refetches once a new key stops changing", async () => {
    vi.mocked(listRemoteModels).mockResolvedValue(MODELS);
    const { rerenderWith } = renderPicker("", "openai", vi.fn(), null);
    await waitFor(() => expect(listRemoteModels).toHaveBeenCalledWith("openai", null, null));
    rerenderWith({ provider: "openai", apiKey: "sk-1", value: "" });
    rerenderWith({ provider: "openai", apiKey: "sk-12", value: "" });
    await waitFor(() => expect(listRemoteModels).toHaveBeenLastCalledWith("openai", "sk-12", null));
    expect(listRemoteModels).not.toHaveBeenCalledWith("openai", "sk-1", null);
  });

  it("keeps the saved or manually entered model value when suggestions load", async () => {
    vi.mocked(listRemoteModels).mockResolvedValue([{ id: "suggested", display_name: "Suggested" }]);
    const onChange = vi.fn();
    renderPicker("my-manual-model", "openai", onChange);

    await screen.findByText(/1 models available/);
    expect(screen.getByRole("combobox", { name: "Model" })).toHaveValue("my-manual-model");
    expect(onChange).not.toHaveBeenCalled();
  });

  it("shows a retryable fallback while preserving manual model entry after failure", async () => {
    vi.mocked(listRemoteModels).mockRejectedValueOnce(new Error("Provider unavailable")).mockRejectedValueOnce(new Error("Provider unavailable")).mockResolvedValue(MODELS);
    renderPicker("manual-model");

    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("Provider unavailable"));
    expect(screen.getByRole("combobox", { name: "Model" })).toHaveValue("manual-model");
    await userEvent.setup().click(screen.getByRole("button", { name: "Try again" }));
    expect(await screen.findByText(/3 models available/)).toBeInTheDocument();
  });
});
