#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

function findMoRoot(startDir) {
  let cur = path.resolve(startDir);
  let highest = cur;
  while (true) {
    if (fs.existsSync(path.join(cur, "mo.toml"))) {
      highest = cur;
    }
    const parent = path.dirname(cur);
    if (parent === cur) return highest;
    cur = parent;
  }
}

const kind = process.argv[2];
if (!kind || (kind !== "vitest" && kind !== "stryker")) {
  console.error("usage: stamp-evidence.mjs <vitest|stryker>");
  process.exit(2);
}

const appDirAbs = path.resolve(process.cwd(), "..");
const rootDir = findMoRoot(appDirAbs);
const relApp = path.relative(rootDir, appDirAbs) || ".";
const defaultLocalBin = path.join(os.homedir(), ".local", "bin", "arvo");
const arvoBin =
  process.env.ARVO_BIN ||
  (fs.existsSync(defaultLocalBin) ? defaultLocalBin : "arvo");

const buildSha = execFileSync(arvoBin, ["control", "sha", "--app", relApp], {
  cwd: rootDir,
  encoding: "utf8",
}).trim();

const evidenceDir = path.join(appDirAbs, ".arvo", "evidence");
fs.mkdirSync(evidenceDir, { recursive: true });
const outPath = path.join(evidenceDir, `${kind}-meta.json`);
fs.writeFileSync(
  outPath,
  `${JSON.stringify({ kind, build_sha: buildSha, stamped_at: new Date().toISOString() }, null, 2)}\n`,
);
