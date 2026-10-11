import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { ChatMessageContent } from "./ChatMessageContent";
import { selectChatText } from "../../test/selectChatText";
import { openUrl } from "@tauri-apps/plugin-opener";

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn().mockResolvedValue(undefined) }));

describe("ChatMessageContent", () => {
  it("renders Markdown blocks, GFM tables, nested formatting, and opens links externally", async () => {
    const { container } = render(<ChatMessageContent role="assistant" onReply={vi.fn()} content={'## Summary\n\n- **Strong** and *emphasis*\n- `inline`\n\n1. Ordered\n\n> Quoted\n\n```js\nconst x = 1;\n```\n\n| Name | Value |\n| --- | --- |\n| item | 2 |\n\n~~Old~~ [Source](https://example.com) [1]'} />);
    expect(screen.getByRole("heading", { name: "Summary", level: 2 })).toBeInTheDocument();
    expect(container.querySelector("ul strong")).toHaveTextContent("Strong");
    expect(container.querySelector("ol li")).toHaveTextContent("Ordered");
    expect(container.querySelector("blockquote")).toHaveTextContent("Quoted");
    expect(container.querySelector("pre code")).toHaveTextContent("const x = 1;");
    expect(screen.getByRole("table")).toHaveTextContent("item");
    expect(container.querySelector("del")).toHaveTextContent("Old");
    expect(container).toHaveTextContent("[1]");
    await userEvent.click(screen.getByRole("link", { name: "Source" }));
    expect(openUrl).toHaveBeenCalledWith("https://example.com");
  });

  it("does not execute HTML or render unsafe link protocols", () => {
    const { container } = render(<ChatMessageContent role="assistant" onReply={vi.fn()} content={'<script>alert(1)</script>\n\n[Bad](javascript:alert%281%29)\n\n![image](https://example.com/tracking.png)'} />);
    expect(container.querySelector("script, img")).toBeNull();
    expect(screen.queryByRole("link")).not.toBeInTheDocument();
  });

  it("replies with selected rendered text spanning formatting and ignores outside selections", async () => {
    const onReply = vi.fn();
    const { container } = render(<div><span>Outside</span><ChatMessageContent role="assistant" onReply={onReply} content="Before **selected** after" /></div>);
    const paragraph = container.querySelector(".chat-markdown p")!;
    selectChatText(paragraph.firstChild!, 3, 6, paragraph.lastChild!);
    await userEvent.click(screen.getByRole("button", { name: "Reply to selection" }));
    expect(onReply).toHaveBeenCalledWith({ role: "assistant", text: "ore selected after" });
    selectChatText(screen.getByText("Outside").firstChild!);
    expect(screen.queryByRole("button", { name: "Reply to selection" })).not.toBeInTheDocument();
    selectChatText(paragraph.firstChild!, 0, 3, screen.getByText("Outside").firstChild!);
    expect(screen.queryByRole("button", { name: "Reply to selection" })).not.toBeInTheDocument();
  });

  it("accepts WebKit endpoints on the message wrapper without losing block text", async () => {
    const onReply = vi.fn();
    const { container } = render(<ChatMessageContent role="assistant" onReply={onReply} content={'## Heading\n\nFirst paragraph\n\nSecond paragraph'} />);
    const wrapper = container.querySelector(".chat-message-content")!;
    selectChatText(wrapper, 0, 1);
    await userEvent.click(screen.getByRole("button", { name: "Reply to selection" }));
    expect(onReply).toHaveBeenCalledWith(expect.objectContaining({ text: expect.stringContaining("Second paragraph") }));
  });
});
