import { useCallback, useState } from "react";

export type UploadMode = "multipart" | "presigned";

export type UploadStatus =
  | "idle"
  | "validating"
  | "presigning"
  | "uploading"
  | "confirming"
  | "uploaded"
  | "error";

export interface PresignedUrlPayload {
  method: string;
  url: string;
  required_headers: Array<[string, string]>;
  expires_at: string;
}

export interface PresignUploadResponse {
  upload_id: string;
  storage_key: string;
  content_type?: string;
  size_bytes?: number;
  presigned: PresignedUrlPayload;
}

export interface UseArvoUploadOptions<TResult = unknown> {
  mode?: UploadMode;
  endpoint?: string;
  presignUrl?: string;
  confirmUrl?: string;
  fieldName?: string;
  maxBytes?: number;
  acceptMimes?: string[];
  csrfToken?: string;
  extraFields?: Record<string, string>;
  fetchFn?: typeof fetch;
  onSuccess?: (result: TResult) => void;
  onError?: (message: string) => void;
}

export interface UseArvoUploadResult<TResult = unknown> {
  status: UploadStatus;
  progress: number;
  error: string | null;
  result: TResult | null;
  upload: (file: File) => Promise<TResult | null>;
  reset: () => void;
}

function readCookie(name: string): string | null {
  if (typeof document === "undefined" || !document.cookie) {
    return null;
  }
  const needle = `${name}=`;
  for (const part of document.cookie.split(";")) {
    const trimmed = part.trim();
    if (trimmed.startsWith(needle)) {
      try {
        return decodeURIComponent(trimmed.slice(needle.length));
      } catch {
        return trimmed.slice(needle.length);
      }
    }
  }
  return null;
}

async function parseErrorResponse(res: Response): Promise<string> {
  try {
    const text = await res.text();
    if (!text) return `Upload failed (HTTP ${res.status})`;
    try {
      const parsed = JSON.parse(text) as { error?: unknown; message?: unknown; reason?: unknown };
      const msg = parsed.error ?? parsed.message ?? parsed.reason;
      return typeof msg === "string" && msg.length > 0 ? msg : text;
    } catch {
      return text;
    }
  } catch {
    return `Upload failed (HTTP ${res.status})`;
  }
}

async function sha256HexIfAvailable(file: File): Promise<string | undefined> {
  if (typeof crypto === "undefined" || !crypto.subtle || typeof file.arrayBuffer !== "function") {
    return undefined;
  }
  try {
    const buf = await file.arrayBuffer();
    const digest = await crypto.subtle.digest("SHA-256", buf);
    const bytes = new Uint8Array(digest);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  } catch {
    return undefined;
  }
}

export function useArvoUpload<TResult = unknown>(
  options: UseArvoUploadOptions<TResult> = {},
): UseArvoUploadResult<TResult> {
  const {
    mode = "multipart",
    endpoint = "/uploads",
    presignUrl = "/uploads/presign",
    confirmUrl,
    fieldName = "file",
    maxBytes,
    acceptMimes,
    csrfToken,
    extraFields,
    fetchFn,
    onSuccess,
    onError,
  } = options;

  const [status, setStatus] = useState<UploadStatus>("idle");
  const [progress, setProgress] = useState<number>(0);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<TResult | null>(null);

  const reset = useCallback(() => {
    setStatus("idle");
    setProgress(0);
    setError(null);
    setResult(null);
  }, []);

  const failWith = useCallback(
    (msg: string): null => {
      setStatus("error");
      setError(msg);
      onError?.(msg);
      return null;
    },
    [onError],
  );

  const upload = useCallback(
    async (file: File): Promise<TResult | null> => {
      setError(null);
      setResult(null);
      setProgress(0);
      setStatus("validating");

      if (file.size <= 0) {
        return failWith("Selected file is empty.");
      }
      if (maxBytes !== undefined && file.size > maxBytes) {
        return failWith(`File exceeds maximum size of ${maxBytes} bytes.`);
      }
      if (acceptMimes && acceptMimes.length > 0) {
        const mime = (file.type || "application/octet-stream").toLowerCase();
        const allowed = acceptMimes.map((m) => m.toLowerCase());
        if (!allowed.includes(mime)) {
          return failWith(`File type '${mime}' is not allowed.`);
        }
      }

      const doFetch = fetchFn ?? globalThis.fetch;
      if (typeof doFetch !== "function") {
        return failWith("Fetch API is unavailable.");
      }

      const xsrf = csrfToken ?? readCookie("XSRF-TOKEN");
      const sameOriginHeaders: Record<string, string> = {};
      if (xsrf) {
        sameOriginHeaders["X-XSRF-TOKEN"] = xsrf;
      }

      try {
        if (mode === "multipart") {
          setStatus("uploading");
          setProgress(25);
          const formData = new FormData();
          formData.append(fieldName, file);
          if (extraFields) {
            for (const [k, v] of Object.entries(extraFields)) {
              formData.append(k, v);
            }
          }
          const res = await doFetch(endpoint, {
            method: "POST",
            credentials: "same-origin",
            headers: sameOriginHeaders,
            body: formData,
          });
          if (!res.ok) {
            return failWith(await parseErrorResponse(res));
          }
          const data = (await res.json()) as TResult;
          setProgress(100);
          setStatus("uploaded");
          setResult(data);
          onSuccess?.(data);
          return data;
        }

        // Presigned 2-step S3/R2/MinIO flow
        setStatus("presigning");
        setProgress(10);
        const sha256Hex = await sha256HexIfAvailable(file);
        const preRes = await doFetch(presignUrl, {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            ...sameOriginHeaders,
          },
          body: JSON.stringify({
            filename: file.name,
            content_type: file.type || "application/octet-stream",
            size_bytes: file.size,
            sha256_hex: sha256Hex ?? null,
          }),
        });
        if (!preRes.ok) {
          return failWith(await parseErrorResponse(preRes));
        }
        const preData = (await preRes.json()) as PresignUploadResponse;

        setStatus("uploading");
        setProgress(50);
        const putHeaders: Record<string, string> = {};
        for (const [k, v] of preData.presigned.required_headers ?? []) {
          putHeaders[k] = v;
        }
        const putRes = await doFetch(preData.presigned.url, {
          method: preData.presigned.method || "PUT",
          headers: putHeaders,
          body: file,
        });
        if (!putRes.ok) {
          return failWith(await parseErrorResponse(putRes));
        }

        let finalResult: TResult = preData as unknown as TResult;
        if (confirmUrl) {
          setStatus("confirming");
          setProgress(85);
          const confRes = await doFetch(confirmUrl, {
            method: "POST",
            credentials: "same-origin",
            headers: {
              "Content-Type": "application/json",
              ...sameOriginHeaders,
            },
            body: JSON.stringify({
              upload_id: preData.upload_id,
              storage_key: preData.storage_key,
            }),
          });
          if (!confRes.ok) {
            return failWith(await parseErrorResponse(confRes));
          }
          finalResult = (await confRes.json()) as TResult;
        }

        setProgress(100);
        setStatus("uploaded");
        setResult(finalResult);
        onSuccess?.(finalResult);
        return finalResult;
      } catch (err) {
        return failWith(err instanceof Error ? err.message : "Upload failed");
      }
    },
    [
      acceptMimes,
      confirmUrl,
      csrfToken,
      endpoint,
      extraFields,
      failWith,
      fetchFn,
      fieldName,
      maxBytes,
      mode,
      onSuccess,
      presignUrl,
    ],
  );

  return { status, progress, error, result, upload, reset };
}
