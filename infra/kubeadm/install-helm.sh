#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$script_dir/common.sh"

require_root
: "${HELM_VERSION:=v3.19.0}"

if command -v helm >/dev/null 2>&1 && [[ "$(helm version --short)" == "${HELM_VERSION}"* ]]; then
  log "Helm ${HELM_VERSION} is already installed"
  exit 0
fi

case "$(uname -m)" in
  x86_64) helm_arch=amd64 ;;
  aarch64) helm_arch=arm64 ;;
  *) fail "unsupported Helm architecture: $(uname -m)" ;;
esac

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
archive="helm-${HELM_VERSION}-linux-${helm_arch}.tar.gz"
base_url="https://get.helm.sh/${archive}"
log "downloading Helm ${HELM_VERSION}"
curl --fail --show-error --silent --location "$base_url" --output "$tmp_dir/$archive"
curl --fail --show-error --silent --location "${base_url}.sha256sum" --output "$tmp_dir/$archive.sha256sum"
(
  cd "$tmp_dir"
  sha256sum --check "$archive.sha256sum"
)
tar -xzf "$tmp_dir/$archive" -C "$tmp_dir"
install -m 0755 "$tmp_dir/linux-${helm_arch}/helm" /usr/local/bin/helm
log "installed $(helm version --short)"
