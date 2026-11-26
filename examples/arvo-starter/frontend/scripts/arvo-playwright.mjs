#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import AxeBuilder from "@axe-core/playwright";
import pixelmatch from "pixelmatch";
import { chromium } from "playwright-core";
import { PNG } from "pngjs";

const VIEWPORTS = {
  mobile: { name: "mobile", width: 390, height: 844 },
  desktop: { name: "desktop", width: 1280, height: 800 },
};

function parseCliArgs(argv) {
  const opts = {
    mode: "drive",
    baseUrl: "",
    runId: "",
    appDir: ".",
    evidenceDir: "",
    buildSha: "",
    viewport: "all",
    reqPath: "/",
    outPath: "",
    cdpUrl: process.env.ARVO_CDP_URL || "",
    updateVisual: process.env.ARVO_UPDATE_VISUAL_SNAPSHOTS === "1",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`Missing value for ${a}`);
      return argv[i];
    };
    if (a === "--mode") opts.mode = next();
    else if (a === "--base-url") opts.baseUrl = next().replace(/\/+$/, "");
    else if (a === "--run-id") opts.runId = next();
    else if (a === "--app-dir") opts.appDir = next();
    else if (a === "--evidence-dir") opts.evidenceDir = next();
    else if (a === "--build-sha") opts.buildSha = next();
    else if (a === "--viewport") opts.viewport = next();
    else if (a === "--path") opts.reqPath = next();
    else if (a === "--out") opts.outPath = next();
    else if (a === "--cdp-url") opts.cdpUrl = next();
    else if (a === "--update-visual") opts.updateVisual = true;
    else throw new Error(`Unknown option: ${a}`);
  }
  return opts;
}

function resolveArvoBin() {
  if (process.env.ARVO_BIN) return process.env.ARVO_BIN;
  const localBin = path.join(os.homedir(), ".local", "bin", "arvo");
  return fs.existsSync(localBin) ? localBin : "arvo";
}

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

function runArvoControl(appDirAbs, subArgs) {
  const bin = resolveArvoBin();
  const rootDir = findMoRoot(appDirAbs);
  const relApp = path.relative(rootDir, appDirAbs) || ".";
  const stdout = execFileSync(bin, ["control", ...subArgs, "--app", relApp], {
    cwd: rootDir,
    encoding: "utf8",
  });
  return stdout.trim();
}

async function openBrowser(cdpUrl) {
  if (cdpUrl) {
    const browser = await chromium.connectOverCDP(cdpUrl);
    return { browser, closeBrowser: async () => browser.close() };
  }
  const executablePath = fs.existsSync("/usr/bin/google-chrome")
    ? "/usr/bin/google-chrome"
    : undefined;
  const browser = await chromium.launch({
    executablePath,
    headless: true,
    args: ["--headless=new", "--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
  });
  return { browser, closeBrowser: async () => browser.close() };
}

function attachFailClosedListeners(page, state, baseUrl) {
  page.on("console", (msg) => {
    if (msg.type() === "error") {
      state.consoleErrors.push(msg.text());
    }
  });
  page.on("pageerror", (err) => {
    state.pageErrors.push(String(err));
  });
  page.on("response", (res) => {
    const url = res.url();
    const status = res.status();
    if (!url.startsWith(baseUrl)) return;
    const reqPath = new URL(url).pathname;
    if (status >= 500) {
      state.http5xx.push(`${status} ${reqPath}`);
    }
    if (reqPath.startsWith("/assets/") && status === 404) {
      state.brokenAssets.push(`${status} ${reqPath}`);
    }
  });
}

async function assertAxeClean(page, pageLabel, state) {
  const results = await new AxeBuilder({ page }).analyze();
  const bad = results.violations.filter(
    (v) => v.impact === "critical" || v.impact === "serious",
  );
  for (const v of bad) {
    state.axeViolations.push({
      page: pageLabel,
      id: v.id,
      impact: v.impact,
      help: v.help,
      nodes: v.nodes.length,
    });
  }
}

async function capturePageArtifacts(page, label, evidenceAbs) {
  await page.evaluate(async () => {
    if (document.fonts?.ready) await document.fonts.ready;
  });
  const pngPath = path.join(evidenceAbs, `${label}.png`);
  const ariaPath = path.join(evidenceAbs, `${label}.aria.txt`);
  await page.screenshot({ path: pngPath, fullPage: true, animations: "disabled" });
  const ariaYaml = await page.locator("body").ariaSnapshot();
  fs.writeFileSync(ariaPath, `${ariaYaml}\n`, "utf8");
  return { pngPath, ariaPath };
}

function checkVisualParity(label, actualPngPath, visualDir, updateVisual) {
  const baselinePath = path.join(visualDir, `${label}.png`);
  if (updateVisual) {
    fs.mkdirSync(visualDir, { recursive: true });
    fs.copyFileSync(actualPngPath, baselinePath);
    return { label, diffPixels: 0, updated: true };
  }
  if (!fs.existsSync(baselinePath)) {
    throw new Error(
      `Missing visual parity baseline ${baselinePath} (run with --update-visual or ARVO_UPDATE_VISUAL_SNAPSHOTS=1 once to establish verified baseline)`,
    );
  }
  const actual = PNG.sync.read(fs.readFileSync(actualPngPath));
  const baseline = PNG.sync.read(fs.readFileSync(baselinePath));
  if (actual.width !== baseline.width || actual.height !== baseline.height) {
    throw new Error(
      `Visual dimension mismatch for ${label}: actual=${actual.width}x${actual.height}, baseline=${baseline.width}x${baseline.height}`,
    );
  }
  const diff = new PNG({ width: baseline.width, height: baseline.height });
  const diffPixels = pixelmatch(
    baseline.data,
    actual.data,
    diff.data,
    baseline.width,
    baseline.height,
    { threshold: 0.0 },
  );
  if (diffPixels > 0) {
    const diffPath = actualPngPath.replace(/\.png$/, ".diff.png");
    fs.writeFileSync(diffPath, PNG.sync.write(diff));
  }
  return { label, diffPixels, updated: false };
}

function extractFeatureScenarios(appDirAbs) {
  const fdir = path.join(appDirAbs, "specs", "features");
  if (!fs.existsSync(fdir)) return [];
  const names = [];
  for (const fname of fs.readdirSync(fdir).sort()) {
    if (!fname.endsWith(".feature.md")) continue;
    const raw = fs.readFileSync(path.join(fdir, fname), "utf8");
    const lines = raw.split(/\r?\n/);
    for (let i = 0; i < lines.length; i += 1) {
      if (lines[i].includes("@browser")) {
        const nextLine = (lines[i + 1] || "").trim();
        if (nextLine.startsWith("Scenario:")) {
          names.push(`${fname}: ${nextLine.slice("Scenario:".length).trim()}`);
        }
      }
    }
  }
  return names;
}

async function runDriveViewport(browser, opts, vp, appDirAbs, evidenceAbs, visualDir, state) {
  const videoTmpDir = path.join(evidenceAbs, `_video_tmp_${vp.name}`);
  fs.mkdirSync(videoTmpDir, { recursive: true });
  const context = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    deviceScaleFactor: 1,
    recordVideo: { dir: videoTmpDir, size: { width: vp.width, height: vp.height } },
  });
  await context.tracing.start({ screenshots: true, snapshots: true });
  const page = await context.newPage();
  attachFailClosedListeners(page, state, opts.baseUrl);
  const videoObj = page.video();

  try {
    // 1. Auth guest gate -> /login -> sign in
    await page.goto(`${opts.baseUrl}/`, { waitUntil: "networkidle" });
    await page.waitForURL((u) => new URL(u).pathname === "/login");
    await page.getByRole("heading", { name: "Sign in to Arvo" }).waitFor();
    await assertAxeClean(page, `login-${vp.name}`, state);

    const loginArts = await capturePageArtifacts(page, `login-${vp.name}`, evidenceAbs);
    state.screenshots.push(path.relative(appDirAbs, loginArts.pngPath));
    state.ariaFiles.push(path.relative(appDirAbs, loginArts.ariaPath));
    state.visualChecks.push(
      checkVisualParity(`login-${vp.name}`, loginArts.pngPath, visualDir, opts.updateVisual),
    );

    await page.getByLabel("Email").fill("Ada@Household.Local");
    await page.getByLabel("Password").fill("horse-staple-battery");
    await page.getByRole("button", { name: "Sign in" }).click();
    await page.waitForURL((u) => new URL(u).pathname === "/");
    await page.getByRole("heading", { name: "Ada & Household <Team>" }).waitFor();
    await page.getByRole("status").waitFor();
    await page.waitForLoadState("networkidle");
    await assertAxeClean(page, `home-${vp.name}`, state);

    const homeArts = await capturePageArtifacts(page, `home-${vp.name}`, evidenceAbs);
    state.screenshots.push(path.relative(appDirAbs, homeArts.pngPath));
    state.ariaFiles.push(path.relative(appDirAbs, homeArts.ariaPath));
    state.visualChecks.push(
      checkVisualParity(`home-${vp.name}`, homeArts.pngPath, visualDir, opts.updateVisual),
    );
    state.scenariosPassed.push(`auth.feature.md: Guest redirect and sign in (${vp.name})`);

    // 2. Create a new bill + reload + @db-check SQL & audit trail
    await page.getByLabel("Bill name").fill("Fiber Internet");
    await page.getByLabel("Category").selectOption("utilities");
    await page.getByLabel("Amount in cents").fill("7500");
    await page.getByRole("button", { name: "Save Bill" }).click();
    await page.getByText("Fiber Internet (due)").waitFor();
    await page.getByText("Due this paycheck: $220.00").waitFor();
    await page.reload({ waitUntil: "networkidle" });
    await page.getByText("Fiber Internet (due)").waitFor();
    await page.getByText("Due this paycheck: $220.00").waitFor();

    const billsSql = JSON.parse(
      runArvoControl(appDirAbs, [
        "inspect",
        "--run-id",
        opts.runId,
        "--sql",
        "SELECT name, category, amount_cents, status FROM bills WHERE name = 'Fiber Internet'",
      ]),
    );
    if (!Array.isArray(billsSql) || billsSql.length !== 1 || billsSql[0].amount_cents !== 7500) {
      throw new Error(`@db-check bill.create SQL mismatch: ${JSON.stringify(billsSql)}`);
    }
    const createAudit = JSON.parse(
      runArvoControl(appDirAbs, ["inspect", "--run-id", opts.runId, "--audit"]),
    );
    if (
      !createAudit.some(
        (ev) =>
          ev.action === "bill.create" &&
          ev.actor === "ada@household.local" &&
          ev.entity_table === "bills",
      )
    ) {
      throw new Error("@db-check bill.create audit entry missing");
    }
    state.dbChecksPassed += 1;
    state.scenariosPassed.push(`bills.feature.md: Create bill + @db-check (${vp.name})`);

    // 3. Mark bill paid -> persistence across reload -> @db-check -> stale 409 conflict
    await page.getByRole("button", { name: "Mark paid Electric & Gas <Utility>" }).click();
    await page.getByText("Electric & Gas <Utility> (in_flight)").waitFor();
    await page.reload({ waitUntil: "networkidle" });
    await page.getByText("Electric & Gas <Utility> (in_flight)").waitFor();
    await assertAxeClean(page, `home-after-pay-${vp.name}`, state);

    const paidArts = await capturePageArtifacts(page, `home-after-pay-${vp.name}`, evidenceAbs);
    state.screenshots.push(path.relative(appDirAbs, paidArts.pngPath));
    state.ariaFiles.push(path.relative(appDirAbs, paidArts.ariaPath));
    state.visualChecks.push(
      checkVisualParity(
        `home-after-pay-${vp.name}`,
        paidArts.pngPath,
        visualDir,
        opts.updateVisual,
      ),
    );

    const payAudit = JSON.parse(
      runArvoControl(appDirAbs, ["inspect", "--run-id", opts.runId, "--audit"]),
    );
    if (
      !payAudit.some(
        (ev) =>
          ev.action === "bill.mark_in_flight" &&
          ev.actor === "ada@household.local" &&
          ev.entity_table === "bills",
      )
    ) {
      throw new Error("@db-check bill.mark_in_flight audit entry missing");
    }

    const xsrfCookie = (await context.cookies()).find((c) => c.name === "XSRF-TOKEN");
    const csrfToken = xsrfCookie ? decodeURIComponent(xsrfCookie.value) : "";
    const conflictRes = await context.request.post(`${opts.baseUrl}/bills/1/pay`, {
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-XSRF-TOKEN": csrfToken,
      },
      data: { expected_version: 1, reason: null },
    });
    const conflictStatus = conflictRes.status();
    if (conflictStatus !== 409) {
      throw new Error(`Expected 409 Conflict on stale expected_version=1, got ${conflictStatus}`);
    }
    state.dbChecksPassed += 1;
    state.scenariosPassed.push(
      `bills.feature.md: Mark paid + @db-check + 409 conflict (${vp.name})`,
    );

    // 4. Sign out returns to /login
    await page.getByRole("button", { name: "Sign out" }).click();
    await page.waitForURL((u) => new URL(u).pathname === "/login");
    await page.getByRole("heading", { name: "Sign in to Arvo" }).waitFor();
  } finally {
    const tracePath = path.join(evidenceAbs, `trace-${vp.name}.zip`);
    await context.tracing.stop({ path: tracePath });
    state.traces.push(path.relative(appDirAbs, tracePath));
    await context.close();
    if (videoObj) {
      const rawVid = await videoObj.path();
      if (rawVid && fs.existsSync(rawVid)) {
        const finalVid = path.join(evidenceAbs, `record-${vp.name}.webm`);
        fs.copyFileSync(rawVid, finalVid);
        state.videos.push(path.relative(appDirAbs, finalVid));
      }
    }
    fs.rmSync(videoTmpDir, { recursive: true, force: true });
  }
}

async function runDrive(opts, appDirAbs, evidenceAbs) {
  const vpList =
    opts.viewport === "all"
      ? [VIEWPORTS.mobile, VIEWPORTS.desktop]
      : [VIEWPORTS[opts.viewport] || VIEWPORTS.desktop];
  const visualDir = path.join(appDirAbs, "snapshots", "visual");
  const browserScenarios = extractFeatureScenarios(appDirAbs);
  const state = {
    build_sha: opts.buildSha,
    run_id: opts.runId,
    passed: false,
    viewports: vpList.map((v) => v.name),
    feature_scenarios_discovered: browserScenarios,
    scenariosPassed: [],
    consoleErrors: [],
    pageErrors: [],
    http5xx: [],
    brokenAssets: [],
    axeViolations: [],
    dbChecksPassed: 0,
    visualChecks: [],
    screenshots: [],
    ariaFiles: [],
    traces: [],
    videos: [],
  };

  const { browser, closeBrowser } = await openBrowser(opts.cdpUrl);
  try {
    for (let idx = 0; idx < vpList.length; idx += 1) {
      const vp = vpList[idx];
      if (idx > 0 && opts.runId) {
        runArvoControl(appDirAbs, ["reset", "--run-id", opts.runId, "--seed", "baseline"]);
      }
      await runDriveViewport(browser, opts, vp, appDirAbs, evidenceAbs, visualDir, state);
    }
  } finally {
    await closeBrowser();
  }

  const maxDiffPixels = state.visualChecks.reduce((m, c) => Math.max(m, c.diffPixels), 0);
  const hasUpdatedVisual = state.visualChecks.some((c) => Boolean(c.updated));
  const ok =
    state.consoleErrors.length === 0 &&
    state.pageErrors.length === 0 &&
    state.http5xx.length === 0 &&
    state.brokenAssets.length === 0 &&
    state.axeViolations.length === 0 &&
    state.dbChecksPassed >= vpList.length * 2 &&
    !hasUpdatedVisual &&
    maxDiffPixels === 0;

  const report = {
    build_sha: opts.buildSha,
    run_id: opts.runId,
    passed: ok,
    viewports: state.viewports,
    feature_scenarios_discovered: state.feature_scenarios_discovered,
    scenarios_passed: state.scenariosPassed,
    console_errors: state.consoleErrors,
    page_errors: state.pageErrors,
    http_5xx: state.http5xx,
    broken_assets: state.brokenAssets,
    axe_violations: state.axeViolations,
    db_checks_passed: state.dbChecksPassed,
    visual_diff_pixels: maxDiffPixels,
    visual_checks: state.visualChecks,
    screenshots: state.screenshots,
    aria_files: state.ariaFiles,
    traces: state.traces,
    videos: state.videos,
  };
  fs.writeFileSync(path.join(evidenceAbs, "e2e-report.json"), `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify(report));
  if (!ok) {
    process.exitCode = 1;
  }
}

async function runSingleCapture(opts, appDirAbs, evidenceAbs, isVideo) {
  const vp = VIEWPORTS[opts.viewport] || VIEWPORTS.desktop;
  const outAbs = opts.outPath
    ? path.isAbsolute(opts.outPath)
      ? opts.outPath
      : path.join(evidenceAbs, opts.outPath)
    : path.join(evidenceAbs, isVideo ? `record-${vp.name}.webm` : `shot-${vp.name}.png`);
  fs.mkdirSync(path.dirname(outAbs), { recursive: true });

  const state = {
    consoleErrors: [],
    pageErrors: [],
    http5xx: [],
    brokenAssets: [],
    axeViolations: [],
  };
  const { browser, closeBrowser } = await openBrowser(opts.cdpUrl);
  const videoTmp = path.join(evidenceAbs, `_rec_${vp.name}`);
  if (isVideo) fs.mkdirSync(videoTmp, { recursive: true });
  const context = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    deviceScaleFactor: 1,
    ...(isVideo ? { recordVideo: { dir: videoTmp, size: { width: vp.width, height: vp.height } } } : {}),
  });
  const page = await context.newPage();
  attachFailClosedListeners(page, state, opts.baseUrl);
  const videoObj = isVideo ? page.video() : null;

  try {
    await page.goto(`${opts.baseUrl}${opts.reqPath}`, { waitUntil: "networkidle" });
    await page.evaluate(async () => {
      if (document.fonts?.ready) await document.fonts.ready;
    });
    if (isVideo) {
      if (new URL(page.url()).pathname === "/login") {
        await page.getByLabel("Email").fill("ada@household.local");
        await page.getByLabel("Password").fill("horse-staple-battery");
        await page.getByRole("button", { name: "Sign in" }).click();
        await page.waitForURL((u) => new URL(u).pathname === "/");
        await page.waitForLoadState("networkidle");
      }
    } else {
      await assertAxeClean(page, `screenshot-${vp.name}`, state);
      await page.screenshot({ path: outAbs, fullPage: true, animations: "disabled" });
      const ariaPath = outAbs.replace(/\.png$/, ".aria.txt");
      fs.writeFileSync(ariaPath, `${await page.locator("body").ariaSnapshot()}\n`, "utf8");
    }
  } finally {
    await context.close();
    if (isVideo && videoObj) {
      const srcVid = await videoObj.path();
      if (srcVid && fs.existsSync(srcVid)) fs.copyFileSync(srcVid, outAbs);
      fs.rmSync(videoTmp, { recursive: true, force: true });
    }
    await closeBrowser();
  }

  const ok =
    state.consoleErrors.length === 0 &&
    state.pageErrors.length === 0 &&
    state.http5xx.length === 0 &&
    state.brokenAssets.length === 0 &&
    state.axeViolations.length === 0;
  console.log(
    JSON.stringify({
      mode: opts.mode,
      out: path.relative(appDirAbs, outAbs),
      passed: ok,
      ...state,
    }),
  );
  if (!ok) process.exitCode = 1;
}

async function main() {
  const opts = parseCliArgs(process.argv.slice(2));
  if (!opts.baseUrl || !opts.evidenceDir) {
    throw new Error("--base-url and --evidence-dir are required");
  }
  const appDirAbs = path.resolve(opts.appDir);
  const evidenceAbs = path.isAbsolute(opts.evidenceDir)
    ? opts.evidenceDir
    : path.join(appDirAbs, opts.evidenceDir);
  fs.mkdirSync(evidenceAbs, { recursive: true });

  if (opts.mode === "drive") {
    await runDrive(opts, appDirAbs, evidenceAbs);
  } else if (opts.mode === "screenshot") {
    await runSingleCapture(opts, appDirAbs, evidenceAbs, false);
  } else if (opts.mode === "record") {
    await runSingleCapture(opts, appDirAbs, evidenceAbs, true);
  } else {
    throw new Error(`Unsupported mode: ${opts.mode}`);
  }
}

main().catch((err) => {
  console.error(err?.stack || String(err));
  process.exit(1);
});
