#!/usr/bin/env bash
# Kubernetes and YAML tools that GitHub-hosted runners have on PATH: kubectl,
# helm, kustomize and yq. Jobs and repository scripts call them without a
# setup action (for example a script that runs `helm` before azure/setup-helm).
# A setup-* action in a job still puts its own version first in PATH.
# Versions and SHA-256 come from build-vm.pkr.hcl (see update-versions.sh).
set -euo pipefail
: "${KUBECTL_VERSION:?}" "${KUBECTL_SHA256:?}" "${HELM_VERSION:?}" "${HELM_SHA256:?}"
: "${KUSTOMIZE_VERSION:?}" "${KUSTOMIZE_SHA256:?}" "${YQ_VERSION:?}" "${YQ_SHA256:?}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Download URL to OUT and check it against SHA256.
fetch() { # URL SHA256 OUT
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

# https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
fetch "https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/linux/amd64/kubectl" "$KUBECTL_SHA256" "$tmp/kubectl"
install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl

# https://helm.sh/docs/intro/install/
fetch "https://get.helm.sh/helm-v$HELM_VERSION-linux-amd64.tar.gz" "$HELM_SHA256" "$tmp/helm.tar.gz"
tar -xzf "$tmp/helm.tar.gz" -C "$tmp" linux-amd64/helm
install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm

# https://kubectl.docs.kubernetes.io/installation/kustomize/binaries/
fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/v$KUSTOMIZE_VERSION/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
  "$KUSTOMIZE_SHA256" "$tmp/kustomize.tar.gz"
tar -xzf "$tmp/kustomize.tar.gz" -C "$tmp" kustomize
install -m 0755 "$tmp/kustomize" /usr/local/bin/kustomize

# yq by Mike Farah (Ubuntu's yq package is a different tool)
fetch "https://github.com/mikefarah/yq/releases/download/v$YQ_VERSION/yq_linux_amd64" "$YQ_SHA256" "$tmp/yq"
install -m 0755 "$tmp/yq" /usr/local/bin/yq

kubectl version --client
helm version --short
kustomize version
yq --version
