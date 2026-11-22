#!/usr/bin/env bash
# Kubernetes and YAML tools that GitHub-hosted runners have on PATH: kubectl,
# helm, kustomize and yq. Jobs and repository scripts call them without a
# setup action (for example a script that runs `helm` before azure/setup-helm).
# A setup-* action in a job still puts its own version first in PATH.
# The newest stable version at build time; Helm stays on major 3, the same as
# the GitHub-hosted image. Each download is checked against its SHA-256.
set -euo pipefail

api=https://api.github.com/repos
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# GET from api.github.com, with GITHUB_TOKEN when the build has one.
github_api() { # URL
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
  else
    curl -fsSL "$1"
  fi
}

# Download URL to OUT and check it against SHA256.
fetch() { # URL SHA256 OUT
  [[ "$2" =~ ^[0-9a-f]{64}$ ]] || { echo "No SHA-256 for $1" >&2; exit 1; }
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

# "URL SHA256" of an asset in a GitHub release (JSON); GitHub gives the digest.
asset() { # RELEASE_JSON NAME
  jq -r --arg n "$2" \
    '.assets[] | select(.name == $n) | "\(.browser_download_url) \(.digest // "" | ltrimstr("sha256:"))"' <<<"$1"
}

# kubectl (https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
v=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
base="https://dl.k8s.io/release/$v/bin/linux/amd64"
fetch "$base/kubectl" "$(curl -fsSL "$base/kubectl.sha256" | cut -d' ' -f1)" "$tmp/kubectl"
install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl

# helm, major 3 (https://helm.sh/docs/intro/install/)
v=$(github_api "$api/helm/helm/releases?per_page=100" |
  jq -r '[.[] | select(.prerelease | not) | .tag_name | select(startswith("v3."))][0] // ""')
[ -n "$v" ] || { echo "No Helm 3 release found" >&2; exit 1; }
file="helm-$v-linux-amd64.tar.gz"
fetch "https://get.helm.sh/$file" "$(curl -fsSL "https://get.helm.sh/$file.sha256sum" | cut -d' ' -f1)" "$tmp/$file"
tar -xzf "$tmp/$file" -C "$tmp" linux-amd64/helm
install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm

# kustomize (tags kustomize/vX.Y.Z; the repository also tags its Go modules)
release=$(github_api "$api/kubernetes-sigs/kustomize/releases?per_page=100" |
  jq '[.[] | select((.prerelease | not) and (.tag_name | startswith("kustomize/v")))][0]')
v=$(jq -r '.tag_name // "" | ltrimstr("kustomize/")' <<<"$release")
[ -n "$v" ] || { echo "No kustomize release found" >&2; exit 1; }
file="kustomize_${v}_linux_amd64.tar.gz"
read -r url sha <<<"$(asset "$release" "$file")"
fetch "$url" "$sha" "$tmp/$file"
tar -xzf "$tmp/$file" -C "$tmp" kustomize
install -m 0755 "$tmp/kustomize" /usr/local/bin/kustomize

# yq by Mike Farah (Ubuntu's yq package is a different tool)
release=$(github_api "$api/mikefarah/yq/releases/latest")
read -r url sha <<<"$(asset "$release" yq_linux_amd64)"
fetch "$url" "$sha" "$tmp/yq"
install -m 0755 "$tmp/yq" /usr/local/bin/yq

kubectl version --client
helm version --short
kustomize version
yq --version
