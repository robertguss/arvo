import fs from "node:fs";
import path from "node:path";

export function loadMoFixture<T>(component: string, name: string): { component: string; props: T } {
  const candidates = [
    path.resolve(process.cwd(), "..", ".arvo", "fixtures", component, `${name}.json`),
    path.resolve(process.cwd(), "..", "..", "..", ".arvo", "fixtures", component, `${name}.json`),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return JSON.parse(fs.readFileSync(candidate, "utf8")) as { component: string; props: T };
    }
  }
  throw new Error(
    `Missing Mo Inertia fixture ${component}/${name}.json; run \`mo run main.mo --arvo-export-fixtures\`.`,
  );
}
