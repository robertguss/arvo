import { router } from "@inertiajs/react";
import { useCallback, useEffect, useRef, useState } from "react";

export type LiveConnectionStatus = "idle" | "connecting" | "open" | "error" | "closed";

export interface InertiaReloadSignal {
  kind?: string;
  only?: string[];
  reason?: string | null;
}

export interface LiveEventMessage {
  event: string;
  data: unknown;
  lastEventId: string;
}

export interface EventSourceLike {
  addEventListener: (type: string, listener: (ev: MessageEvent) => void) => void;
  removeEventListener?: (type: string, listener: (ev: MessageEvent) => void) => void;
  close: () => void;
  onopen: ((ev: Event) => void) | null;
  onerror: ((ev: Event) => void) | null;
}

export interface UseArvoLiveOptions {
  url?: string;
  enabled?: boolean;
  events?: string[];
  onReload?: (only: string[], reason?: string | null) => void;
  onEvent?: (msg: LiveEventMessage) => void;
  onError?: (err: Event) => void;
  eventSourceFactory?: (url: string) => EventSourceLike;
}

export interface UseArvoLiveResult {
  status: LiveConnectionStatus;
  lastEventId: string | null;
  lastEvent: LiveEventMessage | null;
  close: () => void;
}

function safeParseJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

export function useArvoLive(options: UseArvoLiveOptions = {}): UseArvoLiveResult {
  const {
    url = "/live",
    enabled = true,
    events = [],
    onReload,
    onEvent,
    onError,
    eventSourceFactory,
  } = options;

  const [status, setStatus] = useState<LiveConnectionStatus>(enabled ? "connecting" : "idle");
  const [lastEventId, setLastEventId] = useState<string | null>(null);
  const [lastEvent, setLastEvent] = useState<LiveEventMessage | null>(null);
  const sourceRef = useRef<EventSourceLike | null>(null);
  const onReloadRef = useRef(onReload);
  const onEventRef = useRef(onEvent);
  const onErrorRef = useRef(onError);
  const factoryRef = useRef(eventSourceFactory);
  onReloadRef.current = onReload;
  onEventRef.current = onEvent;
  onErrorRef.current = onError;
  factoryRef.current = eventSourceFactory;

  const eventsKey = events.join(",");

  const close = useCallback(() => {
    if (sourceRef.current) {
      sourceRef.current.close();
      sourceRef.current = null;
      setStatus("closed");
    }
  }, []);

  useEffect(() => {
    if (!enabled) {
      setStatus("idle");
      return;
    }
    const factory =
      factoryRef.current ??
      (typeof EventSource !== "undefined"
        ? (targetUrl: string) => new EventSource(targetUrl, { withCredentials: true })
        : null);
    if (!factory) {
      setStatus("idle");
      return;
    }

    setStatus("connecting");
    const es = factory(url);
    sourceRef.current = es;

    const handleConnected = (ev: MessageEvent) => {
      setStatus("open");
      if (ev.lastEventId) setLastEventId(ev.lastEventId);
      const msg: LiveEventMessage = {
        event: "live.connected",
        data: safeParseJson(String(ev.data ?? "{}")),
        lastEventId: ev.lastEventId ?? "",
      };
      setLastEvent(msg);
      onEventRef.current?.(msg);
    };

    const handleReload = (ev: MessageEvent) => {
      if (ev.lastEventId) setLastEventId(ev.lastEventId);
      const parsed = safeParseJson(String(ev.data ?? "{}")) as InertiaReloadSignal;
      const only = Array.isArray(parsed?.only)
        ? parsed.only.filter((k): k is string => typeof k === "string" && k.length > 0)
        : [];
      const reason = typeof parsed?.reason === "string" ? parsed.reason : null;
      const msg: LiveEventMessage = {
        event: "inertia.reload",
        data: parsed,
        lastEventId: ev.lastEventId ?? "",
      };
      setLastEvent(msg);
      onEventRef.current?.(msg);
      if (onReloadRef.current) {
        onReloadRef.current(only, reason);
      } else {
        router.reload({
          only: only.length > 0 ? only : undefined,
        });
      }
    };

    es.onopen = () => setStatus("open");
    es.onerror = (ev: Event) => {
      setStatus("error");
      onErrorRef.current?.(ev);
    };
    es.addEventListener("live.connected", handleConnected);
    es.addEventListener("inertia.reload", handleReload);

    const customHandlers: Array<[string, (ev: MessageEvent) => void]> = [];
    for (const evName of eventsKey.split(",").filter((s) => s.length > 0)) {
      if (evName === "live.connected" || evName === "inertia.reload") continue;
      const fn = (ev: MessageEvent) => {
        if (ev.lastEventId) setLastEventId(ev.lastEventId);
        const msg: LiveEventMessage = {
          event: evName,
          data: safeParseJson(String(ev.data ?? "")),
          lastEventId: ev.lastEventId ?? "",
        };
        setLastEvent(msg);
        onEventRef.current?.(msg);
      };
      customHandlers.push([evName, fn]);
      es.addEventListener(evName, fn);
    }

    return () => {
      es.removeEventListener?.("live.connected", handleConnected);
      es.removeEventListener?.("inertia.reload", handleReload);
      for (const [evName, fn] of customHandlers) {
        es.removeEventListener?.(evName, fn);
      }
      es.close();
      if (sourceRef.current === es) {
        sourceRef.current = null;
      }
    };
  }, [url, enabled, eventsKey]);

  return { status, lastEventId, lastEvent, close };
}
