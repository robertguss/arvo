import { describe, expect, it } from "vitest";
import { formatCents, readCsrfToken } from "../lib/format";

describe("format utilities", () => {
  it("formats cents into dollar strings accurately", () => {
    expect(formatCents(0)).toBe("$0.00");
    expect(formatCents(14500)).toBe("$145.00");
    expect(formatCents(7599)).toBe("$75.99");
  });

  it("extracts and URI-decodes XSRF-TOKEN cookies safely", () => {
    expect(readCsrfToken("")).toBe("");
    expect(readCsrfToken("arvo_session=abc; other=1")).toBe("");
    expect(readCsrfToken("arvo_session=abc; XSRF-TOKEN=tok%2B1%2F2")).toBe("tok+1/2");
    expect(readCsrfToken("XSRF-TOKEN=plain-token; Path=/")).toBe("plain-token");
    expect(readCsrfToken("XSRF-TOKEN=%E0%A4%A")).toBe("%E0%A4%A");
  });
});
