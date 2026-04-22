#!/usr/bin/env bash

set -euo pipefail

get_truenas_versions() {
  local series="$1"
  local min_version="$2"
  local page=1
  local version
  local tags
  local count

  while :; do
    tags=$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2026-03-10" \
      "https://api.github.com/repos/truenas/scale-build/tags?per_page=100&page=$page")

    count=$(jq 'length' <<<"$tags")
    [ "$count" -eq 0 ] && break

    while IFS= read -r version; do
      case "$version" in
        "$series".*)
          if [ "$(printf '%s\n%s\n' "$min_version" "$version" | sort -V | head -n1)" = "$min_version" ]; then
            printf '%s\n' "$version"
          fi
          ;;
      esac
    done < <(
      jq -r '.[].name | select(test("^TS-[0-9]+(\\.[0-9]+)+$")) | sub("^TS-"; "")' <<<"$tags"
    )

    page=$((page + 1))
  done
}

run_builds() {
  for truenas_version in "$@"; do
    TRUENAS_VERSION="$truenas_version" PUBLISH=1 ./devops-build-script.sh
  done
}

mapfile -t fangtooth_versions < <(get_truenas_versions "25.04" "25.04.1")
mapfile -t goldeye_versions   < <(get_truenas_versions "25.10" "25.10.2")

run_builds "${fangtooth_versions[@]}"
run_builds "${goldeye_versions[@]}"
