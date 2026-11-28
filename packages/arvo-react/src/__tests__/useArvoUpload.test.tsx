import { act, renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { useArvoUpload } from "../hooks/useArvoUpload";

describe("useArvoUpload", () => {
  it("uploads multipart form-data with X-XSRF-TOKEN and resets cleanly", async () => {
    const fetchFn = vi.fn(async () => {
      return new Response(JSON.stringify({ id: "up_1", filename: "receipt.png" }), {
        status: 201,
        headers: { "Content-Type": "application/json" },
      });
    }) as unknown as typeof fetch;

    const onSuccess = vi.fn();
    const { result } = renderHook(() =>
      useArvoUpload<{ id: string; filename: string }>({
        endpoint: "/bills/uploads",
        csrfToken: "xsrf_tok_123",
        acceptMimes: ["image/png"],
        maxBytes: 1024,
        fetchFn,
        onSuccess,
      }),
    );

    const file = new File(["pngbytes"], "receipt.png", { type: "image/png" });
    let uploaded: { id: string; filename: string } | null = null;
    await act(async () => {
      uploaded = await result.current.upload(file);
    });

    expect(uploaded).toEqual({ id: "up_1", filename: "receipt.png" });
    expect(result.current.status).toBe("uploaded");
    expect(result.current.progress).toBe(100);
    expect(onSuccess).toHaveBeenCalledWith({ id: "up_1", filename: "receipt.png" });
    expect(fetchFn).toHaveBeenCalledWith(
      "/bills/uploads",
      expect.objectContaining({
        method: "POST",
        headers: { "X-XSRF-TOKEN": "xsrf_tok_123" },
      }),
    );

    act(() => result.current.reset());
    expect(result.current.status).toBe("idle");
    expect(result.current.result).toBeNull();
  });

  it("blocks disallowed MIME types and oversized files before hitting network", async () => {
    const fetchFn = vi.fn() as unknown as typeof fetch;
    const { result } = renderHook(() =>
      useArvoUpload({
        acceptMimes: ["image/png"],
        maxBytes: 10,
        fetchFn,
      }),
    );

    await act(async () => {
      await result.current.upload(new File(["<svg/>"], "xss.svg", { type: "image/svg+xml" }));
    });
    expect(result.current.status).toBe("error");
    expect(result.current.error).toContain("not allowed");
    expect(fetchFn).not.toHaveBeenCalled();

    await act(async () => {
      await result.current.upload(new File(["012345678901"], "big.png", { type: "image/png" }));
    });
    expect(result.current.status).toBe("error");
    expect(result.current.error).toContain("exceeds maximum size");
    expect(fetchFn).not.toHaveBeenCalled();
  });

  it("executes 2-step presigned S3 PUT + confirm workflow", async () => {
    const calls: Array<{ url: string; method?: string }> = [];
    const fetchFn = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input);
      calls.push({ url, method: init?.method });
      if (url === "/uploads/presign") {
        return new Response(
          JSON.stringify({
            upload_id: "up_s3",
            storage_key: "docs/usr_1/up_s3.pdf",
            presigned: {
              method: "PUT",
              url: "https://bucket.example/docs/usr_1/up_s3.pdf?sig=1",
              required_headers: [["Content-Type", "application/pdf"]],
              expires_at: "2026-11-28T06:05:00Z",
            },
          }),
          { status: 200 },
        );
      }
      if (url.startsWith("https://bucket.example/")) {
        return new Response("", { status: 200 });
      }
      return new Response(JSON.stringify({ upload_id: "up_s3", status: "attached" }), {
        status: 200,
      });
    }) as unknown as typeof fetch;

    const { result } = renderHook(() =>
      useArvoUpload<{ upload_id: string; status: string }>({
        mode: "presigned",
        presignUrl: "/uploads/presign",
        confirmUrl: "/uploads/confirm",
        csrfToken: "tok",
        fetchFn,
      }),
    );

    await act(async () => {
      await result.current.upload(new File(["%PDF-1.7"], "bill.pdf", { type: "application/pdf" }));
    });

    expect(calls.map((c) => c.url)).toEqual([
      "/uploads/presign",
      "https://bucket.example/docs/usr_1/up_s3.pdf?sig=1",
      "/uploads/confirm",
    ]);
    expect(result.current.status).toBe("uploaded");
    expect(result.current.result).toEqual({ upload_id: "up_s3", status: "attached" });
  });
});
