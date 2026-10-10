import { describe, expect, it } from "vitest";
import { displayDomain, parseAggregatorPost } from "./aggregatorPost";

const REDDIT_LINK_POST = `<table> <tr><td> <a href="https://www.reddit.com/r/technology/comments/1abc/rogue_ai_agent/"> <img src="https://external-preview.redd.it/thumb.jpg?width=640&amp;crop=smart" alt="Rogue AI agent" title="Rogue AI agent" /> </a> </td><td> &#32; submitted by &#32; <a href="https://www.reddit.com/user/plain_handle"> /u/plain_handle </a> <br/> <span><a href="https://www.bbc.com/news/articles/c1234">[link]</a></span> &#32; <span><a href="https://www.reddit.com/r/technology/comments/1abc/rogue_ai_agent/">[comments]</a></span> </td></tr></table>`;

const REDDIT_SELF_POST = `<!-- SC_OFF --><div class="md"><p>Has anyone tried <a href="https://example.com">this</a>?</p></div><!-- SC_ON --> &#32; submitted by &#32; <a href="https://www.reddit.com/user/asker"> /u/asker </a> <br/> <span><a href="https://www.reddit.com/r/rust/comments/2def/question/">[link]</a></span> &#32; <span><a href="https://www.reddit.com/r/rust/comments/2def/question/">[comments]</a></span>`;

const REDDIT_IMAGE_POST = `submitted by <a href="https://www.reddit.com/user/pics_fan"> /u/pics_fan </a> <span><a href="https://i.redd.it/abc123.jpeg">[link]</a></span> <span><a href="https://www.reddit.com/r/pics/comments/3ghi/sunset/">[comments]</a></span>`;

const HNRSS = `<p>Article URL: <a href="https://blog.example.com/post">https://blog.example.com/post</a></p><p>Comments URL: <a href="https://news.ycombinator.com/item?id=42">https://news.ycombinator.com/item?id=42</a></p><p>Points: 1,234</p><p># Comments: 567</p>`;

describe("parseAggregatorPost", () => {
  it("ignores ordinary articles", () => {
    expect(parseAggregatorPost({ url: "https://example.com/a", comments_url: null, content_html: "<p>Hi</p>", author: null })).toBeNull();
  });

  it("reads a Reddit link post from the feed HTML", () => {
    const post = parseAggregatorPost({
      url: "https://www.reddit.com/r/technology/comments/1abc/rogue_ai_agent/",
      comments_url: null,
      content_html: REDDIT_LINK_POST,
      author: "/u/plain_handle",
    })!;
    expect(post).toMatchObject({
      kind: "reddit",
      siteName: "Reddit",
      community: "r/technology",
      submitter: "plain_handle",
      linkUrl: "https://www.bbc.com/news/articles/c1234",
      mediaUrl: null,
      selfHtml: null,
      discussionUrl: "https://www.reddit.com/r/technology/comments/1abc/rogue_ai_agent/",
      thumbnailUrl: "https://external-preview.redd.it/thumb.jpg?width=640&crop=smart",
    });
  });

  it("keeps only the body of a Reddit self post", () => {
    const post = parseAggregatorPost({
      url: "https://www.reddit.com/r/rust/comments/2def/question/",
      comments_url: null,
      content_html: REDDIT_SELF_POST,
      author: null,
    })!;
    expect(post.linkUrl).toBeNull();
    expect(post.submitter).toBe("asker");
    expect(post.selfHtml).toContain("Has anyone tried");
    expect(post.selfHtml).not.toContain("submitted by");
    expect(post.selfHtml).not.toContain("[comments]");
  });

  it("treats a Reddit image post as media, not a link out", () => {
    const post = parseAggregatorPost({
      url: "https://www.reddit.com/r/pics/comments/3ghi/sunset/",
      comments_url: null,
      content_html: REDDIT_IMAGE_POST,
      author: null,
    })!;
    expect(post.mediaUrl).toBe("https://i.redd.it/abc123.jpeg");
    expect(post.linkUrl).toBeNull();
  });

  it("reads hnrss points, comment count and the linked article", () => {
    const post = parseAggregatorPost({
      url: "https://blog.example.com/post",
      comments_url: "https://news.ycombinator.com/item?id=42",
      content_html: HNRSS,
      author: "pg",
    })!;
    expect(post).toMatchObject({
      kind: "hacker_news",
      siteName: "Hacker News",
      linkUrl: "https://blog.example.com/post",
      discussionUrl: "https://news.ycombinator.com/item?id=42",
      submitter: "pg",
      points: 1234,
      commentCount: 567,
    });
  });

  it("has no link for an Ask HN post", () => {
    const post = parseAggregatorPost({
      url: "https://news.ycombinator.com/item?id=7",
      comments_url: null,
      content_html: `<a href="https://news.ycombinator.com/item?id=7">Comments</a>`,
      author: null,
    })!;
    expect(post.linkUrl).toBeNull();
    expect(post.discussionUrl).toBe("https://news.ycombinator.com/item?id=7");
  });
});

describe("displayDomain", () => {
  it("drops www", () => {
    expect(displayDomain("https://www.bbc.com/news/x")).toBe("bbc.com");
  });
});
