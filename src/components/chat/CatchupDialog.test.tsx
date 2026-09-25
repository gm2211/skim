import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { CatchupDialog, catchupScopeSummary, catchupSelection } from "./CatchupDialog";
import { useUiStore } from "../../stores/uiStore";
import {
  cancelCatchupReport,
  generateCatchupReport,
  CATCHUP_CANCELLED,
  type CatchupProgress,
  type CatchupReport,
} from "../../services/commands";

let provider = "openai";
let settings = { ai: { provider } };

vi.mock("../../hooks/useSettings", () => ({
  useSettings: () => ({ data: settings }),
}));

vi.mock("../../services/commands", () => ({
  generateCatchupReport: vi.fn(),
  cancelCatchupReport: vi.fn(),
  CATCHUP_PROGRESS_EVENT: "catchup_progress",
  CATCHUP_CANCELLED: "Catch-up cancelled",
}));

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

vi.mock("../common/ModelPicker", () => ({
  ModelPicker: (p: { surface: string; disabled?: boolean }) => (
    <div data-testid="model-picker" data-surface={p.surface} data-disabled={String(!!p.disabled)} />
  ),
}));

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
  article_count: 12,
};

beforeEach(() => {
  vi.clearAllMocks();
  progressListeners.clear();
  provider = "openai";
  settings = { ai: { provider } };
  useUiStore.setState({ isPhone: false, showSettings: false });
  // The dialog remembers the reader's last choice across opens; put it back so
  // one test's selection does not leak into the next.
  catchupSelection.scope = "unread";
  catchupSelection.sinceHours = null;
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
    await waitFor(() =>
      expect(generateCatchupReport).toHaveBeenCalledWith("unread", null, expect.any(String)),
    );

    await userEvent.setup().selectOptions(screen.getByLabelText("Include"), "inbox");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run catch-up" })).toBeInTheDocument());
    expect(generateCatchupReport).toHaveBeenCalledTimes(1);
  });

  it("sends the chosen scope and time range to the backend", async () => {
    render(<CatchupDialog onClose={vi.fn()} />);
    const user = userEvent.setup();

    await user.selectOptions(screen.getByLabelText("Include"), "inbox");
    await user.selectOptions(screen.getByLabelText("Going back"), "24");
    await user.click(screen.getByRole("button", { name: "Run catch-up" }));

    await waitFor(() =>
      expect(generateCatchupReport).toHaveBeenCalledWith("inbox", 24, expect.any(String)),
    );
  });

  it("keeps the reader's scope and range when the dialog is reopened", async () => {
    const first = render(<CatchupDialog onClose={vi.fn()} />);
    const user = userEvent.setup();
    await user.selectOptions(screen.getByLabelText("Include"), "inbox");
    await user.selectOptions(screen.getByLabelText("Going back"), "72");
    first.unmount();

    render(<CatchupDialog onClose={vi.fn()} />);
    expect(screen.getByLabelText("Include")).toHaveValue("inbox");
    expect(screen.getByLabelText("Going back")).toHaveValue("72");
  });

  it("names how many articles the run actually read", async () => {
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    expect(
      await screen.findByText("Read 12 articles from everything unread."),
    ).toBeInTheDocument();
  });

  it("explains an empty priority inbox rather than blaming the news", async () => {
    vi.mocked(generateCatchupReport).mockResolvedValueOnce({
      stories: [],
      briefs: [],
      sources: [],
      article_count: 0,
    });
    render(<CatchupDialog onClose={vi.fn()} />);
    const user = userEvent.setup();

    await user.selectOptions(screen.getByLabelText("Include"), "inbox");
    await user.click(screen.getByRole("button", { name: "Run catch-up" }));

    expect(await screen.findByText(/only 4s and 5s reach this scope/)).toBeInTheDocument();
  });

  describe("catchupScopeSummary", () => {
    it("names the scope and the window", () => {
      expect(catchupScopeSummary("inbox", 24, 7)).toBe(
        "Read 7 articles from your priority inbox from the last 24 hours.",
      );
      expect(catchupScopeSummary("unread", null, 1)).toBe(
        "Read 1 article from everything unread.",
      );
    });
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

  it("cites every article a story gathers, numbered, with the outlets over the headline", async () => {
    const lobsters = { ...source, id: "a2", publication: "Lobsters", title: "verl 1.0 released" };
    const hn = { ...source, id: "a3", publication: "Hacker News", title: "verl 1.0: RL for LLMs at scale" };
    vi.mocked(generateCatchupReport).mockResolvedValueOnce({
      ...report,
      stories: [{ ...report.stories[0], article_ids: ["a1", "a2", "a3"] }],
      briefs: [],
      sources: [source, lobsters, hn],
    });
    render(<CatchupDialog onClose={vi.fn()} />);
    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    expect(await screen.findByText("3 sources")).toBeInTheDocument();
    expect(screen.getByText("theverge.com · Lobsters · Hacker News")).toBeInTheDocument();
    expect(screen.getByTitle("verl 1.0 released")).toBeInTheDocument();
    expect(screen.getByTitle("verl 1.0: RL for LLMs at scale")).toBeInTheDocument();
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
    const runId = vi.mocked(generateCatchupReport).mock.calls[0][2] as string;

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
      run_id: runId,
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
      run_id: runId,
    });

    expect(screen.getByText(/ByteDance released verl 1\.0/)).toBeInTheDocument();
    expect(screen.queryByLabelText("Writing this story")).not.toBeInTheDocument();

    await act(async () => {
      finish(report);
    });
  });

  it("mounts the model picker for this surface, disabled while a run is in progress", async () => {
    let finish: (value: CatchupReport) => void = () => {};
    vi.mocked(generateCatchupReport).mockReturnValueOnce(
      new Promise<CatchupReport>((resolve) => {
        finish = resolve;
      }),
    );
    render(<CatchupDialog onClose={vi.fn()} />);

    const picker = screen.getByTestId("model-picker");
    expect(picker).toHaveAttribute("data-surface", "catchup");
    expect(picker).toHaveAttribute("data-disabled", "false");

    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));
    expect(screen.getByTestId("model-picker")).toHaveAttribute("data-disabled", "true");

    await act(async () => {
      finish(report);
    });
  });

  it("says so plainly when nothing on the page was real news", async () => {
    vi.mocked(generateCatchupReport).mockResolvedValueOnce({ stories: [], briefs: [], sources: [], article_count: 4 });
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    expect(
      await screen.findByText(/there was no real news in these articles/),
    ).toBeInTheDocument();
  });

  it("keeps both selects enabled and offers a Stop button while a run is in progress", async () => {
    let finish: (value: CatchupReport) => void = () => {};
    vi.mocked(generateCatchupReport).mockReturnValueOnce(
      new Promise<CatchupReport>((resolve) => {
        finish = resolve;
      }),
    );
    render(<CatchupDialog onClose={vi.fn()} />);
    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    expect(await screen.findByRole("button", { name: "Stop catch-up" })).toBeInTheDocument();
    expect(screen.getByLabelText("Include")).toBeEnabled();
    expect(screen.getByLabelText("Going back")).toBeEnabled();

    await act(async () => {
      finish(report);
    });
  });

  it("stops the run in place, keeps the partial page and swallows a late cancellation rejection", async () => {
    let reject: (reason: unknown) => void = () => {};
    vi.mocked(generateCatchupReport).mockReturnValueOnce(
      new Promise<CatchupReport>((_resolve, rej) => {
        reject = rej;
      }),
    );
    render(<CatchupDialog onClose={vi.fn()} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));
    const runId = vi.mocked(generateCatchupReport).mock.calls[0][2] as string;

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
      run_id: runId,
    });

    await user.click(screen.getByRole("button", { name: "Stop catch-up" }));

    expect(cancelCatchupReport).toHaveBeenCalledWith(runId);
    expect(screen.getByText("Stopped. Run again to finish the page.")).toBeInTheDocument();
    expect(screen.getByText("ByteDance open-sources its RL training stack")).toBeInTheDocument();
    expect(screen.queryByLabelText("Writing this story")).not.toBeInTheDocument();

    await act(async () => {
      reject(new Error(CATCHUP_CANCELLED));
    });

    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
    expect(screen.getByText("Stopped. Run again to finish the page.")).toBeInTheDocument();
  });

  it("ignores catch-up progress that belongs to a run that is no longer current", async () => {
    vi.mocked(generateCatchupReport).mockReturnValueOnce(new Promise<CatchupReport>(() => {}));
    render(<CatchupDialog onClose={vi.fn()} />);
    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    emitProgress({
      stage: "picking",
      completed: 0,
      total: 1,
      message: "Writing the lead story…",
      report,
      run_id: "a-run-this-dialog-never-started",
    });

    expect(
      screen.queryByText("ByteDance open-sources its RL training stack"),
    ).not.toBeInTheDocument();
  });

  it("changing the range mid-run stops the run instead of starting a new one", async () => {
    vi.mocked(generateCatchupReport).mockReturnValueOnce(new Promise<CatchupReport>(() => {}));
    render(<CatchupDialog onClose={vi.fn()} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    await user.selectOptions(screen.getByLabelText("Going back"), "24");

    expect(cancelCatchupReport).toHaveBeenCalledTimes(1);
    expect(generateCatchupReport).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Run catch-up" })).toBeInTheDocument();
  });

  it("runs again with the new range and a fresh run id after a stop", async () => {
    vi.mocked(generateCatchupReport).mockReturnValueOnce(new Promise<CatchupReport>(() => {}));
    render(<CatchupDialog onClose={vi.fn()} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));
    const firstRunId = vi.mocked(generateCatchupReport).mock.calls[0][2] as string;

    await user.click(screen.getByRole("button", { name: "Stop catch-up" }));
    await user.selectOptions(screen.getByLabelText("Going back"), "168");
    await user.click(screen.getByRole("button", { name: "Run catch-up" }));

    expect(generateCatchupReport).toHaveBeenCalledTimes(2);
    const secondCall = vi.mocked(generateCatchupReport).mock.calls[1];
    expect(secondCall[0]).toBe("unread");
    expect(secondCall[1]).toBe(168);
    expect(secondCall[2]).not.toBe(firstRunId);

    await screen.findByText("ByteDance open-sources its RL training stack");
  });

  it("cancels the in-flight run when the dialog unmounts", async () => {
    vi.mocked(generateCatchupReport).mockReturnValueOnce(new Promise<CatchupReport>(() => {}));
    const { unmount } = render(<CatchupDialog onClose={vi.fn()} />);
    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));
    const runId = vi.mocked(generateCatchupReport).mock.calls[0][2] as string;

    unmount();

    expect(cancelCatchupReport).toHaveBeenCalledWith(runId);
  });

  it("does not cache a stopped run's partial page", async () => {
    vi.mocked(generateCatchupReport).mockReturnValueOnce(new Promise<CatchupReport>(() => {}));
    const first = render(<CatchupDialog onClose={vi.fn()} />);
    const user = userEvent.setup();
    await user.selectOptions(screen.getByLabelText("Include"), "inbox");
    await user.selectOptions(screen.getByLabelText("Going back"), "6");
    await user.click(screen.getByRole("button", { name: "Run catch-up" }));
    const runId = vi.mocked(generateCatchupReport).mock.calls[0][2] as string;

    emitProgress({
      stage: "picking",
      completed: 0,
      total: 1,
      message: "Writing the lead story…",
      report,
      run_id: runId,
    });
    expect(screen.getByText("ByteDance open-sources its RL training stack")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Stop catch-up" }));
    first.unmount();

    render(<CatchupDialog onClose={vi.fn()} />);
    expect(screen.getByLabelText("Include")).toHaveValue("inbox");
    expect(screen.getByLabelText("Going back")).toHaveValue("6");
    expect(
      screen.queryByText("ByteDance open-sources its RL training stack"),
    ).not.toBeInTheDocument();
    expect(screen.getByText("Ready when you are")).toBeInTheDocument();
  });
});
