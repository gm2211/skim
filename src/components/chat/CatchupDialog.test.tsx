import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { CatchupDialog } from "./CatchupDialog";
import { useUiStore } from "../../stores/uiStore";
import { generateCatchupReport, type CatchupProgress, type CatchupReport } from "../../services/commands";

let provider = "openai";
let settings = { ai: { provider } };

vi.mock("../../hooks/useSettings", () => ({
  useSettings: () => ({ data: settings }),
}));

vi.mock("../../services/commands", () => ({
  generateCatchupReport: vi.fn(),
  CATCHUP_PROGRESS_EVENT: "catchup_progress",
}));

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

// Capture the progress listener so tests can push the page in mid-run, the way
// the backend does between its two passes.
const progressListeners = new Set<(event: { payload: CatchupProgress }) => void>();
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (_event: string, handler: (event: { payload: CatchupProgress }) => void) => {
    progressListeners.add(handler);
    return () => progressListeners.delete(handler);
  }),
}));

const emitProgress = (payload: CatchupProgress) =>
  act(() => {
    progressListeners.forEach((handler) => handler({ payload }));
  });

const source = {
  id: "a1",
  title: "verl hits 1.0 with multi-node rollouts",
  publication: "theverge.com",
  url: "https://example.com/verl",
  published_at: null,
};

const report: CatchupReport = {
  stories: [
    {
      headline: "ByteDance open-sources its RL training stack",
      lede: "ByteDance released verl 1.0 under Apache 2.0. It is the first public stack to train 70B models across nodes.",
      article_ids: ["a1"],
    },
  ],
  briefs: [{ text: "Grafana ships a self-hosted analytics bundle.", article_ids: ["a1"] }],
  sources: [source],
};

beforeEach(() => {
  vi.clearAllMocks();
  progressListeners.clear();
  provider = "openai";
  settings = { ai: { provider } };
  useUiStore.setState({ isPhone: false, showSettings: false });
  vi.mocked(generateCatchupReport).mockResolvedValue(report);
});

describe("CatchupDialog", () => {
  it("offers AI setup before a request when no provider is configured", async () => {
    provider = "none";
    settings = { ai: { provider } };
    render(<CatchupDialog onClose={vi.fn()} />);

    expect(screen.getByRole("button", { name: "Run catch-up" })).toBeDisabled();
    await userEvent.setup().click(screen.getByRole("button", { name: "Open AI settings" }));

    expect(useUiStore.getState().showSettings).toBe(true);
    expect(generateCatchupReport).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("turns backend configuration errors into a settings action", async () => {
    vi.mocked(generateCatchupReport).mockRejectedValueOnce(new Error("No AI provider configured"));
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: "Run catch-up" }));

    expect(await screen.findByRole("button", { name: "Open AI settings" })).toBeInTheDocument();
    expect(screen.getByText("No AI provider configured")).toBeInTheDocument();
  });

  it("shows generic failures with an explicit retry", async () => {
    vi.mocked(generateCatchupReport).mockRejectedValueOnce(new Error("Network unavailable"));
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: "Run catch-up" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Network unavailable");
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });

  it("runs only on explicit action and never on a scope change", async () => {
    render(<CatchupDialog onClose={vi.fn()} />);

    expect(generateCatchupReport).not.toHaveBeenCalled();
    await userEvent.setup().click(screen.getByRole("button", { name: "Run catch-up" }));
    await waitFor(() => expect(generateCatchupReport).toHaveBeenCalledWith("unread"));

    await userEvent.setup().selectOptions(screen.getByLabelText("Include"), "inbox");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run catch-up" })).toBeInTheDocument());
    expect(generateCatchupReport).toHaveBeenCalledTimes(1);
  });

  it("closes with Escape and exposes modal semantics", () => {
    const onClose = vi.fn();
    render(<CatchupDialog onClose={onClose} />);

    const dialog = screen.getByRole("dialog", { name: "Quick Catch-up" });
    expect(dialog).toHaveAttribute("aria-modal", "true");
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onClose).toHaveBeenCalledOnce();
  });

  it("prints a story as a headline, a lede and the articles behind it", async () => {
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    expect(
      await screen.findByText("ByteDance open-sources its RL training stack"),
    ).toBeInTheDocument();
    expect(screen.getByText(/ByteDance released verl 1\.0/)).toBeInTheDocument();
    expect(screen.getByText("Also")).toBeInTheDocument();
    expect(screen.getByText("Grafana ships a self-hosted analytics bundle.")).toBeInTheDocument();
  });

  it("names the publication rather than the feed's own format title", async () => {
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    // The story and the brief both cite this article, so it prints twice.
    expect(await screen.findAllByText("theverge.com")).toHaveLength(2);
    expect(screen.queryByText("RSS 2.0")).not.toBeInTheDocument();
    expect(screen.getAllByTitle("verl hits 1.0 with multi-node rollouts").length).toBeGreaterThan(0);
  });

  it("shows headlines as soon as they are picked and fills the ledes in after", async () => {
    let finish: (value: CatchupReport) => void = () => {};
    vi.mocked(generateCatchupReport).mockReturnValueOnce(
      new Promise<CatchupReport>((resolve) => {
        finish = resolve;
      }),
    );
    render(<CatchupDialog onClose={vi.fn()} />);
    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    const headlineOnly: CatchupReport = {
      ...report,
      stories: [{ ...report.stories[0], lede: "" }],
      briefs: [],
    };
    emitProgress({
      stage: "picking",
      completed: 0,
      total: 1,
      message: "Writing the lead story…",
      report: headlineOnly,
    });

    expect(screen.getByText("ByteDance open-sources its RL training stack")).toBeInTheDocument();
    expect(screen.getByLabelText("Writing this story")).toBeInTheDocument();
    expect(screen.queryByText(/ByteDance released verl 1\.0/)).not.toBeInTheDocument();

    emitProgress({
      stage: "writing",
      completed: 1,
      total: 1,
      message: "Writing story 1 of 1…",
      report,
    });

    expect(screen.getByText(/ByteDance released verl 1\.0/)).toBeInTheDocument();
    expect(screen.queryByLabelText("Writing this story")).not.toBeInTheDocument();

    await act(async () => {
      finish(report);
    });
  });

  it("says so plainly when nothing on the page was real news", async () => {
    vi.mocked(generateCatchupReport).mockResolvedValueOnce({ stories: [], briefs: [], sources: [] });
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    expect(
      await screen.findByText(/there was no real news in these articles/),
    ).toBeInTheDocument();
  });
});
