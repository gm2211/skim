import { describe, expect, it, vi } from "vitest";

const openUrl = vi.fn((_url: string) => Promise.resolve());
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: (url: string) => openUrl(url) }));

import { openArticleLink, resolveArticleLink } from "./externalLinks";

describe("resolveArticleLink", () => {
  it("keeps absolute web links", () => {
    expect(resolveArticleLink("https://dynamicland.org/", "https://blog.example/post")).toBe("https://dynamicland.org/");
  });

  it("resolves relative links against the article, not the app", () => {
    expect(resolveArticleLink("/about", "https://blog.example/2026/post")).toBe("https://blog.example/about");
    expect(resolveArticleLink("next.html", "https://blog.example/2026/post")).toBe("https://blog.example/2026/next.html");
  });

  it("leaves in-page anchors and script links alone", () => {
    expect(resolveArticleLink("#fn1", "https://blog.example/post")).toBeNull();
    expect(resolveArticleLink("javascript:alert(1)", "https://blog.example/post")).toBeNull();
    expect(resolveArticleLink("", "https://blog.example/post")).toBeNull();
  });

  it("keeps mailto links", () => {
    expect(resolveArticleLink("mailto:a@b.c", null)).toBe("mailto:a@b.c");
  });
});

describe("openArticleLink", () => {
  it("opens a clicked article link in the browser and stops the window navigating", () => {
    const root = document.createElement("div");
    root.innerHTML = `<p><a href="https://dynamicland.org/"><span>Dynamicland</span></a></p>`;
    document.body.appendChild(root);
    let prevented = false;
    root.addEventListener("click", (e) => {
      openArticleLink(e, "https://blog.example/post");
      prevented = e.defaultPrevented;
    });
    root.querySelector("span")!.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    expect(prevented).toBe(true);
    expect(openUrl).toHaveBeenCalledWith("https://dynamicland.org/");
    root.remove();
  });
});
