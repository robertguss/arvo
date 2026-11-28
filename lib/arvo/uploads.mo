## Storage-agnostic bounded file upload pipeline: magic-byte MIME sniffing,
## active HTML/XSS & SVG rejection, per-owner quotas, confined local storage,
## safe download headers, and AWS SigV4 presigned S3/R2/MinIO uploads.
module Arvo.Uploads
expose UploadError(..),
UploadPolicy(..),
UploadRecord(..),
ValidatedUpload(..),
PresignedUpload(..),
to_text,
format_utc_iso,
default_policy,
image_policy,
document_policy,
validate_policy,
sniff_mime,
mime_extension,
sanitize_filename,
build_storage_key,
validate_bytes,
validate_uploaded_file,
prepare_local_record,
store_local,
read_local,
delete_local,
download_response,
prepare_s3_upload,
presign_s3_download
use Api
use Arvo.Form
use Arvo.Id
use Arvo.S3
use Crypto

max_presign_seconds = 604800

## Errors returned by upload validation, quota enforcement, local disk I/O, or S3 presigning.
enum UploadError
  EmptyFile
  FileTooLarge(size: Int, max_bytes: Int)
  QuotaExceeded(used_bytes: Int, incoming_bytes: Int, quota_bytes: Int)
  DisallowedMime(detected: Text)
  UnsupportedSignature
  DangerousContent(reason: Text)
  InvalidKey(reason: Text)
  InvalidPolicy(reason: Text)
  StorageFailed(reason: Text)
  S3Failed(S3.S3Error)
end

## Formats an `UploadError` as a human-readable diagnostic.
fn to_text(err: UploadError) : Text
  case err
    EmptyFile: "uploaded file is empty"
    FileTooLarge(size: s, max_bytes: m): "file size #{s} bytes exceeds limit #{m} bytes"
    QuotaExceeded(used_bytes: u, incoming_bytes: inc, quota_bytes: q): "quota exceeded (#{u} used + #{inc} incoming > #{q} limit bytes)"
    DisallowedMime(detected: m): "MIME type '#{m}' is not allowed"
    UnsupportedSignature: "unrecognized binary file signature"
    DangerousContent(reason: r): "blocked dangerous upload content: #{r}"
    InvalidKey(reason: r): "invalid upload key or path: #{r}"
    InvalidPolicy(reason: r): "invalid upload policy: #{r}"
    StorageFailed(reason: r): "upload storage failed: #{r}"
    S3Failed(e): S3.to_text(e)
  end
end

## Declarative upload constraints governing size limits, MIME allowlist, quotas, and active-content blocks.
struct UploadPolicy
  max_bytes: Int
  allowed_mimes: List(Text)
  max_owner_bytes: Option(Int)
  allow_svg?: Bool
  allow_html?: Bool
  presign_expires_seconds: Int
end

## Canonical database-independent upload metadata record persisted across persistence adapters.
struct UploadRecord
  id: Text
  owner_id: Text
  storage_backend: Text
  storage_key: Text
  original_filename: Text
  content_type: Text
  size_bytes: Int
  sha256_hex: Text
  status: Text
  created_at: Text
  attached_at: Option(Text)
  expires_at: Option(Text)
end

## Verified byte payload with sniffed MIME type, canonical filename, and SHA-256 digest.
struct ValidatedUpload
  original_filename: Text
  safe_filename: Text
  content_type: Text
  extension: Text
  size_bytes: Int
  sha256_hex: Text
  data: Bytes
end

## Server-issued direct-to-object-storage presigned upload instructions paired with upload ID.
struct PresignedUpload
  upload_id: Text
  storage_key: Text
  content_type: Text
  size_bytes: Int
  presigned: S3.PresignedUrl
end

## Formats `Time` as fixed-width 27-byte UTC RFC 3339 (`YYYY-MM-DDTHH:MM:SS.ffffffZ`).
fn format_utc_iso(t: Time) : Text
  raw = t.to_text
  base = raw.drop_suffix("Z") or raw
  parts = base.split(".")
  return "#{base}.000000Z" if parts.size == 1
  whole = parts.first or base
  frac = parts.get(1) or ""
  zeros = if frac.byte_count < 6: "0".repeat(6 - frac.byte_count) else: ""
  "#{whole}.#{frac}#{zeros}Z"
end

## Safe general-purpose upload policy (10 MiB max, images + PDF + UTF-8 text/CSV, no HTML or SVG).
fn default_policy() : UploadPolicy
  UploadPolicy(
    max_bytes: 10485760,
    allowed_mimes: [
      "image/png",
      "image/jpeg",
      "image/gif",
      "image/webp",
      "application/pdf",
      "text/plain",
      "text/csv"
    ],
    max_owner_bytes: None,
    allow_svg?: false,
    allow_html?: false,
    presign_expires_seconds: 300
  )
end

## Raster image upload policy (10 MiB max, PNG/JPEG/GIF/WebP only, active SVG/HTML forbidden).
fn image_policy() : UploadPolicy
  UploadPolicy(
    max_bytes: 10485760,
    allowed_mimes: ["image/png", "image/jpeg", "image/gif", "image/webp"],
    max_owner_bytes: None,
    allow_svg?: false,
    allow_html?: false,
    presign_expires_seconds: 300
  )
end

## Document & receipt upload policy (25 MiB max, PDF + raster images + CSV/plain text).
fn document_policy() : UploadPolicy
  UploadPolicy(
    max_bytes: 26214400,
    allowed_mimes: [
      "application/pdf",
      "image/png",
      "image/jpeg",
      "image/gif",
      "image/webp",
      "text/csv",
      "text/plain"
    ],
    max_owner_bytes: None,
    allow_svg?: false,
    allow_html?: false,
    presign_expires_seconds: 300
  )
end

## Validates policy limits and per-owner quota bounds.
fn validate_policy(policy: UploadPolicy) : Result(Unit, UploadError)
  if policy.max_bytes <= 0
    return Error(InvalidPolicy(reason: "max_bytes must be positive"))
  end
  if policy.presign_expires_seconds < 1 or policy.presign_expires_seconds > max_presign_seconds
    return Error(
      InvalidPolicy(reason: "presign_expires_seconds must be between 1 and #{max_presign_seconds}")
    )
  end
  if policy.max_owner_bytes is Some(q) and q < 0
    return Error(InvalidPolicy(reason: "max_owner_bytes cannot be negative"))
  end
  Ok(Unit)
end

fn hex_bytes(hex: Text) : Bytes
  Bytes.from_hex(hex) or "".bytes
end

fn starts_with_bytes?(data: Bytes, prefix: Bytes) : Bool
  data.size >= prefix.size and data.slice(0, prefix.size) == prefix
end

fn control_or_nl?(raw: Text) : Bool
  for b in raw.bytes.to_list
    n = b.to_int
    return true if n < 32 or n == 127
  end
  false
end

fn has_ascii_ws?(raw: Text) : Bool
  for ch in raw.chars
    return true if ch.ascii_white_space?
  end
  false
end

## Detects MIME type strictly from payload magic bytes (falling back to safe UTF-8 text heuristics).
## Never trusts client-supplied `Content-Type` headers.
fn sniff_mime(data: Bytes, filename: Text) : Result(Text, UploadError)
  return Error(EmptyFile) if data.size == 0

  # Raster images: PNG, JPEG, GIF87a/GIF89a, RIFF..WEBP
  return Ok("image/png") if starts_with_bytes?(data, hex_bytes("89504E470D0A1A0A"))
  return Ok("image/jpeg") if starts_with_bytes?(data, hex_bytes("FFD8FF"))
  if starts_with_bytes?(data, "GIF87a".bytes) or starts_with_bytes?(data, "GIF89a".bytes)
    return Ok("image/gif")
  end
  if data.size >= 12 and data.slice(0, 4) == "RIFF".bytes and data.slice(8, 12) == "WEBP".bytes
    return Ok("image/webp")
  end

  # Documents & archives: PDF, ZIP
  return Ok("application/pdf") if starts_with_bytes?(data, "%PDF-".bytes)
  if starts_with_bytes?(data, hex_bytes("504B0304")) or
    starts_with_bytes?(data, hex_bytes("504B0506")) or
    starts_with_bytes?(data, hex_bytes("504B0708"))
    return Ok("application/zip")
  end

  # UTF-8 text inspection: actively flag HTML/script & SVG payloads regardless of file extension
  case data.decode_utf8
    None: Error(UnsupportedSignature)
    Some(txt):
      no_bom = txt.drop_prefix("\u{FEFF}") or txt
      return Error(DangerousContent(reason: "NUL byte inside UTF-8 upload")) if no_bom.contains?(
        "\u{0}"
      )
      lower_trimmed = no_bom.trim.ascii_lowercase
      head = if lower_trimmed.char_count > 512
        Text.from_chars(lower_trimmed.chars.take(512))
      else
        lower_trimmed
      end
      if head.starts_with?("<!doctype html") or
        head.starts_with?("<html") or
        head.starts_with?("<script") or
        head.starts_with?("<iframe") or
        head.starts_with?("<object") or
        head.starts_with?("<embed") or
        lower_trimmed.contains?("<script") or
        lower_trimmed.contains?("<html")
        return Ok("text/html")
      end
      if head.starts_with?("<svg") or (
        head.starts_with?("<?xml") and lower_trimmed.contains?("<svg")
      )
        return Ok("image/svg+xml")
      end
      if filename.trim.ascii_lowercase.ends_with?(".csv")
        Ok("text/csv")
      else
        Ok("text/plain")
      end
  end
end

## Returns canonical lowercase file extension for recognized MIME types (`"bin"` fallback).
fn mime_extension(mime: Text) : Text
  examples
    mime_extension("image/png") == "png"
    mime_extension("image/jpeg") == "jpg"
    mime_extension("application/pdf") == "pdf"
    mime_extension("text/csv") == "csv"
    mime_extension("application/octet-stream") == "bin"
  end

  m = mime.trim.ascii_lowercase
  if m == "image/png"
    "png"
  else if m == "image/jpeg"
    "jpg"
  else if m == "image/gif"
    "gif"
  else if m == "image/webp"
    "webp"
  else if m == "image/svg+xml"
    "svg"
  else if m == "application/pdf"
    "pdf"
  else if m == "application/zip"
    "zip"
  else if m == "text/csv"
    "csv"
  else if m == "text/plain"
    "txt"
  else if m == "text/html"
    "html"
  else
    "bin"
  end
end

fn filename_safe_char?(ch: Char) : Bool
  (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or
    ch == '.' or
    ch == '-' or
    ch == '_'
end

## Sanitizes an arbitrary client filename by stripping directories, traversal dots, and unsafe chars.
fn sanitize_filename(raw: Text) : Text
  examples
    sanitize_filename("../../etc/passwd") == "passwd"
    sanitize_filename("C:\\Users\\Ada\\my \"receipt\" (1).pdf") == "my__receipt___1_.pdf"
    sanitize_filename("..\\.hidden") == "hidden"
    sanitize_filename("   ") == "upload"
  end

  promise "sanitized filename contains no slashes, quotes, control chars, or empty result"
    not result.empty? and
      not result.contains?("/") and
      not result.contains?("\\") and
      not result.contains?("\"") and
      not result.starts_with?(".")
  end

  norm_sep = raw.trim.replace("\\", "/")
  base = norm_sep.split("/").last or ""
  var chars = []
  for ch in base.chars
    chars = chars.append(if filename_safe_char?(ch): ch else: '_')
  end
  var cleaned = Text.from_chars(chars)
  while cleaned.starts_with?(".")
    cleaned = cleaned.drop_prefix(".") or ""
  end
  trimmed = if cleaned.char_count > 120: Text.from_chars(cleaned.chars.take(120)) else: cleaned
  if trimmed.empty? or trimmed == "." or trimmed == ".."
    "upload"
  else
    trimmed
  end
end

fn validate_segment(label: Text, seg: Text) : Result(Text, UploadError)
  t = seg.trim
  if t.empty? or
    t == "." or
    t == ".." or
    t.contains?("/") or
    t.contains?("\\") or
    has_ascii_ws?(t) or
    control_or_nl?(t)
    return Error(InvalidKey(reason: "invalid #{label} segment '#{seg}'"))
  end
  Ok(t)
end

## Builds a safe normalized object/storage key (`[prefix/]<owner_id>/<upload_id>.<ext>`).
fn build_storage_key(prefix: Text, owner_id: Text, upload_id: Text, mime: Text) : Result(
  Text,
  UploadError
)
  clean_owner = try validate_segment("owner_id", owner_id)
  clean_id = try validate_segment("upload_id", upload_id)
  ext = mime_extension(mime)
  trimmed_prefix = prefix.trim
  raw_key = if trimmed_prefix.empty?
    "#{clean_owner}/#{clean_id}.#{ext}"
  else
    "#{trimmed_prefix}/#{clean_owner}/#{clean_id}.#{ext}"
  end
  S3.sanitize_object_key(raw_key).map_error(fn(e) S3Failed(e) end)
end

fn enforce_mime_and_quota(
  detected_mime: Text,
  incoming_size: Int,
  policy: UploadPolicy,
  owner_used_bytes: Int
) : Result(Text, UploadError)
  _ = try validate_policy(policy)
  return Error(InvalidPolicy(reason: "owner_used_bytes cannot be negative")) if owner_used_bytes < 0
  return Error(EmptyFile) if incoming_size <= 0
  if incoming_size > policy.max_bytes
    return Error(FileTooLarge(size: incoming_size, max_bytes: policy.max_bytes))
  end
  if policy.max_owner_bytes is Some(quota) and owner_used_bytes + incoming_size > quota
    return Error(
      QuotaExceeded(used_bytes: owner_used_bytes, incoming_bytes: incoming_size, quota_bytes: quota)
    )
  end

  norm = detected_mime.trim.ascii_lowercase
  if norm == "text/html" and not policy.allow_html?
    return Error(DangerousContent(reason: "HTML/script uploads are blocked by policy"))
  end
  if norm == "image/svg+xml" and not policy.allow_svg?
    return Error(DangerousContent(reason: "SVG uploads are blocked by policy"))
  end
  allowed = policy.allowed_mimes.map(fn(m) m.trim.ascii_lowercase end)
  return Error(DisallowedMime(detected: norm)) if not allowed.contains?(norm)
  Ok(norm)
end

fn valid_validated_upload?(policy: UploadPolicy, res: Result(ValidatedUpload, UploadError)) : Bool
  case res
    Ok(v): v.size_bytes > 0 and
      v.size_bytes <= policy.max_bytes and
      v.sha256_hex.byte_count == 64 and (policy.allow_html? or v.content_type != "text/html") and (
        policy.allow_svg? or v.content_type != "image/svg+xml"
      )
    Error(_): true
  end
end

## Validates raw uploaded bytes against size limits, per-owner quota, magic-byte sniffing, and XSS blocks.
fn validate_bytes(filename: Text, data: Bytes, policy: UploadPolicy, owner_used_bytes: Int) : Result(
  ValidatedUpload,
  UploadError
)
  promise "validated upload satisfies size limit, SHA-256 hex digest, and HTML/SVG blocklist"
    valid_validated_upload?(policy, result)
  end

  _ = try validate_policy(policy)
  return Error(InvalidPolicy(reason: "owner_used_bytes cannot be negative")) if owner_used_bytes < 0
  return Error(EmptyFile) if data.size == 0
  if data.size > policy.max_bytes
    return Error(FileTooLarge(size: data.size, max_bytes: policy.max_bytes))
  end
  if policy.max_owner_bytes is Some(quota) and owner_used_bytes + data.size > quota
    return Error(
      QuotaExceeded(used_bytes: owner_used_bytes, incoming_bytes: data.size, quota_bytes: quota)
    )
  end

  detected = try sniff_mime(data, filename)
  norm = try enforce_mime_and_quota(detected, data.size, policy, owner_used_bytes)
  safe_name = sanitize_filename(filename)
  ext = mime_extension(norm)
  digest = Crypto.sha256(data).to_hex
  Ok(
    ValidatedUpload(
      original_filename: safe_name,
      safe_filename: safe_name,
      content_type: norm,
      extension: ext,
      size_bytes: data.size,
      sha256_hex: digest,
      data: data
    )
  )
end

## Validates an `Arvo.Form.UploadedFile` parsed from `multipart/form-data`.
fn validate_uploaded_file(file: Form.UploadedFile, policy: UploadPolicy, owner_used_bytes: Int) : Result(
  ValidatedUpload,
  UploadError
)
  validate_bytes(file.filename, file.data, policy, owner_used_bytes)
end

## Builds an `'attached'` `UploadRecord` from a `ValidatedUpload` with normalized UTC timestamps.
fn prepare_local_record(
  owner_id: Text,
  prefix: Text,
  validated: ValidatedUpload,
  rng: SecureRandom,
  clock: Clock
) : Result(UploadRecord, UploadError)
  uid = Id.ulid(rng, clock)
  key = try build_storage_key(prefix, owner_id, uid, validated.content_type)
  now_iso = format_utc_iso(clock.now)
  Ok(
    UploadRecord(
      id: uid,
      owner_id: owner_id,
      storage_backend: "local",
      storage_key: key,
      original_filename: validated.original_filename,
      content_type: validated.content_type,
      size_bytes: validated.size_bytes,
      sha256_hex: validated.sha256_hex,
      status: "attached",
      created_at: now_iso,
      attached_at: Some(now_iso),
      expires_at: None
    )
  )
end

fn sanitize_local_base(raw: Text) : Result(Text, UploadError)
  t = raw.trim
  if control_or_nl?(t) or t.contains?("\\") or t.starts_with?("/")
    return Error(InvalidKey(reason: "base_dir must be a safe relative directory path"))
  end
  var cur = t
  while cur.ends_with?("/")
    cur = cur.drop_suffix("/") or ""
  end
  if cur.empty? or cur == "." or cur == ".."
    return Error(InvalidKey(reason: "base_dir cannot be empty or '.'/'..'"))
  end
  for seg in cur.split("/")
    if seg.empty? or seg == "." or seg == ".."
      return Error(InvalidKey(reason: "invalid base_dir segment '#{seg}'"))
    end
  end
  Ok(cur)
end

fn resolve_local_path(base_dir: Text, storage_key: Text) : Result((Text, List(Text)), UploadError)
  clean_base = try sanitize_local_base(base_dir)
  clean_key = try S3.sanitize_object_key(storage_key).map_error(fn(e) S3Failed(e) end)
  full_path = "#{clean_base}/#{clean_key}"
  base_segs = clean_base.split("/")
  key_segs = clean_key.split("/")
  parent_segs = if key_segs.size > 1
    base_segs.concat(key_segs.take(key_segs.size - 1))
  else
    base_segs
  end
  Ok((full_path, parent_segs))
end

## Writes `data` to confined local disk storage beneath relative `base_dir`, creating parent dirs.
fn store_local(files: Files, base_dir: Text, storage_key: Text, data: Bytes) : Result(
  Text,
  UploadError
)
  (full_path, parent_segs) = try resolve_local_path(base_dir, storage_key)
  var cur = ""
  for seg in parent_segs
    cur = if cur.empty?: seg else: "#{cur}/#{seg}"
    if not files.exists?(cur)
      _mk = try files.make_folder(cur).map_error(fn(e) StorageFailed(reason: e.to_text) end)
    end
  end
  _wr = try files.write_bytes(full_path, data).map_error(fn(e) StorageFailed(reason: e.to_text) end)
  Ok(full_path)
end

## Reads an uploaded blob strictly via `ReadFiles` from confined `base_dir`.
fn read_local(rf: ReadFiles, base_dir: Text, storage_key: Text) : Result(Bytes, UploadError)
  (full_path, _parents) = try resolve_local_path(base_dir, storage_key)
  rf.read_bytes(full_path).map_error(fn(e) StorageFailed(reason: e.to_text) end)
end

## Deletes a local blob if present beneath `base_dir`, returning whether a file was removed.
fn delete_local(files: Files, base_dir: Text, storage_key: Text) : Result(Bool, UploadError)
  (full_path, _parents) = try resolve_local_path(base_dir, storage_key)
  return Ok(false) if not files.exists?(full_path)
  _rm = try files.remove(full_path).map_error(fn(e) StorageFailed(reason: e.to_text) end)
  Ok(true)
end

fn safe_inline_mime?(mime: Text) : Bool
  m = mime.trim.ascii_lowercase
  m == "image/png" or
    m == "image/jpeg" or
    m == "image/gif" or
    m == "image/webp" or
    m == "application/pdf" or
    m == "text/plain"
end

## Builds a hardened binary download `Api.Response` with `nosniff`, sandbox CSP, and safe Content-Disposition.
fn download_response(record: UploadRecord, data: Bytes, inline?: Bool) : Api.Response
  safe_name = sanitize_filename(record.original_filename)
  disp_mode = if inline? and safe_inline_mime?(record.content_type)
    "inline"
  else
    "attachment"
  end
  Api.response(
    200,
    [
      ("Content-Type", record.content_type),
      ("Content-Length", data.size.to_text),
      ("Content-Disposition", "#{disp_mode}; filename=\"#{safe_name}\""),
      ("X-Content-Type-Options", "nosniff"),
      ("Content-Security-Policy", "default-src 'none'; sandbox"),
      ("Cache-Control", "private, max-age=3600")
    ],
    data
  )
end

## Prepares a pending `UploadRecord` plus AWS SigV4 presigned `PUT` URL binding type, length, and optional SHA-256.
fn prepare_s3_upload(
  cfg: S3.S3Config,
  policy: UploadPolicy,
  owner_id: Text,
  owner_used_bytes: Int,
  filename: Text,
  declared_mime: Text,
  size_bytes: Int,
  sha256_hex: Option(Text),
  prefix: Text,
  rng: SecureRandom,
  clock: Clock
) : Result((UploadRecord, PresignedUpload), UploadError)
  norm_mime = try enforce_mime_and_quota(declared_mime, size_bytes, policy, owner_used_bytes)
  uid = Id.ulid(rng, clock)
  key = try build_storage_key(prefix, owner_id, uid, norm_mime)
  safe_name = sanitize_filename(filename)

  clean_sha = case sha256_hex
    Some(h):
      decoded = try Bytes.from_hex(h.trim).or_fail(InvalidKey(reason: "sha256_hex must be hex"))
      if decoded.size != 32
        return Error(InvalidKey(reason: "sha256_hex must decode to 32 bytes"))
      end
      Some(decoded.to_hex)
    None: None
  end

  put_opts = S3.PresignPutOptions(
    expires_seconds: policy.presign_expires_seconds,
    content_type: Some(norm_mime),
    content_length: Some(size_bytes),
    sha256_hex: clean_sha
  )
  presigned = try S3.presign_put(cfg, key, put_opts, clock.now).map_error(fn(e) S3Failed(e) end)
  now_iso = format_utc_iso(clock.now)
  exp_iso = format_utc_iso(presigned.expires_at)
  rec = UploadRecord(
    id: uid,
    owner_id: owner_id,
    storage_backend: "s3",
    storage_key: key,
    original_filename: safe_name,
    content_type: norm_mime,
    size_bytes: size_bytes,
    sha256_hex: clean_sha or "",
    status: "pending",
    created_at: now_iso,
    attached_at: None,
    expires_at: Some(exp_iso)
  )
  Ok((
    rec,
    PresignedUpload(
      upload_id: uid,
      storage_key: key,
      content_type: norm_mime,
      size_bytes: size_bytes,
      presigned: presigned
    )
  ))
end

## Generates an AWS SigV4 presigned `GET` URL forcing `attachment` disposition for non-inline MIME types.
fn presign_s3_download(
  cfg: S3.S3Config,
  record: UploadRecord,
  expires_seconds: Int,
  inline?: Bool,
  clock: Clock
) : Result(S3.PresignedUrl, UploadError)
  safe_name = sanitize_filename(record.original_filename)
  disp_mode = if inline? and safe_inline_mime?(record.content_type)
    "inline"
  else
    "attachment"
  end
  opts = S3.PresignGetOptions(
    expires_seconds: expires_seconds,
    response_content_disposition: Some("#{disp_mode}; filename=\"#{safe_name}\""),
    response_content_type: Some(record.content_type)
  )
  S3.presign_get(cfg, record.storage_key, opts, clock.now).map_error(fn(e) S3Failed(e) end)
end

test "Arvo.Uploads sniffs magic bytes, blocks disguised XSS/SVG, enforces quotas, and stores/serves files safely"
  # 1. Magic-byte sniffing ignores deceptive client filename extensions
  png_bytes = Bytes.from_hex("89504E470D0A1A0A0000000D49484452") or stop "png"
  jpg_bytes = Bytes.from_hex("FFD8FFE000104A464946") or stop "jpg"
  gif_bytes = "GIF89a\u{1}\u{0}".bytes
  webp_bytes = "RIFF\u{1}\u{0}\u{0}\u{0}WEBPVP8 ".bytes
  pdf_bytes = "%PDF-1.7\n1 0 obj".bytes

  assert sniff_mime(png_bytes, "evil.exe") == Ok("image/png")
  assert sniff_mime(jpg_bytes, "photo.txt") == Ok("image/jpeg")
  assert sniff_mime(gif_bytes, "anim.bin") == Ok("image/gif")
  assert sniff_mime(webp_bytes, "img.webp") == Ok("image/webp")
  assert sniff_mime(pdf_bytes, "receipt.dat") == Ok("application/pdf")
  assert sniff_mime("col1,col2\n1,2\n".bytes, "export.CSV") == Ok("text/csv")
  assert sniff_mime("hello world".bytes, "note.txt") == Ok("text/plain")
  assert sniff_mime(Bytes.from_hex("DEADBEEF") or stop "bin", "bad.png") ==
    Error(UnsupportedSignature)

  # 2. Active HTML/script & SVG payloads blocked even if uploaded as .png or .txt
  html_bomb = "  <html><script>alert(1)</script></html>".bytes
  svg_bomb = "<?xml version=\"1.0\"?><svg onload=\"alert(1)\"></svg>".bytes
  assert validate_bytes("avatar.png", html_bomb, image_policy(), 0) is
    Error(DangerousContent(reason: _))
  assert validate_bytes("avatar.png", svg_bomb, image_policy(), 0) is
    Error(DangerousContent(reason: _))
  assert validate_bytes("notes.txt", html_bomb, default_policy(), 0) is
    Error(DangerousContent(reason: _))

  # 3. Quota & size limits
  var qpol = image_policy()
  qpol.max_bytes = 32
  qpol.max_owner_bytes = Some(40)
  assert validate_bytes("big.png", "0123456789".repeat(4).bytes, qpol, 0) is
    Error(FileTooLarge(size: 40, max_bytes: 32))
  assert validate_bytes("ok.png", png_bytes, qpol, 30) ==
    Error(QuotaExceeded(used_bytes: 30, incoming_bytes: png_bytes.size, quota_bytes: 40))

  # 4. End-to-end validation -> confined local storage -> ReadFiles read -> hardened download_response
  uploaded = Form.UploadedFile(
    field_name: "receipt",
    filename: "../../receipt \"#1\".png",
    content_type: "text/html",
    data: png_bytes
  )
  val = case validate_uploaded_file(uploaded, image_policy(), 0)
    Ok(v): v
    Error(_): stop "expected valid png upload"
  end
  assert val.content_type == "image/png"
  assert val.extension == "png"
  assert val.safe_filename == "receipt___1_.png"
  assert val.sha256_hex == Crypto.sha256(png_bytes).to_hex

  rng = SecureRandom.seeded(707)
  t0 = Time.parse("2026-11-28T04:00:00Z") or stop "t0"
  clk = Clock.fixed(t0)
  files = Files.in_memory({})

  rec = case prepare_local_record("mem_ada", "receipts", val, rng, clk)
    Ok(r): r
    Error(_): stop "expected local upload record"
  end
  assert rec.status == "attached" and rec.storage_key.starts_with?("receipts/mem_ada/")
  assert rec.storage_key.ends_with?(".png")

  assert store_local(files, ".arvo/uploads", rec.storage_key, val.data) is Ok(stored_path)
  assert stored_path == ".arvo/uploads/#{rec.storage_key}"
  assert read_local(files.read_only, ".arvo/uploads", rec.storage_key) == Ok(png_bytes)

  # Traversal blocked cleanly
  assert store_local(files, "../escape", rec.storage_key, png_bytes) is Error(InvalidKey(reason: _))
  assert store_local(files, ".arvo/uploads", "../secret.png", png_bytes) is Error(S3Failed(_))

  dl_inline = download_response(rec, png_bytes, true)
  assert dl_inline.status == 200
  assert dl_inline.header("X-Content-Type-Options") == Some("nosniff")
  assert dl_inline.header("Content-Security-Policy") == Some("default-src 'none'; sandbox")
  assert dl_inline.header("Content-Disposition") == Some("inline; filename=\"receipt___1_.png\"")

  # 5. S3 SigV4 presigned PUT + GET round-trip (rejecting SVG when disallowed)
  s3_cfg = S3.S3Config(
    endpoint: "https://s3.us-east-1.amazonaws.com",
    region: "us-east-1",
    bucket: "arvo-uploads",
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: None,
    path_style?: false
  )
  assert prepare_s3_upload(
    s3_cfg,
    image_policy(),
    "mem_ada",
    0,
    "xss.svg",
    "image/svg+xml",
    120,
    None,
    "avatars",
    rng,
    clk
  ) is
    Error(DangerousContent(reason: _))

  (s3_rec, pre) = case prepare_s3_upload(
    s3_cfg,
    document_policy(),
    "mem_ada",
    0,
    "bill.pdf",
    "application/pdf",
    2048,
    Some(Crypto.sha256(pdf_bytes).to_hex),
    "docs",
    rng,
    clk
  )
    Ok(pair): pair
    Error(_): stop "expected s3 presign"
  end
  assert s3_rec.status == "pending" and s3_rec.expires_at != None
  assert pre.presigned.method == "PUT"
  assert pre.presigned.url.contains?("X-Amz-Signature=")
  assert presign_s3_download(s3_cfg, s3_rec, 120, false, clk) is Ok(dl_s3)
  assert dl_s3.method == "GET" and dl_s3.url.contains?("response-content-disposition=attachment")

  # Delete local file idempotently
  assert delete_local(files, ".arvo/uploads", rec.storage_key) == Ok(true)
  assert delete_local(files, ".arvo/uploads", rec.storage_key) == Ok(false)
end
