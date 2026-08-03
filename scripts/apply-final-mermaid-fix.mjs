import { readFile, writeFile } from "node:fs/promises";

const file = "docs/Phase3.1-Final-Architecture-Review.md";
let source = await readFile(file, "utf8");

const replacements = [
  [
    "        IR -. identity and ROLE_INVESTOR input expected .-> EP",
    "        IR -.->|identity and ROLE_INVESTOR input expected| EP",
  ],
  [
    "        IR -. not directly queried in Phase 3.1 .-> RM",
    "        IR -.->|not directly queried in Phase 3.1| RM",
  ],
];

let changed = false;
for (const [before, after] of replacements) {
  if (source.includes(after)) continue;
  if (!source.includes(before)) {
    throw new Error(`Expected Mermaid syntax not found: ${before}`);
  }
  source = source.replace(before, after);
  changed = true;
}

if (changed) {
  await writeFile(file, source, "utf8");
  console.log(`Updated ${file}`);
} else {
  console.log("Final Mermaid compatibility fixes are already applied.");
}
