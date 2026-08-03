import { readFile, writeFile } from "node:fs/promises";

const replacements = [
  {
    file: "docs/Phase3.1-Final-Architecture-Review.md",
    from: "    V->>V: accrue both; migrate pending; rewrite debt; check solvency",
    to: "    V->>V: accrue both, migrate pending, rewrite debt, check solvency",
  },
  {
    file: "docs/Phase3.1-Final-Architecture-Review.md",
    from: "    M->>M: status = Executed; clear active request",
    to: "    M->>M: status = Executed, clear active request",
  },
  {
    file: "docs/Phase3.2-OfferingEscrow-Design.md",
    from: "    M->>M: validate identity, time, capacity; compute filled and usdcCost",
    to: "    M->>M: validate identity, time and capacity, then compute filled and usdcCost",
  },
  {
    file: "docs/Phase3.2-OfferingEscrow-Design.md",
    from: "    E->>E: verify exact balance delta; record funded contribution",
    to: "    E->>E: verify exact balance delta, then record funded contribution",
  },
];

const byFile = new Map();
for (const replacement of replacements) {
  const list = byFile.get(replacement.file) ?? [];
  list.push(replacement);
  byFile.set(replacement.file, list);
}

let changed = false;
for (const [file, fileReplacements] of byFile) {
  let source = await readFile(file, "utf8");
  let fileChanged = false;

  for (const { from, to } of fileReplacements) {
    if (source.includes(to)) {
      continue;
    }
    if (!source.includes(from)) {
      throw new Error(`Expected Mermaid source text not found in ${file}: ${from}`);
    }
    source = source.replace(from, to);
    fileChanged = true;
  }

  if (fileChanged) {
    await writeFile(file, source, "utf8");
    console.log(`Updated ${file}`);
    changed = true;
  }
}

if (!changed) {
  console.log("Known Mermaid fixes are already applied.");
}
