#!/bin/sh
# Install abc (macOS, Apple Silicon or Intel) from GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/abelcondev/abc/main/install.sh | sh
#
# Environment:
#   ABC_VERSION      release tag to install (default: latest), e.g. v0.1.0
#   ABC_INSTALL_DIR  destination directory (default: ~/.local/bin)
set -eu

repo="abelcondev/abc"
version="${ABC_VERSION:-latest}"
install_dir="${ABC_INSTALL_DIR:-$HOME/.local/bin}"

fail() {
	printf 'abc install: %s\n' "$1" >&2
	exit 1
}

case "$(uname -s)" in
Darwin) os="macos" ;;
*) fail "abc publishes macOS builds only; build from source with Zig 0.16 on $(uname -s)" ;;
esac

case "$(uname -m)" in
arm64 | aarch64) arch="aarch64" ;;
x86_64 | amd64) arch="x86_64" ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

# Apple Silicon running a Rosetta shell reports x86_64; prefer the native build.
if [ "$arch" = "x86_64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
	arch="aarch64"
fi

asset="abc-${os}-${arch}.tar.gz"
if [ "$version" = "latest" ]; then
	base="https://github.com/${repo}/releases/latest/download"
else
	base="https://github.com/${repo}/releases/download/${version}"
fi

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

printf 'Downloading %s (%s)...\n' "$asset" "$version"
curl -fsSL "$base/$asset" -o "$tmp/$asset" || fail "download failed: $base/$asset"
curl -fsSL "$base/$asset.sha256" -o "$tmp/$asset.sha256" || fail "checksum download failed"

expected="$(awk '{print $1}' "$tmp/$asset.sha256")"
actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "checksum mismatch for $asset"

tar -xzf "$tmp/$asset" -C "$tmp"
[ -f "$tmp/abc" ] || fail "archive does not contain abc"

mkdir -p "$install_dir"
install -m 755 "$tmp/abc" "$install_dir/abc"
xattr -d com.apple.quarantine "$install_dir/abc" 2>/dev/null || true

printf 'Installed %s to %s\n' "$("$install_dir/abc" --version 2>/dev/null || echo abc)" "$install_dir/abc"

# `abc update` reuses this script and only needs the install line above.
if [ "${ABC_UPDATING:-0}" = "1" ]; then
	exit 0
fi

case ":$PATH:" in
*":$install_dir:"*)
	resolved="$(command -v abc 2>/dev/null || true)"
	if [ -n "$resolved" ] && [ "$resolved" != "$install_dir/abc" ]; then
		printf '\nNote: `abc` currently resolves to %s, which comes earlier in PATH.\n' "$resolved"
	fi
	;;
*)
	shell_name="$(basename "${SHELL:-sh}")"
	case "$shell_name" in
	zsh) rc="~/.zshrc" ;;
	bash) rc="~/.bashrc" ;;
	*) rc="your shell profile" ;;
	esac
	printf '\n%s is not in PATH. Add it with:\n  echo '\''export PATH="%s:$PATH"'\'' >> %s\n' "$install_dir" "$install_dir" "$rc"
	;;
esac

cat <<'NEXT'

Next steps:
  abc login deepseek          # or export DEEPSEEK_API_KEY / DASHSCOPE_API_KEY / ...
  cd your_project && abc
NEXT
