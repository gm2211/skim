import { fireEvent } from "@testing-library/react";

export function selectChatText(node: Node, start = 0, end = node.textContent?.length ?? 0, endNode = node) {
  const range = document.createRange();
  range.setStart(node, start);
  range.setEnd(endNode, end);
  range.getBoundingClientRect = () => ({ top: 80, left: 20, bottom: 100, right: 120, width: 100, height: 20, x: 20, y: 80, toJSON: () => ({}) });
  const selection = window.getSelection()!;
  selection.removeAllRanges();
  selection.addRange(range);
  fireEvent(document, new Event("selectionchange"));
}
