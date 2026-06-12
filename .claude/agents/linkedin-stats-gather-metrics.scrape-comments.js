// Top-level comments scraper for linkedin-stats-gather-metrics step 10.3.
// Writes to `weeks[WEEK].comments` (the array of comment entries — distinct
// from `metrics.comments`, which is the analytics-reported total count).
//
// This file is the canonical scrape body. The agent MUST pass its contents
// verbatim to mcp__playwright__browser_evaluate as the `function` argument
// — no edits, no improvisation. Strip the leading "//" comment block first;
// keep the arrow function exactly as written.
//
// Output shape: an array (length 0..200) where EVERY entry has EXACTLY these
// five keys, in this order:
//   { author_name, author_url, text, reactions, replies_count }
//
// Do not add other keys (no `headline`, no `time_text`, no `profile_url`, no
// `author`, no `name`). Do not rename keys. Do not change selectors.

() => {
  const isTopLevel = (el) =>
    el && !el.closest('.comments-replies-list, .comments-comment-replies');

  const articles = Array.from(document.querySelectorAll('article.comments-comment-entity'))
    .filter(isTopLevel);

  const parseInt0 = (s) => {
    const m = (s || '').replace(/,/g, '').match(/\d+/);
    return m ? parseInt(m[0], 10) : 0;
  };

  const out = [];
  for (const a of articles.slice(0, 200)) {
    const nameEl = a.querySelector('.comments-comment-meta__description-title');
    const linkEl =
      a.querySelector('a.comments-comment-meta__description-container') ||
      a.querySelector('a.comments-comment-meta__image-link');

    // Comment body. The text container is the FIRST
    // `.comments-comment-item__main-content` inside this article that is
    // not inside a nested replies container.
    const textEl = Array.from(
      a.querySelectorAll('.comments-comment-item__main-content')
    ).find(isTopLevel);

    // Reaction + reply counts belong to the top-level comment only — skip
    // any matching elements that live inside a nested replies container.
    const reactEl = Array.from(
      a.querySelectorAll('.comments-comment-social-bar__reactions-count--cr')
    ).find(isTopLevel);
    const repliesEl = Array.from(
      a.querySelectorAll('.comments-comment-social-bar__replies-count--cr')
    ).find(isTopLevel);

    let author_url = linkEl?.getAttribute('href') || '';
    try {
      const u = new URL(author_url, 'https://www.linkedin.com');
      author_url = u.origin + u.pathname;
    } catch {}

    const author_name = (nameEl?.textContent || '').trim();

    // Pull text via innerText (handles line breaks), trim, cap at 2000 chars.
    let text = (textEl?.innerText || '').trim();
    if (text.length > 2000) text = text.slice(0, 2000);

    // Skip ghost cards (no name AND no URL AND no text).
    if (!author_name && !author_url && !text) continue;

    out.push({
      author_name,
      author_url,
      text,
      reactions:     parseInt0(reactEl?.textContent),
      replies_count: parseInt0(repliesEl?.textContent),
    });
  }
  return out;
}
