#!/bin/bash
# Deploy the simp-webrick stack to Minikube.  Idempotent: skips the build and
# apply steps if the stack is already healthy.
#
# Usage:
#   k8s/minikube-deploy.sh          # deploy (or no-op if already healthy)
#   k8s/minikube-deploy.sh --down   # delete all deployed resources
#   k8s/minikube-deploy.sh --force  # rebuild and reapply even if already healthy
#
# PUPPET_CA_SRC=/path/to/puppet-ca k8s/minikube-deploy.sh

set -euo pipefail

# Route all kubectl calls through minikube's bundled kubectl so they always
# target the running minikube cluster, regardless of the system kubeconfig.
kubectl() { minikube kubectl -- "$@"; }

# ── Container engine detection ─────────────────────────────────────────────────
# Prefer podman; fall back to docker.  Override with CONTAINER_ENGINE=docker.
if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
    _ENGINE="$CONTAINER_ENGINE"
elif command -v podman &>/dev/null; then
    _ENGINE=podman
elif command -v docker &>/dev/null; then
    _ENGINE=docker
else
    printf 'Error: neither podman nor docker found\n' >&2
    exit 1
fi
printf '# Using container engine: %s\n' "$_ENGINE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Path to the puppet-ca source tree.  Override via environment variable:
#   PUPPET_CA_SRC=/path/to/puppet-ca k8s/minikube-deploy.sh
PUPPET_CA_SRC="${PUPPET_CA_SRC:-$REPO_ROOT/../puppet-ca}"

# ── Argument handling ──────────────────────────────────────────────────────────
DO_FORCE=false
DO_DOWN=false

for _arg in "$@"; do
    case "$_arg" in
        --force) DO_FORCE=true ;;
        --down)  DO_DOWN=true ;;
        *) printf 'Unknown argument: %s\n' "$_arg" >&2; exit 1 ;;
    esac
done

if $DO_DOWN; then
    if ! minikube status &>/dev/null; then
        printf '# Minikube is not running; nothing to remove.\n'
        exit 0
    fi
    printf '# Removing simp-webrick k8s resources...\n'
    kubectl delete -f "$SCRIPT_DIR/puppet-client.yml" --ignore-not-found
    kubectl delete -f "$SCRIPT_DIR/puppet-master.yml"  --ignore-not-found
    kubectl delete -f "$SCRIPT_DIR/puppet-ca.yml"      --ignore-not-found
    printf '# Done.\n'
    exit 0
fi

# ── Ensure minikube is running ─────────────────────────────────────────────────
if ! minikube status &>/dev/null; then
    printf '# Starting minikube...\n'
    minikube start --driver="$_ENGINE" --container-runtime=containerd
fi

# ── Idempotency check ──────────────────────────────────────────────────────────
# If all deployments are already healthy and --force was not given, skip the
# expensive build / image-load / apply cycle.
if ! $DO_FORCE; then
    _healthy=true
    for _d in puppet-ca puppet-master puppet-client; do
        kubectl rollout status "deployment/$_d" --timeout=10s &>/dev/null \
            || { _healthy=false; break; }
    done
    if $_healthy; then
        printf '# Stack is already healthy; nothing to do (use --force to rebuild).\n'
        exit 0
    fi
fi

# ── Build images ───────────────────────────────────────────────────────────────
printf '# Building puppet-ca image from %s...\n' "$PUPPET_CA_SRC"
"$_ENGINE" build -t puppet-ca:latest "$PUPPET_CA_SRC"

printf '# Building puppet-master image...\n'
"$_ENGINE" build -t puppet-master:latest -f "$REPO_ROOT/Dockerfile.passenger" "$REPO_ROOT"

printf '# Building puppet-client image...\n'
"$_ENGINE" build -t puppet-client:latest -f "$REPO_ROOT/Dockerfile.client" "$REPO_ROOT"

# ── Load images into minikube ──────────────────────────────────────────────────
# minikube image load <name> may require a Docker daemon for some drivers.
# Work-around: save each image to a private temp directory and load from there.
# mktemp -d creates the directory with mode 700, avoiding TOCTOU races in /tmp.
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

printf '# Loading images into minikube (via tar)...\n'
for img in puppet-ca puppet-master puppet-client; do
    printf '#   loading %s:latest...\n' "$img"
    "$_ENGINE" save "${img}:latest" -o "$_tmpdir/${img}.tar"
    minikube image load "$_tmpdir/${img}.tar"
done
printf '# Images loaded.\n'

# ── Apply manifests ────────────────────────────────────────────────────────────
printf '# Applying manifests...\n'
kubectl apply -f "$SCRIPT_DIR/puppet-ca.yml"
kubectl apply -f "$SCRIPT_DIR/puppet-master.yml"
kubectl apply -f "$SCRIPT_DIR/puppet-client.yml"

# ── Wait for readiness ─────────────────────────────────────────────────────────
printf '# Waiting for puppet-ca to be ready'
kubectl rollout status deployment/puppet-ca --timeout=120s
printf '\n'

printf '# Waiting for puppet-master to be ready (bootstraps TLS cert from CA)'
kubectl rollout status deployment/puppet-master --timeout=180s
printf '\n'

printf '# Waiting for puppet-client to be ready'
kubectl rollout status deployment/puppet-client --timeout=60s
printf '\n'

printf '# Stack deployed.\n'
printf '#\n'
printf '# To run integration tests:\n'
printf '#   ./test/integration.sh --k8s\n'
printf '#\n'
printf '# To tear down:\n'
printf '#   k8s/minikube-deploy.sh --down\n'
