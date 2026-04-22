#!/usr/bin/env bash
set -euo pipefail

RELEASE_API_URL="${RELEASE_API_URL:-https://api.github.com/repos/binary-person/truenas-nvidia-raw-builder/releases/tags/builds}"
SYSEXT_DIR="${SYSEXT_DIR:-/usr/share/truenas/sysext-extensions}"
TARGET_RAW="${SYSEXT_DIR}/nvidia.raw"
BACKUP_RAW="${SYSEXT_DIR}/nvidia.raw.bak"

declare -A ASSET_URLS=()
declare -A ASSET_NAMES=()

TMP_RAW=""
USR_DATASET=""
USR_READONLY_ORIGINAL=""
USR_READONLY_CHANGED=0
DOCKER_NVIDIA_TOGGLED=0
SYSEXT_UNMERGED=0
ROLLBACK_BACKUP_TO_TARGET=0

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

cleanup() {
  local exit_code=$?

  if [[ -n "$TMP_RAW" && -f "$TMP_RAW" ]]; then
    rm -f "$TMP_RAW"
  fi

  if (( exit_code != 0 )); then
    if (( ROLLBACK_BACKUP_TO_TARGET == 1 )) && [[ -f "$BACKUP_RAW" && ! -f "$TARGET_RAW" ]]; then
      mv "$BACKUP_RAW" "$TARGET_RAW" >/dev/null 2>&1 || true
    fi

    if (( USR_READONLY_CHANGED == 1 )) && [[ -n "$USR_DATASET" && -n "$USR_READONLY_ORIGINAL" ]]; then
      zfs set readonly="$USR_READONLY_ORIGINAL" "$USR_DATASET" >/dev/null 2>&1 || true
    fi

    if (( SYSEXT_UNMERGED == 1 )); then
      systemd-sysext merge >/dev/null 2>&1 || true
    fi

    if (( DOCKER_NVIDIA_TOGGLED == 1 )); then
      midclt call docker.update '{"nvidia": true}' >/dev/null 2>&1 || true
    fi
  fi

  exit "$exit_code"
}

trap cleanup EXIT

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "Run this script as root."
  fi
}

require_commands() {
  local cmd
  local required=(
    midclt
    jq
    curl
    rmmod
    zfs
    systemd-sysext
    systemctl
    install
    mktemp
    sort
  )

  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      fail "Required command not found: $cmd"
    fi
  done
}

detect_truenas_version() {
  local raw_version

  raw_version=$(midclt call system.info | jq -r '.version')
  if [[ -z "$raw_version" || "$raw_version" == "null" ]]; then
    fail "Failed to detect the current TrueNAS version."
  fi

  if [[ "$raw_version" =~ ^TrueNAS-SCALE-([0-9]+(\.[0-9]+)+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi

  if [[ "$raw_version" =~ ^([0-9]+(\.[0-9]+)+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi

  fail "This script only supports TrueNAS SCALE. Detected version: $raw_version"
}

fetch_release_assets() {
  local truenas_version="$1"
  local assets_json
  local name
  local url
  local driver
  local module_type
  local asset_version
  local key

  assets_json=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$RELEASE_API_URL") || fail "Failed to query the builds release. Check your network connection and try again."

  while IFS=$'\t' read -r name url; do
    [[ -n "$name" && -n "$url" ]] || continue

    if [[ "$name" =~ ^truenas-([0-9]+(\.[0-9]+)+)-nvidia-([0-9]+(\.[0-9]+)+)-(open|proprietary)\.raw$ ]]; then
      asset_version="${BASH_REMATCH[1]}"
      driver="${BASH_REMATCH[3]}"
      module_type="${BASH_REMATCH[5]}"

      [[ "$asset_version" == "$truenas_version" ]] || continue

      key="${driver}|${module_type}"
      ASSET_URLS["$key"]="$url"
      ASSET_NAMES["$key"]="$name"
    fi
  done < <(
    jq -r '.assets[]? | [.name, .browser_download_url] | @tsv' <<<"$assets_json"
  )

  if [[ ${#ASSET_URLS[@]} -eq 0 ]]; then
    fail "No release builds were found for TrueNAS ${truenas_version}."
  fi
}

choose_option() {
  local prompt="$1"
  shift

  local -a options=("$@")
  local selection
  local index

  if [[ ${#options[@]} -eq 0 ]]; then
    fail "No options are available for: $prompt"
  fi

  while :; do
    echo "$prompt" >&2
    for index in "${!options[@]}"; do
      printf '  [%d] %s\n' "$((index + 1))" "${options[index]}" >&2
    done

    read -r -p "Choose an option [1-${#options[@]}]: " selection
    if [[ ! "$selection" =~ ^[0-9]+$ ]]; then
      echo "Please enter a number." >&2
      continue
    fi

    if (( selection < 1 || selection > ${#options[@]} )); then
      echo "Please choose a number between 1 and ${#options[@]}." >&2
      continue
    fi

    printf '%s\n' "${options[selection - 1]}"
    return
  done
}

confirm() {
  local prompt="$1"
  local reply

  read -r -p "$prompt [y/N]: " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

get_driver_choices() {
  local key
  local driver
  local -A seen=()

  for key in "${!ASSET_URLS[@]}"; do
    driver="${key%%|*}"
    seen["$driver"]=1
  done

  printf '%s\n' "${!seen[@]}" | sort -V
}

get_module_choices() {
  local driver="$1"
  local -a choices=()
  local module_type

  for module_type in open proprietary; do
    if [[ -n "${ASSET_URLS[${driver}|${module_type}]:-}" ]]; then
      choices+=("$module_type")
    fi
  done

  printf '%s\n' "${choices[@]}"
}

prepare_usr_dataset() {
  if [[ -n "$USR_DATASET" ]]; then
    return
  fi

  USR_DATASET=$(zfs list -H -o name /usr)
  if [[ -z "$USR_DATASET" ]]; then
    fail "Failed to resolve the ZFS dataset backing /usr."
  fi

  USR_READONLY_ORIGINAL=$(zfs get -H -o value readonly "$USR_DATASET")
  if [[ "$USR_READONLY_ORIGINAL" != "on" && "$USR_READONLY_ORIGINAL" != "off" ]]; then
    fail "Failed to determine the readonly property for ${USR_DATASET}."
  fi
}

make_usr_writable() {
  prepare_usr_dataset

  if [[ "$USR_READONLY_ORIGINAL" == "on" ]]; then
    zfs set readonly=off "$USR_DATASET"
    USR_READONLY_CHANGED=1
  fi
}

restore_usr_readonly() {
  if (( USR_READONLY_CHANGED == 1 )); then
    zfs set readonly="$USR_READONLY_ORIGINAL" "$USR_DATASET"
    USR_READONLY_CHANGED=0
  fi
}

disable_nvidia_support() {
  midclt call docker.update '{"nvidia": false}' >/dev/null
  DOCKER_NVIDIA_TOGGLED=1
}

enable_nvidia_support() {
  midclt call docker.update '{"nvidia": true}' >/dev/null
  DOCKER_NVIDIA_TOGGLED=0
}

restart_docker_service() {
  if ! systemctl restart docker; then
    warn "Failed to restart docker. You may need to restart it manually."
  fi
}

unload_nvidia_modules() {
  local warn_failures="${1:-1}"
  local module
  local error_output

  for module in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    if ! error_output=$(rmmod "$module" 2>&1 >/dev/null); then
      if [[ "$error_output" == *"is not currently loaded"* ]]; then
        continue
      fi

      if [[ "$warn_failures" == "1" ]]; then
        if [[ -n "$error_output" ]]; then
          warn "$error_output"
        else
          warn "Could not unload kernel module: ${module}. This can be normal if it is still in use."
        fi
      fi
    fi
  done
}

unload_nvidia_modules_twice() {
  unload_nvidia_modules 0
  unload_nvidia_modules 1
}

unmerge_sysext() {
  systemd-sysext unmerge
  SYSEXT_UNMERGED=1
}

merge_sysext() {
  systemd-sysext merge
  SYSEXT_UNMERGED=0
}

download_asset() {
  local url="$1"
  local name="$2"

  TMP_RAW=$(mktemp "/tmp/${name}.XXXXXX")
  echo "Downloading ${name}..."
  curl -fL --progress-bar -o "$TMP_RAW" "$url" || fail "Failed to download ${name}."

  if [[ ! -s "$TMP_RAW" ]]; then
    fail "Downloaded file is empty: ${name}"
  fi
}

install_selected_driver() {
  local truenas_version="$1"
  local driver="$2"
  local module_type="$3"
  local key="${driver}|${module_type}"
  local asset_name="${ASSET_NAMES[$key]}"
  local asset_url="${ASSET_URLS[$key]}"

  if [[ -f "$BACKUP_RAW" ]]; then
    echo "Install will overwrite ${TARGET_RAW}."
    echo "Install will preserve  ${BACKUP_RAW}."
    if ! confirm "Continue with install?"; then
      echo "Install cancelled."
      return
    fi
  elif [[ ! -f "$TARGET_RAW" ]]; then
    fail "Could not find the current ${TARGET_RAW} to back up."
  fi

  echo "Selected TrueNAS version: ${truenas_version}"
  echo "Selected NVIDIA driver: ${driver}"
  echo "Selected module type: ${module_type}"

  download_asset "$asset_url" "$asset_name"

  disable_nvidia_support
  unmerge_sysext
  make_usr_writable

  if [[ ! -f "$BACKUP_RAW" ]]; then
    mv "$TARGET_RAW" "$BACKUP_RAW"
    ROLLBACK_BACKUP_TO_TARGET=1
  fi

  install -m 0644 "$TMP_RAW" "$TARGET_RAW"
  ROLLBACK_BACKUP_TO_TARGET=0

  restore_usr_readonly
  merge_sysext
  enable_nvidia_support
  unload_nvidia_modules_twice
  # restart_docker_service # handled already by "enable_nvidia_support"

  echo "Install complete."
  echo "Installed: ${asset_name}"
  echo "Run nvidia-smi to check updated version. If you see an NVRM API mismatch, try rebooting."
}

restore_original_driver() {
  if [[ ! -f "$BACKUP_RAW" ]]; then
    fail "Restore is unavailable because ${BACKUP_RAW} does not exist."
  fi

  echo "Restoring the original NVIDIA driver from ${BACKUP_RAW}."

  disable_nvidia_support
  unmerge_sysext
  make_usr_writable

  ROLLBACK_BACKUP_TO_TARGET=1
  rm -f "$TARGET_RAW"
  mv "$BACKUP_RAW" "$TARGET_RAW"
  ROLLBACK_BACKUP_TO_TARGET=0

  restore_usr_readonly
  merge_sysext
  enable_nvidia_support
  unload_nvidia_modules_twice
  # restart_docker_service # handled already by "enable_nvidia_support"

  echo "Restore complete."
  echo "Load the new drivers by running 'nvidia-smi'"
  echo "Check for nvidia driver errors by running 'dmesg -w'"
}

main() {
  local truenas_version
  local -a action_choices
  local action
  local -a driver_choices
  local driver
  local -a module_choices
  local module_type

  require_root
  require_commands

  truenas_version=$(detect_truenas_version)

  echo "Detected TrueNAS version: ${truenas_version}"
  if [[ -f "$BACKUP_RAW" ]]; then
    echo "Backup detected: ${BACKUP_RAW}"
  else
    echo "No backup detected yet."
  fi
  echo

  action_choices=("install" "restore")
  action=$(choose_option "What would you like to do?" "${action_choices[@]}")
  echo

  case "$action" in
    install)
      fetch_release_assets "$truenas_version"

      mapfile -t driver_choices < <(get_driver_choices)
      driver=$(choose_option "Which NVIDIA driver would you like to install?" "${driver_choices[@]}")
      echo

      mapfile -t module_choices < <(get_module_choices "$driver")
      module_type=$(choose_option "Which kernel module type would you like to install?" "${module_choices[@]}")
      echo

      install_selected_driver "$truenas_version" "$driver" "$module_type"
      ;;
    restore)
      restore_original_driver
      ;;
    *)
      fail "Unexpected action selected: $action"
      ;;
  esac
}

main "$@"
