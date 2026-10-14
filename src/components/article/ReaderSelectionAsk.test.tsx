import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useRef } from "react";
import { describe, expect, it, vi } from "vitest";
import { ReaderSelectionAsk } from "./ReaderSelectionAsk";
import { selectChatText } from "../../test/selectChatText";

function Reader({ onAsk }: { onAsk: (text: string) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  return (
    <>
      <p>Outside the article</p>
      <div ref={ref} style={{ position: "relative" }}>
        <p>Sanders slammed the response to developing AI.</p>
        <ReaderSelectionAsk containerRef={ref} onAsk={onAsk} />
      </div>
    </>
  );
}

describe("ReaderSelectionAsk", () => {
  it("offers Ask in chat for a passage selected in the article", async () => {
    const onAsk = vi.fn();
    render(<Reader onAsk={onAsk} />);
    expect(screen.queryByRole("button", { name: "Ask in chat" })).not.toBeInTheDocument();
    selectChatText(screen.getByText("Sanders slammed the response to developing AI.").firstChild!, 8, 15);
    await userEvent.setup().click(screen.getByRole("button", { name: "Ask in chat" }));
    expect(onAsk).toHaveBeenCalledWith("slammed");
    expect(screen.queryByRole("button", { name: "Ask in chat" })).not.toBeInTheDocument();
  });

  it("ignores selections outside the article", () => {
    render(<Reader onAsk={vi.fn()} />);
    selectChatText(screen.getByText("Outside the article").firstChild!);
    expect(screen.queryByRole("button", { name: "Ask in chat" })).not.toBeInTheDocument();
  });
});
