import { mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import process from "node:process";
import { spawnSync } from "node:child_process";

const ROOTS = ["README.md", "docs"];
const MERMAID_BLOCK = /```mermaid[\t ]*\r?\n([\s\S]*?)```/g;
const MMDC = path.resolve("node_modules/.bin/mmdc");

async function collectMarkdownFiles(target) {
  const metadata = await stat(target);
  if (metadata.isFile()) {
    return target.endsWith(".md") ? [target] : [];
  }

  const entries = await readdir(target, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map((entry) => collectMarkdownFiles(path.join(target, entry.name))),
  );
  return nested.flat().filter((file) => file.endsWith(".md"));
}

const files = (
  await Promise.all(ROOTS.map((target) => collectMarkdownFiles(target)))
).flat();
const workdir = await mkdtemp(path.join(tmpdir(), "ip-breaker-mermaid-"));

let diagramCount = 0;
const failures = [];

try {
  for (const file of files.sort()) {
    const source = await readFile(file, "utf8");
    const matches = [...source.matchAll(MERMAID_BLOCK)];

    for (const [index, match] of matches.entries()) {
      diagramCount += 1;
      const diagram = match[1].trim();
      const startLine = source.slice(0, match.index).split(/\r?\n/).length;
      const basename = `${diagramCount}-${path.basename(file, ".md")}-${index + 1}`;
      const input = path.join(workdir, `${basename}.mmd`);
      const output = path.join(workdir, `${basename}.svg`);

      await writeFile(input, `${diagram}\n`, "utf8");
      const result = spawnSync(MMDC, ["-i", input, "-o", output], {
        encoding: "utf8",
        env: process.env,
      });

      if (result.status === 0) {
        console.log(`PASS ${file}:${startLine} diagram ${index + 1}`);
        continue;
      }

      const message = [result.stdout, result.stderr]
        .filter(Boolean)
        .join("\n")
        .trim();
      failures.push({ file, startLine, index: index + 1, message });
      console.error(`FAIL ${file}:${startLine} diagram ${index + 1}`);
      console.error(message || `mmdc exited with status ${result.status}`);
    }
  }
} finally {
  await rm(workdir, { recursive: true, force: true });
}

if (failures.length > 0) {
  console.error(`\n${failures.length} Mermaid diagram(s) failed rendering.`);
  process.exit(1);
}

console.log(`\nRendered ${diagramCount} Mermaid diagram(s) across ${files.length} Markdown file(s).`);
