import * as fs from "fs";
import * as path from "path";
import * as https from "https";

interface Post {
  id: string;
  date: string;
  timestamp: number;
  fullText: string;
  impressions: number;
  reactions: number;
  comments: number;
  reposts: number;
  imageUrls: string[];
  url: string;
}

const POSTS_DIR = path.join(__dirname, "posts");
const IMAGES_DIR = path.join(__dirname, "images");

function normalizeUnicode(text: string): string {
  // Map Unicode bold/italic math chars to ASCII
  const ranges: [number, number, number][] = [
    [0x1d400, 0x1d419, 65],  // Bold A-Z
    [0x1d41a, 0x1d433, 97],  // Bold a-z
    [0x1d434, 0x1d44d, 65],  // Italic A-Z
    [0x1d44e, 0x1d467, 97],  // Italic a-z
    [0x1d468, 0x1d481, 65],  // Bold Italic A-Z
    [0x1d482, 0x1d49b, 97],  // Bold Italic a-z
    [0x1d5d4, 0x1d5ed, 65],  // Bold Sans A-Z
    [0x1d5ee, 0x1d607, 97],  // Bold Sans a-z
    [0x1d608, 0x1d621, 65],  // Sans Italic A-Z
    [0x1d622, 0x1d63b, 97],  // Sans Italic a-z
    [0x1d63c, 0x1d655, 65],  // Sans Bold Italic A-Z
    [0x1d656, 0x1d66f, 97],  // Sans Bold Italic a-z
    [0x1d670, 0x1d689, 65],  // Monospace A-Z
    [0x1d68a, 0x1d6a3, 97],  // Monospace a-z
    [0x1d7ce, 0x1d7d7, 48],  // Bold 0-9
    [0x1d7d8, 0x1d7e1, 48],  // Double-struck 0-9
    [0x1d7e2, 0x1d7eb, 48],  // Sans 0-9
    [0x1d7ec, 0x1d7f5, 48],  // Sans Bold 0-9
    [0x1d7f6, 0x1d7ff, 48],  // Monospace 0-9
  ];

  let result = "";
  for (const char of text) {
    const cp = char.codePointAt(0)!;
    let mapped = false;
    for (const [start, end, base] of ranges) {
      if (cp >= start && cp <= end) {
        result += String.fromCharCode(base + (cp - start));
        mapped = true;
        break;
      }
    }
    if (!mapped) {
      // Also handle serif bold/italic from Mathematical Alphanumeric Symbols
      if (cp >= 0x1d4b0 && cp <= 0x1d4b9) {
        result += String.fromCharCode(65 + (cp - 0x1d4b0)); // Script A-Z
      } else if (cp >= 0x1d4ea && cp <= 0x1d503) {
        result += String.fromCharCode(97 + (cp - 0x1d4ea)); // Script a-z
      } else {
        result += char;
      }
    }
  }
  return result;
}

function slugify(text: string): string {
  return normalizeUnicode(text)
    .toLowerCase()
    .replace(/[^\w\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .substring(0, 50)
    .replace(/-$/, "");
}

function getTitle(text: string): string {
  // Take first line or first ~60 chars, normalize unicode
  const firstLine = normalizeUnicode(text.split("\n")[0].trim());
  if (firstLine.length <= 70) return firstLine;
  return firstLine.substring(0, 67) + "...";
}

function hasEmoji(text: string): boolean {
  const emojiRegex =
    /[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}\u{1F1E0}-\u{1F1FF}\u{2702}-\u{27B0}\u{24C2}-\u{1F251}\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FA6F}\u{1FA70}-\u{1FAFF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}\u{FE00}-\u{FE0F}\u{1F000}-\u{1F02F}\u{200D}\u{20E3}\u{FE0F}\u{E0020}-\u{E007F}]/u;
  return emojiRegex.test(text);
}

function downloadImage(url: string, dest: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    https
      .get(url, (response) => {
        if (response.statusCode === 301 || response.statusCode === 302) {
          const redirectUrl = response.headers.location;
          if (redirectUrl) {
            file.close();
            fs.unlinkSync(dest);
            return downloadImage(redirectUrl, dest).then(resolve).catch(reject);
          }
        }
        response.pipe(file);
        file.on("finish", () => {
          file.close();
          resolve();
        });
      })
      .on("error", (err) => {
        fs.unlinkSync(dest);
        reject(err);
      });
  });
}

async function main() {
  const rawData = JSON.parse(
    fs.readFileSync(path.join(__dirname, "raw_data.json"), "utf-8")
  ) as Post[];

  // Sort by date descending
  const posts = rawData.sort(
    (a, b) => new Date(b.date).getTime() - new Date(a.date).getTime()
  );

  fs.mkdirSync(POSTS_DIR, { recursive: true });
  fs.mkdirSync(IMAGES_DIR, { recursive: true });

  const yamlEntries: string[] = [];

  for (const post of posts) {
    const title = getTitle(post.fullText);
    const slug = slugify(title);
    const fileBase = `${post.date}-${slug}`;

    // Download image if exists
    let imageFile = "";
    if (post.imageUrls.length > 0) {
      const ext = "jpg";
      imageFile = `images/${fileBase}.${ext}`;
      const imageDest = path.join(__dirname, imageFile);
      if (!fs.existsSync(imageDest)) {
        try {
          console.log(`Downloading image for ${post.date}...`);
          await downloadImage(post.imageUrls[0], imageDest);
        } catch (e) {
          console.error(`Failed to download image for ${post.id}:`, e);
          imageFile = "";
        }
      }
    }

    // Create markdown file
    const contentFile = `posts/${fileBase}.md`;
    let md = `# ${title}\n\n`;
    md += `**Date:** ${post.date}\n\n`;
    md += `**Impressions:** ${post.impressions.toLocaleString()} | **Reactions:** ${post.reactions} | **Comments:** ${post.comments} | **Reposts:** ${post.reposts}\n\n`;
    md += `**LinkedIn URL:** [View Post](${post.url})\n\n`;
    md += `---\n\n`;
    md += post.fullText + "\n";
    if (imageFile) {
      md += `\n![Post Image](../${imageFile})\n`;
    }

    fs.writeFileSync(path.join(__dirname, contentFile), md, "utf-8");
    console.log(`Created ${contentFile}`);

    // Build YAML entry
    const preview =
      post.fullText.substring(0, 60).replace(/"/g, '\\"').replace(/\n/g, " ") +
      "...";
    yamlEntries.push(`  - id: "${post.id}"
    date: "${post.date}"
    title: "${title.replace(/"/g, '\\"')}"
    impressions: ${post.impressions}
    reactions: ${post.reactions}
    comments: ${post.comments}
    reposts: ${post.reposts}
    has_image: ${post.imageUrls.length > 0}
    image_file: "${imageFile}"
    content_file: "${contentFile}"
    url: "${post.url}"
    content_length: ${post.fullText.length}
    has_emoji: ${hasEmoji(post.fullText)}
    content_preview: "${preview}"`);
  }

  // Write statistics.yaml
  const yaml = `posts:\n${yamlEntries.join("\n")}\n`;
  fs.writeFileSync(path.join(__dirname, "statistics.yaml"), yaml, "utf-8");
  console.log("Created statistics.yaml");

  // Build index.md
  const totalPosts = posts.length;
  const totalImpressions = posts.reduce((s, p) => s + p.impressions, 0);
  const avgImpressions = Math.round(totalImpressions / totalPosts);
  const totalReactions = posts.reduce((s, p) => s + p.reactions, 0);
  const totalComments = posts.reduce((s, p) => s + p.comments, 0);
  const topByImpressions = [...posts]
    .sort((a, b) => b.impressions - a.impressions)
    .slice(0, 3);
  const topByReactions = [...posts]
    .sort((a, b) => b.reactions - a.reactions)
    .slice(0, 3);

  let index = `# Peter Ovchynnikov - LinkedIn Posts Wiki\n\n`;
  index += `> Posts from ${posts[posts.length - 1].date} to ${posts[0].date}\n\n`;
  index += `## Summary Statistics\n\n`;
  index += `| Metric | Value |\n`;
  index += `|--------|-------|\n`;
  index += `| Total Posts | ${totalPosts} |\n`;
  index += `| Total Impressions | ${totalImpressions.toLocaleString()} |\n`;
  index += `| Avg Impressions/Post | ${avgImpressions.toLocaleString()} |\n`;
  index += `| Total Reactions | ${totalReactions} |\n`;
  index += `| Total Comments | ${totalComments} |\n`;
  index += `| Date Range | ${posts[posts.length - 1].date} to ${posts[0].date} |\n\n`;

  index += `## Top Posts by Impressions\n\n`;
  for (const p of topByImpressions) {
    const title = getTitle(p.fullText);
    const slug = slugify(title);
    index += `1. **[${title}](posts/${p.date}-${slug}.md)** - ${p.impressions.toLocaleString()} impressions\n`;
  }

  index += `\n## Top Posts by Reactions\n\n`;
  for (const p of topByReactions) {
    const title = getTitle(p.fullText);
    const slug = slugify(title);
    index += `1. **[${title}](posts/${p.date}-${slug}.md)** - ${p.reactions} reactions\n`;
  }

  index += `\n## All Posts\n\n`;
  index += `| Date | Title | Impressions | Reactions | Comments | Reposts |\n`;
  index += `|------|-------|-------------|-----------|----------|---------|\n`;
  for (const p of posts) {
    const title = getTitle(p.fullText);
    const slug = slugify(title);
    const shortTitle =
      title.length > 55 ? title.substring(0, 52) + "..." : title;
    index += `| ${p.date} | [${shortTitle}](posts/${p.date}-${slug}.md) | ${p.impressions.toLocaleString()} | ${p.reactions} | ${p.comments} | ${p.reposts} |\n`;
  }

  index += `\n---\n*Generated on ${new Date().toISOString().split("T")[0]}*\n`;

  fs.writeFileSync(path.join(__dirname, "index.md"), index, "utf-8");
  console.log("Created index.md");

  console.log("\nDone! Generated:");
  console.log(`  - ${totalPosts} post markdown files`);
  console.log(`  - statistics.yaml`);
  console.log(`  - index.md`);
}

main().catch(console.error);
