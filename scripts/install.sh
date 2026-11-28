#!/usr/bin/env sh
# Standalone installer and updater for the Mo, MoDB, and Arvo toolchain (and optional Dana).
# Works without Homebrew on x86_64 Linux and Apple Silicon macOS.
set -eu

PREFIX="${ARVO_PREFIX:-$HOME/.local}"
SKIP_MO="${ARVO_SKIP_MO:-0}"
WITH_DANA="${ARVO_WITH_DANA:-0}"
MO_VERSION="${MO_VERSION:-}"
MODB_VERSION="${MODB_VERSION:-}"
ARVO_VERSION="${ARVO_VERSION:-}"
DANA_VERSION="${DANA_VERSION:-}"

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Install or update mo, modb, modb-mcp, and arvo into <prefix>/bin and <prefix>/share.

Options:
  --prefix DIR          Install prefix (default: ~/.local, or $ARVO_PREFIX)
  --skip-mo             Skip downloading mo (use mo from PATH / mise / brew)
  --with-dana           Also install or update the dana binary
  --mo-version TAG      Pin mo release tag (e.g. v0.4.1 or 0.4.1)
  --modb-version TAG    Pin modb release tag (e.g. v0.9.0 or 0.9.0)
  --arvo-version TAG    Pin arvo release tag (e.g. v0.2.0 or 0.2.0)
  --dana-version TAG    Pin dana release tag (implies --with-dana)
  -h, --help            Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      [ "$#" -ge 2 ] || { printf 'install.sh: --prefix requires a directory argument\n' >&2; exit 1; }
      PREFIX="$2"
      shift 2
      ;;
    --skip-mo)
      SKIP_MO=1
      shift
      ;;
    --with-dana)
      WITH_DANA=1
      shift
      ;;
    --mo-version)
      [ "$#" -ge 2 ] || { printf 'install.sh: --mo-version requires a tag\n' >&2; exit 1; }
      MO_VERSION="$2"
      shift 2
      ;;
    --modb-version)
      [ "$#" -ge 2 ] || { printf 'install.sh: --modb-version requires a tag\n' >&2; exit 1; }
      MODB_VERSION="$2"
      shift 2
      ;;
    --arvo-version)
      [ "$#" -ge 2 ] || { printf 'install.sh: --arvo-version requires a tag\n' >&2; exit 1; }
      ARVO_VERSION="$2"
      shift 2
      ;;
    --dana-version)
      [ "$#" -ge 2 ] || { printf 'install.sh: --dana-version requires a tag\n' >&2; exit 1; }
      DANA_VERSION="$2"
      WITH_DANA=1
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'install.sh: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'install.sh: required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd tar
require_cmd awk

case "$PREFIX" in
  /*) ;;
  *)
    mkdir -p "$PREFIX"
    PREFIX="$(CDPATH='' cd -- "$PREFIX" && pwd)"
    ;;
esac

PREFIX="${PREFIX%/}"
[ -n "$PREFIX" ] || PREFIX="/"

normalize_tag() {
  case "$1" in
    v*) printf '%s\n' "$1" ;;
    *)  printf 'v%s\n' "$1" ;;
  esac
}

resolve_latest_tag() {
  repo="$1"
  effective="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/robertguss/$repo/releases/latest")"
  tag="${effective##*/}"
  case "$tag" in
    v*)
      printf '%s\n' "$tag"
      ;;
    *)
      printf 'install.sh: could not resolve latest release tag for robertguss/%s (got %s)\n' "$repo" "$effective" >&2
      exit 1
      ;;
  esac
}

detect_target() {
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}:${arch}" in
    Linux:x86_64|Linux:amd64)
      printf 'x86_64-linux\n'
      ;;
    Darwin:arm64|Darwin:aarch64)
      printf 'aarch64-macos\n'
      ;;
    *)
      printf 'install.sh: no prebuilt release binary for %s %s; install with Homebrew (brew install robertguss/tap/arvo) or build from source.\n' "$os" "$arch" >&2
      exit 1
      ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    printf 'install.sh: neither sha256sum nor shasum found for checksum verification\n' >&2
    exit 1
  fi
}

verify_checksum() {
  sums_file="$1"
  archive_path="$2"
  archive_name="$3"

  expected="$(awk -v name="$archive_name" '
    $2 == name || $2 == ("./" name) || $2 == ("*" name) { print $1; exit }
  ' "$sums_file")"
  if [ -z "$expected" ]; then
    printf 'install.sh: missing checksum entry for %s in SHA256SUMS.txt\n' "$archive_name" >&2
    exit 1
  fi

  actual="$(sha256_file "$archive_path")"
  if [ "$expected" != "$actual" ]; then
    printf 'install.sh: SHA-256 mismatch for %s (expected %s, got %s)\n' "$archive_name" "$expected" "$actual" >&2
    exit 1
  fi
}

TMPDIR_WORK="$(mktemp -d "${TMPDIR:-/tmp}/arvo-install.XXXXXX")"
trap 'rm -rf "$TMPDIR_WORK"' EXIT HUP INT TERM

mkdir -p "$PREFIX/bin" "$PREFIX/share"

TARGET=""
if [ "$SKIP_MO" = "0" ] || [ "$WITH_DANA" = "1" ]; then
  TARGET="$(detect_target)"
fi

install_release_binary() {
  repo="$1"
  tag="$2"
  target="$3"

  archive_name="${repo}-${tag}-${target}.tar.gz"
  base_url="https://github.com/robertguss/${repo}/releases/download/${tag}"
  archive_path="$TMPDIR_WORK/$archive_name"
  sums_path="$TMPDIR_WORK/${repo}-SHA256SUMS.txt"
  extract_dir="$TMPDIR_WORK/${repo}-unpack"

  printf '==> Installing %s %s (%s)\n' "$repo" "$tag" "$target"
  curl -fsSL "$base_url/$archive_name" -o "$archive_path"
  curl -fsSL "$base_url/SHA256SUMS.txt" -o "$sums_path"
  verify_checksum "$sums_path" "$archive_path" "$archive_name"

  mkdir -p "$extract_dir"
  tar -xzf "$archive_path" -C "$extract_dir"
  src_bin="$extract_dir/${repo}-${tag}-${target}/${repo}"
  if [ ! -f "$src_bin" ]; then
    printf 'install.sh: expected binary %s missing from %s\n' "$src_bin" "$archive_name" >&2
    exit 1
  fi

  tmp_out="$PREFIX/bin/.${repo}.tmp.$$"
  cp "$src_bin" "$tmp_out"
  chmod 0755 "$tmp_out"
  mv -f "$tmp_out" "$PREFIX/bin/$repo"
}

find_unpacked_root() {
  dir="$1"
  for entry in "$dir"/*; do
    if [ -d "$entry" ]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done
  printf 'install.sh: unpacked archive in %s contained no root directory\n' "$dir" >&2
  exit 1
}

rewrite_modb_dep() {
  toml_file="$1"
  modb_dir="$2"
  tmp_toml="${toml_file}.tmp.$$"
  awk -v target="$modb_dir" '
    /^[[:space:]]*modb[[:space:]]*=/ {
      print "modb = { path = \"" target "\" }"
      next
    }
    { print }
  ' "$toml_file" > "$tmp_toml"
  mv -f "$tmp_toml" "$toml_file"
}

install_modb() {
  tag="$1"
  tarball="$TMPDIR_WORK/modb-${tag}.tar.gz"
  extract_dir="$TMPDIR_WORK/modb-unpack"
  stage_dir="$PREFIX/share/.modb.new.$$"

  printf '==> Installing modb %s\n' "$tag"
  curl -fsSL "https://github.com/robertguss/modb/archive/refs/tags/${tag}.tar.gz" -o "$tarball"
  mkdir -p "$extract_dir"
  tar -xzf "$tarball" -C "$extract_dir"
  src_root="$(find_unpacked_root "$extract_dir")"

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  cp -R "$src_root/mo.toml" "$src_root/src" "$src_root/tools" "$src_root/examples" "$src_root/README.md" "$stage_dir/"
  rm -rf "$PREFIX/share/modb"
  mv "$stage_dir" "$PREFIX/share/modb"

  tmp_modb="$PREFIX/bin/.modb.tmp.$$"
  cat > "$tmp_modb" <<EOF
#!/usr/bin/env sh
set -eu
PREFIX_BIN="$PREFIX/bin"
MODB_ROOT="$PREFIX/share/modb"
if [ -n "\${MO:-}" ]; then
  MO_BIN="\$MO"
elif [ -x "\$PREFIX_BIN/mo" ]; then
  MO_BIN="\$PREFIX_BIN/mo"
elif command -v mo >/dev/null 2>&1; then
  MO_BIN="\$(command -v mo)"
else
  printf 'modb: could not locate \`mo\` binary (set MO=/path/to/mo or add mo to PATH)\n' >&2
  exit 1
fi
exec "\$MO_BIN" run "\$MODB_ROOT/src/modb/cli.mo" "\$@"
EOF
  chmod 0755 "$tmp_modb"
  mv -f "$tmp_modb" "$PREFIX/bin/modb"

  tmp_mcp="$PREFIX/bin/.modb-mcp.tmp.$$"
  cat > "$tmp_mcp" <<EOF
#!/usr/bin/env sh
set -eu
exec python3 "$PREFIX/share/modb/tools/modb_mcp_server.py" "\$@"
EOF
  chmod 0755 "$tmp_mcp"
  mv -f "$tmp_mcp" "$PREFIX/bin/modb-mcp"
}

install_arvo() {
  tag="$1"
  tarball="$TMPDIR_WORK/arvo-${tag}.tar.gz"
  extract_dir="$TMPDIR_WORK/arvo-unpack"
  stage_dir="$PREFIX/share/.arvo.new.$$"

  printf '==> Installing arvo %s\n' "$tag"
  curl -fsSL "https://github.com/robertguss/arvo/archive/refs/tags/${tag}.tar.gz" -o "$tarball"
  mkdir -p "$extract_dir"
  tar -xzf "$tarball" -C "$extract_dir"
  src_root="$(find_unpacked_root "$extract_dir")"

  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"
  cp -R "$src_root/mo.toml" "$src_root/lib" "$src_root/cmd" "$src_root/packages" "$src_root/bin" "$src_root/README.md" "$src_root/LICENSE" "$stage_dir/"
  chmod 0755 "$stage_dir/bin/arvo"
  rewrite_modb_dep "$stage_dir/packages/arvo-modb/mo.toml" "$PREFIX/share/modb"
  rewrite_modb_dep "$stage_dir/packages/arvo-modb/cmd/backup/mo.toml" "$PREFIX/share/modb"

  rm -rf "$PREFIX/share/arvo"
  mv "$stage_dir" "$PREFIX/share/arvo"

  tmp_arvo="$PREFIX/bin/.arvo.tmp.$$"
  cat > "$tmp_arvo" <<EOF
#!/usr/bin/env sh
set -eu
PREFIX_BIN="$PREFIX/bin"
export ARVO_ROOT="$PREFIX/share/arvo"
export MODB_PATH="$PREFIX/share/modb"
if [ -z "\${MO:-}" ]; then
  if [ -x "\$PREFIX_BIN/mo" ]; then
    MO="\$PREFIX_BIN/mo"
    export MO
  elif command -v mo >/dev/null 2>&1; then
    MO="\$(command -v mo)"
    export MO
  fi
fi
exec "\$ARVO_ROOT/bin/arvo" "\$@"
EOF
  chmod 0755 "$tmp_arvo"
  mv -f "$tmp_arvo" "$PREFIX/bin/arvo"
}

if [ "$SKIP_MO" = "0" ]; then
  if [ -n "$MO_VERSION" ]; then
    MO_TAG="$(normalize_tag "$MO_VERSION")"
  else
    MO_TAG="$(resolve_latest_tag mo)"
  fi
  install_release_binary mo "$MO_TAG" "$TARGET"
fi

if [ "$WITH_DANA" = "1" ]; then
  if [ -n "$DANA_VERSION" ]; then
    DANA_TAG="$(normalize_tag "$DANA_VERSION")"
  else
    DANA_TAG="$(resolve_latest_tag dana)"
  fi
  install_release_binary dana "$DANA_TAG" "$TARGET"
fi

if [ -n "$MODB_VERSION" ]; then
  MODB_TAG="$(normalize_tag "$MODB_VERSION")"
else
  MODB_TAG="$(resolve_latest_tag modb)"
fi
install_modb "$MODB_TAG"

if [ -n "$ARVO_VERSION" ]; then
  ARVO_TAG="$(normalize_tag "$ARVO_VERSION")"
else
  ARVO_TAG="$(resolve_latest_tag arvo)"
fi
install_arvo "$ARVO_TAG"

echo
printf 'Installed to %s/bin and %s/share\n' "$PREFIX" "$PREFIX"
if [ "$SKIP_MO" = "0" ]; then
  printf '  mo:       %s\n' "$("$PREFIX/bin/mo" --version)"
elif command -v mo >/dev/null 2>&1; then
  printf '  mo:       %s (%s)\n' "$(mo --version)" "$(command -v mo)"
else
  printf '  mo:       skipped (ensure mo 0.4.1+ is on PATH before running modb/arvo)\n'
fi
if [ "$WITH_DANA" = "1" ]; then
  printf '  dana:     %s\n' "$("$PREFIX/bin/dana" --version)"
fi
printf '  modb:     %s (%s)\n' "$MODB_TAG" "$PREFIX/bin/modb"
printf '  modb-mcp: %s (%s)\n' "$MODB_TAG" "$PREFIX/bin/modb-mcp"
printf '  arvo:     %s (%s)\n' "$ARVO_TAG" "$PREFIX/bin/arvo"

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *)
    echo
    printf 'Note: add %s/bin to your PATH to invoke installed commands directly.\n' "$PREFIX"
    ;;
esac
