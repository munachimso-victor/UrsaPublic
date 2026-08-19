#!/usr/bin/env bash
# Host prerequisites for this manual KubeStellar repro only.
# Does NOT create clusters — run ./setup_kubestellar.sh next.
#
# Usage:
#   chmod +x install_requirements.sh
#   ./install_requirements.sh
#
# Options:
#   --skip-apt     Skip apt install (docker, curl)
#   --skip-check   Skip KubeStellar check_pre_req.sh
#   --skip-inotify Skip raising fs.inotify limits
#   --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESTELLAR_VERSION="0.29.0"
CLUSTERADM_VERSION="0.10.1"
INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin}"

SKIP_APT=false
SKIP_CHECK=false
SKIP_INOTIFY=false

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-apt) SKIP_APT=true ;;
    --skip-check) SKIP_CHECK=true ;;
    --skip-inotify) SKIP_INOTIFY=true ;;
    --help|-h) usage ;;
    *) die "Unknown option: $1 (use --help)" ;;
  esac
  shift
done

ARCH="$(detect_arch)"
log "Manual repro directory: ${SCRIPT_DIR}"
log "Detected platform: linux/${ARCH}"

run_with_docker() {
  if docker info >/dev/null 2>&1; then
    "$@"
  elif have_cmd sg && getent group docker >/dev/null 2>&1; then
    sg docker -c "$*"
  else
    sudo "$@"
  fi
}

install_bin() {
  local src="$1" name="$2"
  sudo install -o root -g root -m 0755 "${src}" "${INSTALL_BIN}/${name}"
}

# --- Docker (via apt on Debian/Ubuntu) ---
if [[ "${SKIP_APT}" == false ]] && have_cmd apt-get; then
  log "Installing apt packages (curl, docker.io, jq)..."
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl ca-certificates docker.io jq
  if have_cmd systemctl; then
    sudo systemctl enable --now docker >/dev/null 2>&1 || true
  fi
  local_user="$(id -un)"
  if getent group docker >/dev/null 2>&1 && ! id -nG "${local_user}" | grep -qw docker; then
    log "Adding ${local_user} to the docker group (log out/in or: newgrp docker)..."
    sudo usermod -aG docker "${local_user}" || true
  fi
elif [[ "${SKIP_APT}" == false ]]; then
  warn "apt-get not found — ensure curl and Docker are installed."
fi

have_cmd curl || die "curl not found"

if docker info >/dev/null 2>&1; then
  log "Docker OK: $(docker version -f '{{.Server.Version}}' 2>/dev/null || echo running)"
elif run_with_docker docker info >/dev/null 2>&1; then
  log "Docker OK (use newgrp docker if docker info fails in a new shell)."
else
  warn "docker info failed — fix Docker before running setup_kubestellar.sh."
fi

# --- kubectl ---
if have_cmd kubectl; then
  log "kubectl already installed: $(kubectl version --client 2>/dev/null | head -1 || true)"
else
  log "Installing kubectl..."
  tmp="$(mktemp)"
  curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" -o "${tmp}"
  install_bin "${tmp}" kubectl
  rm -f "${tmp}"
fi

# --- helm ---
if have_cmd helm; then
  log "helm already installed: $(helm version --short 2>/dev/null || true)"
else
  log "Installing Helm 3..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- kind ---
if have_cmd kind; then
  log "kind already installed: $(kind version 2>/dev/null || true)"
else
  log "Installing kind..."
  tmp="$(mktemp)"
  curl -fsSL "https://kind.sigs.k8s.io/dl/latest/kind-linux-${ARCH}" -o "${tmp}"
  install_bin "${tmp}" kind
  rm -f "${tmp}"
fi

# --- kflex ---
if have_cmd kflex; then
  log "kflex already installed: $(kflex version 2>/dev/null || true)"
else
  log "Installing kflex..."
  curl -fsSL https://raw.githubusercontent.com/kubestellar/kubeflex/main/scripts/install-kubeflex.sh \
    | sudo bash -s -- --ensure-folder "${INSTALL_BIN}" --strip-bin
fi

# --- clusteradm ---
if have_cmd clusteradm; then
  log "clusteradm already installed: $(clusteradm version 2>/dev/null | head -1 || true)"
else
  log "Installing clusteradm ${CLUSTERADM_VERSION}..."
  curl -fsSL https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh \
    | bash -s -- "${CLUSTERADM_VERSION}"
fi

# --- yq (kubestellar-snapshot.sh; not in default apt on Ubuntu) ---
if have_cmd yq; then
  log "yq already installed: $(yq --version 2>/dev/null || true)"
else
  log "Installing yq..."
  tmp="$(mktemp)"
  curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" -o "${tmp}"
  install_bin "${tmp}" yq
  rm -f "${tmp}"
fi

# --- inotify (Kind with multiple clusters) ---
if [[ "${SKIP_INOTIFY}" == false ]]; then
  log "Raising inotify limits..."
  sudo sysctl -w fs.inotify.max_user_instances=8192 >/dev/null || warn "Could not set max_user_instances"
  sudo sysctl -w fs.inotify.max_user_watches=524288 >/dev/null || warn "Could not set max_user_watches"
fi

# --- Local scripts ---
for script in setup_kubestellar.sh create-kind-cluster-with-SSL-passthrough.sh install_requirements.sh; do
  [[ -f "${SCRIPT_DIR}/${script}" ]] && chmod +x "${SCRIPT_DIR}/${script}"
done

# --- KubeStellar pre-flight ---
if [[ "${SKIP_CHECK}" == false ]]; then
  log "Running KubeStellar v${KUBESTELLAR_VERSION} pre-req check..."
  check_cmd='bash <(curl -fsSL https://raw.githubusercontent.com/kubestellar/kubestellar/v'"${KUBESTELLAR_VERSION}"'/scripts/check_pre_req.sh) kflex ocm helm kubectl docker kind'
  if run_with_docker bash -c "${check_cmd}"; then
    log "KubeStellar pre-req check passed."
  else
    warn "Pre-req check reported issues — fix before ./setup_kubestellar.sh."
  fi
else
  log "Skipping KubeStellar pre-req check (--skip-check)."
fi

cat <<EOF

================================================================================
Host prerequisites installed.
================================================================================

  If docker group was just added: newgrp docker  (or log out/in)

  Verify:
    docker info
    kubectl version --client
    helm version
    kind version
    kflex version
    clusteradm version

  Next:
    export KUBECONFIG=~/.kube/kubeflex
    ./setup_kubestellar.sh

================================================================================
EOF
