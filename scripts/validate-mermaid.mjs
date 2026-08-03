import { readdir, readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import mermaid from "mermaid";

const ROOTS = ["README.md", "docs"];
const MERMAID_BLOCK = /```mermaid[\t ]*\r?\n([\s\S]*?)```/g;

async function collectMarkdownFiles(target) {
  const stat = await import("node:fs/promises").then(({ stat }) => stat(target));
  if (stat.isFile()) {
    return target.endsWith(".md") ? [target] : [];
  }

  const entries = await readdir(target, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map((entry) => collectMarkdownFiles(path.join(target, entry.name))),
  );
  return nested.flat().filter((file) => file.endsWith(".md"));
}

mermaid.initialize({
  startOnLoad: false,
  securityLevel: "strict",
});

const files = (
  await Promise.all(ROOTS.map((target) => collectMarkdownFiles(target)))
).flat();

let diagramCount = 0;
const failures = [];

for (const file of files.sort()) {
  const source = await readFile(file, "utf8");
  const matches = [...source.matchAll(MERMAID_BLOCK)];

  for (const [index, match] of matches.entries()) {
    diagramCount += 1;
    const diagram = match[1].trim();
    const startLine = source.slice(0, match.index).split(/\r?\n/).length;

    try {
      await mermaid.parse(diagram);
      console.log(`PASS ${file}:${startLine} diagram ${index + 1}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      failures.push({ file, startLine, index: index + 1, message });
      console.error(`FAIL ${file}:${startLine} diagram ${index + 1}`);
      console.error(message);
    }
  }
}

if (failures.length > 0) {
  console.error(`\n${failures.length} Mermaid diagram(s) failed validation.`);
  process.exit(1);
}

console.log(`\nValidated ${diagramCount} Mermaid diagram(s) across ${files.length} Markdown file(s).`);
