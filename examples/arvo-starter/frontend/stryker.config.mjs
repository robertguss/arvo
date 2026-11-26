/** @type {import('@stryker-mutator/api/core').PartialStrykerOptions} */
export default {
  packageManager: "npm",
  testRunner: "vitest",
  vitest: {
    configFile: "vitest.config.ts",
  },
  mutate: [
    "src/**/*.{ts,tsx}",
    "!src/arvo.gen.ts",
    "!src/main.tsx",
    "!src/vite-env.d.ts",
    "!src/**/__tests__/**",
    "!src/**/*.test.{ts,tsx}",
  ],
  reporters: ["clear-text", "json"],
  jsonReporter: {
    fileName: "../.arvo/evidence/stryker-report.json",
  },
  thresholds: {
    high: 90,
    low: 85,
    break: 85,
  },
  concurrency: 2,
  coverageAnalysis: "perTest",
  tempDirName: ".stryker-tmp",
  cleanTempDir: true,
};
