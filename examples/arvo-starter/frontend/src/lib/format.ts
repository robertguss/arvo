export function formatCents(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

export function readCsrfToken(cookieHeader: string): string {
  for (const part of cookieHeader.split(";")) {
    const trimmed = part.trim();
    if (trimmed.startsWith("XSRF-TOKEN=")) {
      const raw = trimmed.slice("XSRF-TOKEN=".length);
      try {
        return decodeURIComponent(raw);
      } catch {
        return raw;
      }
    }
  }
  return "";
}
