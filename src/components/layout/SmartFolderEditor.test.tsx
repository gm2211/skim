import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SmartFolderEditor } from "./SmartFolderEditor";
import * as commands from "../../services/commands";
import type { Feed, Folder } from "../../services/types";

vi.mock("../../services/commands", () => ({
  previewSmartFolder: vi.fn(),
}));

const feeds: Feed[] = [
  { id: "ai", title: "AI Weekly", url: "https://ai.example.com/feed", site_url: null, description: null, icon_url: null, feedly_id: null, created_at: 0, updated_at: 0, last_fetched_at: null, folder_id: null, opml_category: "Technology", unread_count: 2 },
  { id: "news", title: "World News", url: "https://news.example.com/feed", site_url: null, description: null, icon_url: null, feedly_id: null, created_at: 0, updated_at: 0, last_fetched_at: null, folder_id: null, opml_category: "News", unread_count: 1 },
];

const folder: Folder = {
  id: "folder-1",
  name: "Technology",
  sort_order: 0,
  is_smart: true,
  rules_json: JSON.stringify({ mode: "any", rules: [{ type: "opml_category", value: "Technology" }] }),
  created_at: 0,
  feed_count: 1,
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(commands.previewSmartFolder).mockResolvedValue(["ai"]);
});

describe("SmartFolderEditor", () => {
  it("creates a dynamic folder with typed rules and previews matches", async () => {
    const user = userEvent.setup();
    const onCreate = vi.fn().mockResolvedValue(undefined);
    render(<SmartFolderEditor feeds={feeds} mode="create" onCancel={vi.fn()} onCreate={onCreate} onUpdate={vi.fn()} />);

    await user.type(screen.getByLabelText("Folder name"), "AI sources");
    await user.selectOptions(screen.getByLabelText("Rule 1 type"), "regex_url");
    await user.type(screen.getByLabelText("Rule 1 value"), "ai\\.example");
    await user.click(screen.getByRole("button", { name: "Create smart folder" }));

    expect(onCreate).toHaveBeenCalledWith("AI sources", {
      mode: "any",
      rules: [{ type: "regex_url", pattern: "ai\\.example" }],
    });
    expect(await screen.findByText(/1 matching feed/)).toBeInTheDocument();
    expect(commands.previewSmartFolder).toHaveBeenCalled();
  });

  it("edits existing rules and preserves all mode", async () => {
    const user = userEvent.setup();
    const onUpdate = vi.fn().mockResolvedValue(undefined);
    render(<SmartFolderEditor feeds={feeds} folder={folder} mode="edit" onCancel={vi.fn()} onCreate={vi.fn()} onUpdate={onUpdate} />);

    await user.selectOptions(screen.getByLabelText("Rule matching mode"), "all");
    await user.click(screen.getByRole("button", { name: "Save rules" }));

    expect(onUpdate).toHaveBeenCalledWith("folder-1", {
      mode: "all",
      rules: [{ type: "opml_category", value: "Technology" }],
    });
  });

  it("hands regular to smart conversion to the parent workflow", async () => {
    const user = userEvent.setup();
    const onConvert = vi.fn().mockResolvedValue(undefined);
    const regularFolder = { ...folder, is_smart: false, rules_json: null, name: "Old folder" };
    render(<SmartFolderEditor feeds={feeds} folder={regularFolder} mode="convert" onCancel={vi.fn()} onCreate={vi.fn()} onUpdate={vi.fn()} onConvert={onConvert} />);

    await user.type(screen.getByLabelText("Rule 1 value"), "AI");
    await user.click(screen.getByRole("button", { name: "Create smart folder" }));

    expect(onConvert).toHaveBeenCalledWith(regularFolder, expect.objectContaining({ mode: "any" }), "Old folder");
  });
});
