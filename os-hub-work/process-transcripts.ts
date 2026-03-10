import { readFileSync, writeFileSync, mkdirSync, readdirSync, existsSync } from "fs";
import { join } from "path";

const RAW_DIR = join(__dirname, "raw");
const OUTPUT_DIR = join(__dirname, "..", "OS HUB Transcripts");
const DOCS_FILE = join(__dirname, "transcript_docs.jsonl");

interface DocMeta {
  id: string;
  name: string;
}

interface CallSegment {
  topic: string;
  date: string; // yyyy.mm.dd
  content: string;
}

function toKebab(s: string): string {
  return s
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
}

function cleanCallName(name: string): string {
  return name
    // Strip [OS Hub] variants
    .replace(/^\[OS Hub\]\s*/i, "")
    .replace(/^\[OS Hub\]:\s*/i, "")
    .replace(/^OS Hub\s*/i, "")
    // Strip other bracket prefixes
    .replace(/^\[Purpose:\s*OsHub\]\s*/i, "")
    .replace(/^\[S&F:OS Hub[^\]]*\]\s*/i, "")
    .replace(/^\[Placeholder\]:\s*/i, "")
    .replace(/^\[Nick\s*\/\s*Anhelina[^\]]*\]\s*/i, "Nick-Anhelina OS Hub sync")
    .replace(/^\[OS Hub\s*<>\s*S&F[^\]]*\]\s*/i, "OS Hub-S&F ")
    .replace(/^\[OS Hub culture project\]\s*/i, "OS Hub culture project")
    .replace(/^\[OS Hub quarterly[^\]]*\]\s*/i, "OS Hub quarterly check-in prep")
    // Clean up leading punctuation left after prefix removal
    .replace(/^[:\s<>]+/, "")
    // Strip trailing transcript/date suffixes from doc names
    .replace(/\s*[-—]\s*Transcription?\s*$/i, "")
    .replace(/\s*[-—]\s*\d{2}\.\d{2}\s*[-—]\s*Transcription?\s*$/i, "")
    .replace(/\s*[-—]\s*\d{4}\/\d{2}\/\d{2}.*$/i, "")
    .trim();
}

function parseDate(dateStr: string): string | null {
  // Try: "Mar 10, 2026, 09:31 AM UTC"
  const m1 = dateStr.match(/(\w+)\s+(\d{1,2}),?\s+(\d{4})/);
  if (m1) {
    const months: Record<string, string> = {
      Jan: "01", Feb: "02", Mar: "03", Apr: "04", May: "05", Jun: "06",
      Jul: "07", Aug: "08", Sep: "09", Oct: "10", Nov: "11", Dec: "12",
    };
    const mon = months[m1[1]];
    if (mon) {
      return `${m1[3]}.${mon}.${m1[2].padStart(2, "0")}`;
    }
  }

  // Try: "2025/05/12 07:28 EDT" or "2025-03-04"
  const m2 = dateStr.match(/(\d{4})[\/\-](\d{2})[\/\-](\d{2})/);
  if (m2) {
    return `${m2[1]}.${m2[2]}.${m2[3]}`;
  }

  return null;
}

function parseDateFromDocName(name: string): string | null {
  // Try: "— 03.10 —" or "— 02.16 —"
  const m = name.match(/—\s*(\d{2})\.(\d{2})\s*—/);
  if (m) {
    const month = parseInt(m[1]);
    const day = m[2];
    const year = month > 3 ? "2025" : "2026";
    return `${year}.${m[1]}.${day}`;
  }

  // Try: "2025/05/12" format
  const m2 = name.match(/(\d{4})\/(\d{2})\/(\d{2})/);
  if (m2) {
    return `${m2[1]}.${m2[2]}.${m2[3]}`;
  }

  return null;
}

function stripTrailingMetadata(text: string): string {
  // Remove trailing Google Docs metadata lines
  return text
    .replace(/\n🗂️\s*Meeting Resources[\s\S]*$/, "")
    .replace(/\n📁\s*Parent Folder\s*$/, "")
    .trim();
}

function splitTranscript(text: string): CallSegment[] {
  const cleaned = stripTrailingMetadata(text);
  const parts = cleaned.split(/(?=^Topic: )/m);
  const segments: CallSegment[] = [];

  for (const part of parts) {
    const trimmed = part.trim();
    if (!trimmed) continue;

    const topicMatch = trimmed.match(/^Topic:\s*(.+)/m);
    if (!topicMatch) continue;

    const topic = topicMatch[1].trim();

    const dateMatch = trimmed.match(/^Date:\s*(.+)/m);
    let date: string | null = null;
    if (dateMatch) {
      date = parseDate(dateMatch[1].trim());
    }
    if (!date) date = "unknown";

    const contentMatch = trimmed.match(/^Transcription\s*\n([\s\S]*)/m);
    const content = contentMatch ? contentMatch[1].trim() : trimmed;

    segments.push({ topic, date, content });
  }

  return segments;
}

function main() {
  const docsLines = readFileSync(DOCS_FILE, "utf-8").split("\n").filter(Boolean);
  const docs: DocMeta[] = docsLines.map((l) => JSON.parse(l));

  console.log(`Found ${docs.length} transcript docs`);

  const rawFiles = readdirSync(RAW_DIR).filter((f) => f.endsWith(".txt"));
  console.log(`Found ${rawFiles.length} downloaded raw files`);

  // Phase 1: Collect ALL segments from all docs, dedup by (callName, date)
  // Keep the longest content for each unique (callName, date) pair
  const deduped = new Map<string, { callName: string; topic: string; date: string; content: string }>();

  const stats = {
    totalDocs: docs.length,
    downloaded: rawFiles.length,
    totalSegmentsRaw: 0,
    totalSegmentsDeduped: 0,
    duplicatesRemoved: 0,
    byCallName: {} as Record<string, number>,
    errors: [] as string[],
    missing: [] as string[],
  };

  for (const doc of docs) {
    const rawPath = join(RAW_DIR, `${doc.id}.txt`);
    if (!existsSync(rawPath)) {
      stats.missing.push(`${doc.name} (${doc.id})`);
      continue;
    }

    let text = readFileSync(rawPath, "utf-8");
    if (!text.trim()) {
      stats.errors.push(`Empty file: ${doc.name}`);
      continue;
    }

    // Strip "Content (NNN characters):\n---\n" prefix from MCP tool wrapper
    text = text.replace(/^Content \(\d+ characters\):\n---\n/, "");

    const topicCount = (text.match(/^Topic: /gm) || []).length;

    if (topicCount === 0) {
      // Single doc without Topic: headers
      const callName = cleanCallName(doc.name);
      const date = parseDateFromDocName(doc.name) || "unknown";
      const content = stripTrailingMetadata(text).trim();
      const key = `${callName}::${date}`;

      stats.totalSegmentsRaw++;
      const existing = deduped.get(key);
      if (!existing || content.length > existing.content.length) {
        deduped.set(key, { callName, topic: callName || doc.name, date, content });
      }
      continue;
    }

    const segments = splitTranscript(text);
    for (const seg of segments) {
      const callName = cleanCallName(seg.topic);
      const key = `${callName}::${seg.date}`;

      stats.totalSegmentsRaw++;
      const existing = deduped.get(key);
      if (!existing || seg.content.length > existing.content.length) {
        deduped.set(key, { callName, topic: seg.topic, date: seg.date, content: seg.content });
      }
    }
  }

  stats.totalSegmentsDeduped = deduped.size;
  stats.duplicatesRemoved = stats.totalSegmentsRaw - stats.totalSegmentsDeduped;

  // Phase 2: Write deduplicated files
  mkdirSync(OUTPUT_DIR, { recursive: true });

  for (const [, entry] of deduped) {
    const folderName = entry.callName || "Unknown";
    const slug = toKebab(entry.callName);

    const folderPath = join(OUTPUT_DIR, folderName);
    mkdirSync(folderPath, { recursive: true });

    const fileName = `${entry.date}-${slug || "transcript"}.md`;
    const filePath = join(folderPath, fileName);

    const mdContent = `# ${entry.topic} — ${entry.date}\n\n${entry.content}\n`;
    writeFileSync(filePath, mdContent);

    stats.byCallName[folderName] = (stats.byCallName[folderName] || 0) + 1;
  }

  // Print report
  console.log("\n=== PROCESSING REPORT ===");
  console.log(`Total transcript docs: ${stats.totalDocs}`);
  console.log(`Downloaded: ${stats.downloaded}`);
  console.log(`Missing downloads: ${stats.missing.length}`);
  console.log(`Total segments found (raw): ${stats.totalSegmentsRaw}`);
  console.log(`Duplicates removed: ${stats.duplicatesRemoved}`);
  console.log(`Total unique transcripts saved: ${stats.totalSegmentsDeduped}`);
  console.log("\n--- By call name ---");
  const sorted = Object.entries(stats.byCallName).sort((a, b) => b[1] - a[1]);
  for (const [name, count] of sorted) {
    console.log(`  ${count}x ${name}`);
  }
  if (stats.missing.length > 0) {
    console.log("\n--- Missing downloads ---");
    for (const m of stats.missing) {
      console.log(`  ${m}`);
    }
  }
  if (stats.errors.length > 0) {
    console.log("\n--- Errors ---");
    for (const e of stats.errors) {
      console.log(`  ${e}`);
    }
  }
}

main();
