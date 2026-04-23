#!/usr/bin/env bash
set -euo pipefail

if ! gh auth status >/dev/null 2>&1; then
  echo "PUBLISH=1 but gh is not authenticated"
  exit 1
fi

docker_login_info=`jq '.auths | length' ~/.docker/config.json`
if [ $docker_login_info -eq 0 ]; then
  echo "PUBLISH=1 but docker not authenticated"
  exit 1
fi

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

release_asset_exists() {
  local filename="$1"
  local url="https://github.com/binary-person/truenas-nvidia-raw-builder/releases/download/builds/$filename"

  curl -fsIL -o /dev/null "$url"
}

needs_any_nvidia_build() {
  local truenas_version="$1"
  local nvidia_version
  local module_type
  local filename

  for nvidia_version in "${nvidia_versions[@]}"; do
    for module_type in "${module_types[@]}"; do
      filename="truenas-${truenas_version}-nvidia-${nvidia_version}-${module_type}.raw"

      if ! release_asset_exists "$filename"; then
        echo "Missing: $filename"
        return 0
      fi
    done
  done

  return 1
}

run_builds() {
  local train="$1"
  shift

  for truenas_version in "$@"; do
    if ! needs_any_nvidia_build "$truenas_version"; then
      echo "All NVIDIA assets already exist for TrueNAS $truenas_version, skipping"
      continue
    fi

    TRUENAS_VERSION="$truenas_version" \
    TRUENAS_TRAIN="$train" \
    PUBLISH="1" \
    ./devops-build-script-combined.sh

    for nvidia_version in "${nvidia_versions[@]}"; do
      for module_type in "${module_types[@]}"; do
        local filename="truenas-${truenas_version}-nvidia-${nvidia_version}-${module_type}.raw"
        if release_asset_exists "$filename"; then
          echo "Already released: $filename, skipping"
          continue
        fi

        TRUENAS_VERSION="$truenas_version" \
        NVIDIA_VERSION="$nvidia_version" \
        NVIDIA_MODULE_TYPE="$module_type" \
        USE_TMP_DIR=1 \
        PUBLISH=1 \
        ./devops-nvidia.sh
      done
    done

    wait

    docker rmi binaryperson/truenas-nvidia-raw-builder-base:$truenas_version
    docker rmi binaryperson/truenas-nvidia-raw-builder:$truenas_version
    docker system prune --force
  done
}


nvidia_versions=(
  "575.64.05"
  "580.142"
  "595.58.03"
)

module_types=(
  "proprietary"
  "open"
)

mapfile -t fangtooth_versions < <(get_truenas_versions "25.04" "25.04.1")
mapfile -t goldeye_versions   < <(get_truenas_versions "25.10" "25.10.2")

run_builds "TrueNAS-SCALE-Fangtooth" "${fangtooth_versions[@]}"
run_builds "TrueNAS-SCALE-Goldeye" "${goldeye_versions[@]}"
