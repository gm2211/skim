import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { CatchupSection, catchupScopeSummary, catchupSelection } from "./CatchupSection";
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
  useUiStore.setState({ isPhone: false, showSettings: false, selectedArticleId: null, sidebarView: { type: "today" }, todayMode: "catchup" });
  // The dialog remembers the reader's last choice across opens; put it back so
  // one test's selection does not leak into the next.
  catchupSelection.scope = "unread";
  catchupSelection.sinceHours = null;
  vi.mocked(generateCatchupReport).mockResolvedValue(report);
});

describe("CatchupSection", () => {
  it("offers AI setup before a request when no provider is configured", async () => {
    provider = "none";
    settings = { ai: { provider } };
    render(<CatchupSection />);

    expect(screen.queryByRole("button", { name: "Run catch-up" })).not.toBeInTheDocument();
    expect(screen.queryByTestId("model-picker")).not.toBeInTheDocument();
    expect(screen.queryByText("Model", { exact: true })).not.toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("button", { name: "Open AI settings" }));

    expect(useUiStore.getState().showSettings).toBe(true);
    expect(generateCatchupReport).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("turns backend configuration errors into a settings action", async () => {
    vi.mocked(generateCatchupReport).mockRejectedValueOnce(new Error("No AI provider configured"));
    render(<CatchupSection />);

    await userEvent.setup().click(screen.getByRole("button", { name: "Run catch-up" }));

    expect(await screen.findByRole("button", { name: "Open AI settings" })).toBeInTheDocument();
    expect(screen.getByText("No AI provider configured")).toBeInTheDocument();
  });

  it("shows generic failures with an explicit retry", async () => {
    vi.mocked(generateCatchupReport).mockRejectedValueOnce(new Error("Network unavailable"));
    render(<CatchupSection />);

    await userEvent.setup().click(screen.getByRole("button", { name: "Run catch-up" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Network unavailable");
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });

  it("runs only on explicit action and never on a scope change", async () => {
    render(<CatchupSection />);

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
    render(<CatchupSection />);
    const user = userEvent.setup();

    await user.selectOptions(screen.getByLabelText("Include"), "inbox");
    await user.selectOptions(screen.getByLabelText("Going back"), "24");
    await user.click(screen.getByRole("button", { name: "Run catch-up" }));

    await waitFor(() =>
      expect(generateCatchupReport).toHaveBeenCalledWith("inbox", 24, expect.any(String)),
    );
  });

  it("can read every article in the window, read or not", async () => {
    render(<CatchupSection />);
    const user = userEvent.setup();

    await user.selectOptions(screen.getByLabelText("Include"), "all");
    await user.selectOptions(screen.getByLabelText("Going back"), "72");
    await user.click(screen.getByRole("button", { name: "Run catch-up" }));

    await waitFor(() =>
      expect(generateCatchupReport).toHaveBeenCalledWith("all", 72, expect.any(String)),
    );
  });

  it("keeps the reader's scope and range when the dialog is reopened", async () => {
    const first = render(<CatchupSection />);
    const user = userEvent.setup();
    await user.selectOptions(screen.getByLabelText("Include"), "inbox");
    await user.selectOptions(screen.getByLabelText("Going back"), "72");
    first.unmount();

    render(<CatchupSection />);
    expect(screen.getByLabelText("Include")).toHaveValue("inbox");
    expect(screen.getByLabelText("Going back")).toHaveValue("72");
  });

  it("names how many articles the run actually read", async () => {
    render(<CatchupSection />);

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
    render(<CatchupSection />);
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
      expect(catchupScopeSummary("all", 72, 12)).toBe(
        "Read 12 articles from every article from the last 3 days.",
      );
    });
  });

  it("is a section of the Today page, not a dialog or a page of its own", () => {
    render(<CatchupSection />);

    const section = screen.getByRole("region", { name: "Catch me up" });
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Close" })).not.toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Quick Catch-up" })).not.toBeInTheDocument();
    expect(within(section).getByLabelText("Include")).toBeInTheDocument();
    expect(within(section).getByLabelText("Going back")).toBeInTheDocument();
  });

  it("prints a story as a headline, a lede and the articles behind it", async () => {
    render(<CatchupSection />);

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
    render(<CatchupSection />);
    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    expect(await screen.findByText("theverge.com · Lobsters · Hacker News")).toBeInTheDocument();
    // A lead without a picture lists its coverage by title where the picture would go.
    const coverage = screen.getByRole("complementary", { name: "Coverage" });
    expect(within(coverage).getAllByRole("button")).toHaveLength(3);
    expect(within(coverage).getByTitle("verl 1.0 released")).toBeInTheDocument();
    expect(within(coverage).getByTitle("verl 1.0: RL for LLMs at scale")).toBeInTheDocument();
    expect(within(coverage).getByText("Hacker News")).toBeInTheDocument();
  });

  it("names the publication rather than the feed's own format title", async () => {
    render(<CatchupSection />);

    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    // The story and the brief both cite this article, so it prints twice.
    expect(await screen.findAllByText("theverge.com")).toHaveLength(2);
    expect(screen.queryByText("RSS 2.0")).not.toBeInTheDocument();
    expect(screen.getAllByTitle("verl hits 1.0 with multi-node rollouts").length).toBeGreaterThan(0);
  });

  it("prints each story as soon as it is written, with its picture and source icons", async () => {
    vi.mocked(generateCatchupReport).mockReturnValueOnce(new Promise<CatchupReport>(() => {}));
    render(<CatchupSection />);
    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));
    const runId = vi.mocked(generateCatchupReport).mock.calls[0][2] as string;

    const second = { headline: "Grafana ships a self-hosted analytics bundle", lede: "", article_ids: ["a2"] };
    const page: CatchupReport = {
      ...report,
      stories: [
        { ...report.stories[0], lede: "", image_url: "https://img.example.com/verl.jpg" },
        second,
      ],
      briefs: [],
      sources: [
        { ...source, icon_url: "https://icons.example.com/verge.png" },
        { ...source, id: "a2", title: "Grafana bundle", publication: "Lobsters" },
      ],
    };
    emitProgress({ stage: "picking", completed: 0, total: 2, message: "Writing the lead story…", report: page, run_id: runId });

    expect(screen.getByText("ByteDance open-sources its RL training stack")).toBeInTheDocument();
    expect(screen.queryByText(second.headline)).not.toBeInTheDocument();
    expect(screen.getByText("1 more story on the way")).toBeInTheDocument();
    expect(document.querySelector('img[src="https://img.example.com/verl.jpg"]')).not.toBeNull();
    expect(document.querySelector('img[src="https://icons.example.com/verge.png"]')).not.toBeNull();

    const firstWritten: CatchupReport = {
      ...page,
      stories: [{ ...page.stories[0], lede: report.stories[0].lede }, second],
    };
    emitProgress({ stage: "writing", completed: 1, total: 2, message: "Writing story 2 of 2…", report: firstWritten, run_id: runId });

    expect(screen.getByText(/ByteDance released verl 1\.0/)).toBeInTheDocument();
    expect(screen.getByText(second.headline)).toBeInTheDocument();
    expect(screen.getByLabelText("Writing this story")).toBeInTheDocument();
    // A publication without an icon prints its initials instead.
    expect(screen.getByRole("button", { name: "Grafana bundle, Lobsters" })).toHaveTextContent("LO");
  });

  it("shows headlines as soon as they are picked and fills the ledes in after", async () => {
    let finish: (value: CatchupReport) => void = () => {};
    vi.mocked(generateCatchupReport).mockReturnValueOnce(
      new Promise<CatchupReport>((resolve) => {
        finish = resolve;
      }),
    );
    render(<CatchupSection />);
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

  it("leaves the model to Today's cog and tells the page while a run is in progress", async () => {
    let finish: (value: CatchupReport) => void = () => {};
    vi.mocked(generateCatchupReport).mockReturnValueOnce(
      new Promise<CatchupReport>((resolve) => {
        finish = resolve;
      }),
    );
    const onLoadingChange = vi.fn();
    render(<CatchupSection onLoadingChange={onLoadingChange} />);
    const user = userEvent.setup();

    expect(screen.queryByTestId("model-picker")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /settings/i })).not.toBeInTheDocument();
    expect(onLoadingChange).toHaveBeenLastCalledWith(false);

    await user.click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));
    expect(onLoadingChange).toHaveBeenLastCalledWith(true);

    await act(async () => {
      finish(report);
    });
    await waitFor(() => expect(onLoadingChange).toHaveBeenLastCalledWith(false));
  });

  it("says so plainly when nothing on the page was real news", async () => {
    vi.mocked(generateCatchupReport).mockResolvedValueOnce({ stories: [], briefs: [], sources: [], article_count: 4 });
    render(<CatchupSection />);

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
    render(<CatchupSection />);
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
    render(<CatchupSection />);
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
    render(<CatchupSection />);
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
    render(<CatchupSection />);
    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));

    await user.selectOptions(screen.getByLabelText("Going back"), "24");

    expect(cancelCatchupReport).toHaveBeenCalledTimes(1);
    expect(generateCatchupReport).toHaveBeenCalledTimes(1);
    expect(screen.getByRole("button", { name: "Run catch-up" })).toBeInTheDocument();
  });

  it("runs again with the new range and a fresh run id after a stop", async () => {
    vi.mocked(generateCatchupReport).mockReturnValueOnce(new Promise<CatchupReport>(() => {}));
    render(<CatchupSection />);
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
    const { unmount } = render(<CatchupSection />);
    await userEvent.setup().click(screen.getByRole("button", { name: /^Run (catch-up|again)$/ }));
    const runId = vi.mocked(generateCatchupReport).mock.calls[0][2] as string;

    unmount();

    expect(cancelCatchupReport).toHaveBeenCalledWith(runId);
  });

  it("does not cache a stopped run's partial page", async () => {
    vi.mocked(generateCatchupReport).mockReturnValueOnce(new Promise<CatchupReport>(() => {}));
    const first = render(<CatchupSection />);
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

    render(<CatchupSection />);
    expect(screen.getByLabelText("Include")).toHaveValue("inbox");
    expect(screen.getByLabelText("Going back")).toHaveValue("6");
    expect(
      screen.queryByText("ByteDance open-sources its RL training stack"),
    ).not.toBeInTheDocument();
    expect(screen.getByText("Your front page is blank.")).toBeInTheDocument();
  });
});
