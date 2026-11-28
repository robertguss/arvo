import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { type EventSourceLike, useArvoLive } from "../hooks/useArvoLive";

vi.mock("@inertiajs/react", () => ({
  router: {
    reload: vi.fn(),
  },
}));

class FakeEventSource implements EventSourceLike {
  listeners = new Map<string, Array<(ev: MessageEvent) => void>>();
  closed = false;
  onopen: ((ev: Event) => void) | null = null;
  onerror: ((ev: Event) => void) | null = null;

  addEventListener(type: string, listener: (ev: MessageEvent) => void): void {
    const prev = this.listeners.get(type) ?? [];
    this.listeners.set(type, [...prev, listener]);
  }

  removeEventListener(type: string, listener: (ev: MessageEvent) => void): void {
    const prev = this.listeners.get(type) ?? [];
    this.listeners.set(
      type,
      prev.filter((fn) => fn !== listener),
    );
  }

  emit(type: string, data: unknown, lastEventId = ""): void {
    const ev = { data: JSON.stringify(data), lastEventId } as MessageEvent;
    for (const fn of this.listeners.get(type) ?? []) {
      fn(ev);
    }
  }

  close(): void {
    this.closed = true;
  }
}

describe("useArvoLive", () => {
  it("subscribes to live.connected, inertia.reload, custom events, and closes on unmount", () => {
    const fake = new FakeEventSource();
    const onReload = vi.fn();
    const onEvent = vi.fn();

    const { result, unmount } = renderHook(() =>
      useArvoLive({
        url: "/live",
        events: ["bill.paid"],
        onReload,
        onEvent,
        eventSourceFactory: () => fake,
      }),
    );

    expect(result.current.status).toBe("connecting");
    act(() => {
      fake.emit("live.connected", { topics: ["org:o1"] }, "41");
    });
    expect(result.current.status).toBe("open");
    expect(result.current.lastEventId).toBe("41");

    act(() => {
      fake.emit("inertia.reload", { kind: "inertia.reload", only: ["bills"], reason: "bill.paid" }, "42");
    });
    expect(onReload).toHaveBeenCalledWith(["bills"], "bill.paid");
    expect(result.current.lastEventId).toBe("42");

    act(() => {
      fake.emit("bill.paid", { id: 9 }, "43");
    });
    expect(onEvent).toHaveBeenCalledWith(
      expect.objectContaining({ event: "bill.paid", data: { id: 9 }, lastEventId: "43" }),
    );

    unmount();
    expect(fake.closed).toBe(true);
  });
});
