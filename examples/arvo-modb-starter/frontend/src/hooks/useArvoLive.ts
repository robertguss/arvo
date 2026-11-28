import { router } from "@inertiajs/react";
import { useEffect, useState } from "react";

export function useArvoLive(url = "/live", enabled = true) {
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    if (!enabled || typeof EventSource === "undefined") return;
    const es = new EventSource(url, { withCredentials: true });
    es.addEventListener("live.connected", () => setConnected(true));
    es.addEventListener("inertia.reload", (ev: MessageEvent) => {
      try {
        const parsed = JSON.parse(String(ev.data)) as { only?: string[] };
        router.reload({
          only: Array.isArray(parsed.only) && parsed.only.length > 0 ? parsed.only : undefined,
        });
      } catch {
        router.reload();
      }
    });
    es.onerror = () => setConnected(false);
    return () => es.close();
  }, [url, enabled]);

  return { connected };
}
