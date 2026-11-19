#!/usr/bin/env bash
# ============================================================================
# Makes sure the CI image has the tools the jobs need, installing only what is
# missing (so a fully-equipped runner image does nothing here):
#   terraform  TERRAFORM_VERSION from releases.hashicorp.com, SHA256-verified
#   jq         via apt-get / apk
# With ENSURE_TEST_TOOLS=true also: bats, shellcheck, python3 (test jobs).
# ============================================================================
set -euo pipefail

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.17.2}"
need=()

have() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
  elif have apk; then
    apk add --no-cache "$@" >/dev/null
  elif have dnf; then
    dnf install -y -q "$@" >/dev/null
  else
    echo "ensure-tools: cannot install $* (no apt-get/apk/dnf); use an image that has them" >&2
    return 1
  fi
}

have jq || need+=(jq)
have unzip || need+=(unzip)
have curl || need+=(curl)
if [[ "${ENSURE_TEST_TOOLS:-false}" == true ]]; then
  have bats || need+=(bats)
  have shellcheck || need+=(shellcheck)
  have python3 || need+=(python3)
fi
if ((${#need[@]})); then
  echo "ensure-tools: installing ${need[*]}"
  pkg_install "${need[@]}"
fi
# PyYAML for tests/validate_configs.py and the test helpers.
if [[ "${ENSURE_TEST_TOOLS:-false}" == true ]] && ! python3 -c 'import yaml' 2>/dev/null; then
  echo "ensure-tools: installing PyYAML"
  if have apt-get; then pkg_install python3-yaml; elif have apk; then pkg_install py3-yaml; else pkg_install python3-pyyaml; fi
fi

if ! have terraform; then
  echo "ensure-tools: installing terraform ${TERRAFORM_VERSION}"
  arch="$(uname -m)"
  case "${arch}" in
  x86_64 | amd64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    echo "ensure-tools: unsupported architecture ${arch}" >&2
    exit 1
    ;;
  esac
  tmp="$(mktemp -d)"
  base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  zip="terraform_${TERRAFORM_VERSION}_linux_${arch}.zip"
  curl -fsSL -o "${tmp}/${zip}" "${base}/${zip}"
  curl -fsSL -o "${tmp}/SHA256SUMS" "${base}/terraform_${TERRAFORM_VERSION}_SHA256SUMS"
  (cd "${tmp}" && grep " ${zip}\$" SHA256SUMS | sha256sum -c -)
  unzip -q -o "${tmp}/${zip}" -d "${tmp}"
  install -m 0755 "${tmp}/terraform" /usr/local/bin/terraform
  rm -rf "${tmp}"
fi

# (sed reads all input: `| head -1` could SIGPIPE terraform under pipefail)
"$(command -v terraform || echo /usr/local/bin/terraform)" version | sed -n 1p
