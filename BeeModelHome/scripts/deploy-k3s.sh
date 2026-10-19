#!/bin/bash
set -euo pipefail

#===============================================================================
# BeeModelHome - K3S Deployment Script (Podman)
#===============================================================================
# Builds the static website (tools/build.py), packs it into an nginx image,
# pushes it and deploys it to K3S on the VPS.
#
# Architecture (namespace: beemodel-home):
#   • beemodel-home   nginx (unprivileged, port 8080) serving site/.
#                     NodePort 32110 — Cloudflare Tunnel forwards
#                     https://beemodel.hideterms.com here over HTTP.
#
# Registry:  beecodersregistry.azurecr.io  (reuses the existing acr-secret
#            ImagePullSecret — copied into this namespace on first deploy).
#
# Usage:
#   ./scripts/deploy-k3s.sh [all|site|build|push|deploy|status|logs|run|tunnel]
#
#   all      site → build → push → deploy → status (default)
#   site     regenerate site/ (pages, releases from CHANGELOG + GitHub; media
#            only when media/ has new sources)
#   build    build the image locally with podman (site/ as it is)
#   push     podman login + push the image
#   deploy   apply the manifests on the VPS and wait for the rollout
#   status   kubectl get on the namespace
#   logs     tail the nginx logs
#   run      serve the image locally on http://localhost:8110 (a preview)
#   tunnel   print the Cloudflare Tunnel ingress rule
#
# Version: the BeeModel version (VERSION) + the git sha, -dirty-<time> for a
# dirty tree; every image is also pushed as :latest. `push` and `deploy` reuse
# the version of the last `build` (override with APP_VERSION=...).
#
# Required tools locally: podman, ssh, git, python3 (+ Pillow, ffmpeg for media)
#===============================================================================

HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$HOME_DIR/.." && pwd)"
cd "$HOME_DIR"

COMMAND="${1:-all}"

REGISTRY="${REGISTRY:-beecodersregistry.azurecr.io}"
NAMESPACE="beemodel-home"
IMAGE="$REGISTRY/beemodel-home"
NODE_PORT=32110
PUBLIC_HOST="${PUBLIC_HOST:-beemodel.hideterms.com}"

VPS_IP="${VPS_IP:-212.47.77.32}"
VPS_USER="${VPS_USER:-bart}"

K8S_DIR="$HOME_DIR/deploy/k3s"
VERSION_FILE="$HOME_DIR/.deploy-k3s.version"

app_version() {
  local base sha
  base="$(cat "$ROOT_DIR/VERSION" 2>/dev/null || echo 0.0.0)"
  sha="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo nogit)"
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain -- BeeModelHome 2>/dev/null)" ]]; then
    echo "$base-$sha-dirty-$(date +%Y%m%d%H%M%S)"
  else
    echo "$base-$sha"
  fi
}
if [[ -z "${APP_VERSION:-}" ]]; then
  if [[ "$COMMAND" =~ ^(push|deploy)$ && -s "$VERSION_FILE" ]]; then
    APP_VERSION="$(cat "$VERSION_FILE")"
  else
    APP_VERSION="$(app_version)"
  fi
fi

ssh_vps() {
  local cmd="$1"
  ssh -o StrictHostKeyChecking=accept-new "$VPS_USER@$VPS_IP" "bash -lc $(printf %q "$cmd")"
}

KUBECTL_VPS='$([ -r "$HOME/.kube/config" ] && echo "env KUBECONFIG=$HOME/.kube/config kubectl" || echo "sudo k3s kubectl")'
kubectl_vps() {
  ssh_vps "$KUBECTL_VPS $1"
}

check_build_deps() { command -v podman >/dev/null 2>&1 || { echo "podman not found"; exit 1; }; }
check_remote_deps() { command -v ssh >/dev/null 2>&1 || { echo "ssh not found"; exit 1; }; }

# -----------------------------------------------------------------------------
build_site() {
  echo "==> Building site/"
  python3 "$HOME_DIR/tools/build.py"
}

build_image() {
  [[ -s "$HOME_DIR/site/index.html" ]] || build_site
  echo "==> Building $IMAGE:$APP_VERSION"
  podman build --pull=newer \
    -t "$IMAGE:latest" -t "$IMAGE:$APP_VERSION" \
    -f "$HOME_DIR/Dockerfile" "$HOME_DIR"
  echo "$APP_VERSION" > "$VERSION_FILE"
}

push_image() {
  echo "==> Logging into $REGISTRY"
  if [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_PASSWORD:-}" ]]; then
    podman login -u "$REGISTRY_USER" -p "$REGISTRY_PASSWORD" "$REGISTRY"
  else
    podman login "$REGISTRY"
  fi
  echo "==> Pushing $IMAGE"
  podman push "$IMAGE:$APP_VERSION"
  podman push "$IMAGE:latest"
}

# Copy the existing acr-secret from a namespace that has one. Idempotent.
ensure_acr_secret() {
  if kubectl_vps "-n $NAMESPACE get secret acr-secret >/dev/null 2>&1"; then
    return 0
  fi
  local src
  for src in beegit beedocs beehosting aidbooks sqail fietsloire; do
    if kubectl_vps "-n $src get secret acr-secret >/dev/null 2>&1"; then
      echo "==> $NAMESPACE/acr-secret missing; copying from $src/acr-secret"
      ssh_vps "K=$KUBECTL_VPS; \$K -n $src get secret acr-secret -o yaml \
        | sed -e '/namespace:/d' -e '/resourceVersion:/d' -e '/uid:/d' -e '/creationTimestamp:/d' \
        | \$K -n $NAMESPACE apply -f -"
      return 0
    fi
  done
  echo "ERROR: no source acr-secret found; create it with"
  echo "  kubectl -n $NAMESPACE create secret docker-registry acr-secret --docker-server=$REGISTRY --docker-username=<user> --docker-password=<token>"
  exit 1
}

deploy_manifests() {
  echo "==> Deploying BeeModelHome $APP_VERSION to $VPS_USER@$VPS_IP (namespace: $NAMESPACE)"
  ssh_vps "$KUBECTL_VPS apply -f -" < "$K8S_DIR/namespace.yaml"
  ensure_acr_secret
  local tmp
  tmp="$(mktemp -d)"
  cp "$K8S_DIR"/*.yaml "$tmp/"
  sed -i "s|newTag: .*|newTag: \"$APP_VERSION\"|" "$tmp/kustomization.yaml"
  tar -C "$tmp" -czf - . | ssh -o StrictHostKeyChecking=accept-new "$VPS_USER@$VPS_IP" \
    "bash -lc $(printf %q "set -e; d=\$(mktemp -d); trap 'rm -rf \$d' EXIT; tar -xzf - -C \$d; $KUBECTL_VPS apply -k \$d")"
  rm -rf "$tmp"
  kubectl_vps "-n $NAMESPACE rollout status deployment/beemodel-home --timeout=180s"
  echo ""
  echo "Deployed BeeModelHome $APP_VERSION"
  echo "  • Origin:  http://$VPS_IP:$NODE_PORT/"
  echo "  • Public:  https://$PUBLIC_HOST/  (via Cloudflare Tunnel)"
  echo ""
  tunnel_info
}

tunnel_info() {
  cat <<EOT
  Cloudflare Tunnel ingress rule (cloudflared on the VPS), before the catch-all:
    - hostname: $PUBLIC_HOST
      service: http://localhost:$NODE_PORT
  and a CNAME $PUBLIC_HOST -> <tunnel-id>.cfargotunnel.com (cloudflared tunnel route dns <tunnel> $PUBLIC_HOST).

EOT
}

status() { kubectl_vps "-n $NAMESPACE get pods,svc,deploy"; }
logs() { kubectl_vps "-n $NAMESPACE logs deployment/beemodel-home --tail=80" || true; }

run_local() {
  [[ -n "$(podman images -q "$IMAGE:latest" 2>/dev/null)" ]] || build_image
  echo "==> http://localhost:8110/  (Ctrl+C stops)"
  podman run --rm -p 8110:8080 "$IMAGE:latest"
}

main() {
  case "$COMMAND" in
    all)
      check_build_deps; check_remote_deps
      build_site; build_image; push_image; deploy_manifests; status ;;
    site)    build_site ;;
    build)   check_build_deps; build_image ;;
    push)    check_build_deps; push_image ;;
    deploy)  check_remote_deps; deploy_manifests ;;
    status)  check_remote_deps; status ;;
    logs)    check_remote_deps; logs ;;
    run)     check_build_deps; run_local ;;
    tunnel)  tunnel_info ;;
    *)
      echo "Unknown command: $COMMAND"
      echo "Usage: $0 [all|site|build|push|deploy|status|logs|run|tunnel]"
      exit 1 ;;
  esac
}

main "$@"
