#!/usr/bin/env bash
# Find the newest versions of the tools in the image (actions/runner, kubectl,
# helm 3, kustomize, yq) and write them with their SHA-256 into the defaults
# in build-vm.pkr.hcl. Review the change and commit it; the next image build
# uses it. The build itself asks no API for versions.
#
# One GraphQL request to GitHub gives the versions and the file digests of
# runner, helm, kustomize and yq (it needs `gh auth login`). kubectl and the
# helm checksum come from their download servers (dl.k8s.io, get.helm.sh).
#
# Usage: bash packer/update-versions.sh
set -euo pipefail
cd "$(dirname "$0")"
hcl=build-vm.pkr.hcl

query='{
  runner: repository(owner: "actions", name: "runner") {
    latestRelease { tagName releaseAssets(first: 50) { nodes { name digest } } }
  }
  helm: repository(owner: "helm", name: "helm") {
    releases(first: 30, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { tagName isPrerelease } }
  }
  kustomize: repository(owner: "kubernetes-sigs", name: "kustomize") {
    releases(first: 30, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes { tagName isPrerelease releaseAssets(first: 20) { nodes { name digest } } }
    }
  }
  yq: repository(owner: "mikefarah", name: "yq") {
    latestRelease { tagName releaseAssets(first: 1, name: "yq_linux_amd64") { nodes { digest } } }
  }
}'

# One NAME=VALUE line for each variable. The kustomize repository also tags
# its Go modules (api/..., kyaml/...), and helm has majors 3 and 4.
filter='.data
| (.runner.latestRelease | (.tagName | ltrimstr("v")) as $v
   | "runner_version=\($v)",
     (.releaseAssets.nodes[] | select(.name == "actions-runner-linux-x64-\($v).tar.gz") | "runner_sha256=\(.digest)")),
  ([.helm.releases.nodes[] | select((.isPrerelease | not) and (.tagName | startswith("v3."))) | .tagName][0]
   | "helm_version=\(ltrimstr("v"))"),
  ([.kustomize.releases.nodes[] | select((.isPrerelease | not) and (.tagName | startswith("kustomize/v")))][0]
   | (.tagName | ltrimstr("kustomize/")) as $v
   | "kustomize_version=\($v | ltrimstr("v"))",
     (.releaseAssets.nodes[] | select(.name == "kustomize_\($v)_linux_amd64.tar.gz") | "kustomize_sha256=\(.digest)")),
  (.yq.latestRelease
   | "yq_version=\(.tagName | ltrimstr("v"))",
     "yq_sha256=\(.releaseAssets.nodes[0].digest)")'

declare -A new
while IFS='=' read -r name value; do
  new[$name]=${value#sha256:}
done < <(gh api graphql -f query="$query" --jq "$filter")

kubectl=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
new[kubectl_version]=${kubectl#v}
new[kubectl_sha256]=$(curl -fsSL "https://dl.k8s.io/release/$kubectl/bin/linux/amd64/kubectl.sha256" | cut -d' ' -f1)
new[helm_sha256]=$(curl -fsSL "https://get.helm.sh/helm-v${new[helm_version]:-}-linux-amd64.tar.gz.sha256sum" | cut -d' ' -f1)

for tool in runner kubectl helm kustomize yq; do
  [[ "${new[${tool}_version]:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    { echo "No version found for $tool: '${new[${tool}_version]:-}'" >&2; exit 1; }
  [[ "${new[${tool}_sha256]:-}" =~ ^[0-9a-f]{64}$ ]] ||
    { echo "No SHA-256 found for $tool ${new[${tool}_version]}" >&2; exit 1; }
done

# Replace the default of each variable block.
for name in "${!new[@]}"; do
  sed -i "/^variable \"$name\" {/,/^}/ s/^\(  default *= *\)\".*\"/\1\"${new[$name]}\"/" "$hcl"
done

if git diff --quiet -- "$hcl"; then
  echo "All tool versions are up to date."
else
  git --no-pager diff -U0 -- "$hcl" | grep -E '^[-+] ' || true
fi
