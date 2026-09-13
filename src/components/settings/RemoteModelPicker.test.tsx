import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
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

function renderPicker(value = "", provider = "openai", onChange = vi.fn()) {
  return render(
    <RemoteModelPicker
      provider={provider}
      apiKey="key"
      endpoint={null}
      value={value}
      onChange={onChange}
    />,
  );
}

beforeEach(() => vi.mocked(listRemoteModels).mockReset());
afterEach(() => vi.restoreAllMocks());

describe("RemoteModelPicker", () => {
  it("ignores a response from an older provider request", async () => {
    const first = deferred<{ id: string; display_name: string }[]>();
    const second = deferred<{ id: string; display_name: string }[]>();
    vi.mocked(listRemoteModels)
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    const view = renderPicker("manual", "openai");
    const user = userEvent.setup();

    await user.click(screen.getByRole("button", { name: "Load available models" }));
    view.rerender(
      <RemoteModelPicker provider="anthropic" apiKey="key" endpoint={null} value="manual" onChange={vi.fn()} />,
    );
    await user.click(screen.getByRole("button", { name: "Load available models" }));

    await act(async () => first.resolve([{ id: "old-model", display_name: "Old model" }]));
    expect(document.querySelector('option[value="old-model"]')).not.toBeInTheDocument();
    await act(async () => second.resolve([{ id: "new-model", display_name: "New model" }]));

    await waitFor(() => expect(document.querySelector('option[value="new-model"]')).toBeInTheDocument());
    expect(document.querySelector('option[value="old-model"]')).not.toBeInTheDocument();
  });

  it("keeps the saved or manually entered model value when suggestions load", async () => {
    vi.mocked(listRemoteModels).mockResolvedValue([{ id: "suggested", display_name: "Suggested" }]);
    const onChange = vi.fn();
    renderPicker("my-manual-model", "openai", onChange);

    await userEvent.setup().click(screen.getByRole("button", { name: "Load available models" }));
    await waitFor(() => expect(document.querySelector('option[value="suggested"]')).toBeInTheDocument());

    expect(screen.getByRole("combobox", { name: "Model" })).toHaveValue("my-manual-model");
    expect(onChange).not.toHaveBeenCalled();
  });

  it("shows a retryable fallback while preserving manual model entry after failure", async () => {
    vi.mocked(listRemoteModels).mockRejectedValue(new Error("Provider unavailable"));
    renderPicker("manual-model");

    await userEvent.setup().click(screen.getByRole("button", { name: "Load available models" }));

    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("Provider unavailable"));
    expect(screen.getByRole("combobox", { name: "Model" })).toHaveValue("manual-model");
    expect(screen.getByRole("button", { name: "Load available models" })).toBeEnabled();
  });
});
