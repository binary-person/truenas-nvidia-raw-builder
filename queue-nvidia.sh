#!/bin/bash

# curated to optimize for the most useful nvidia versions
# 575.64.05 - cuda 12.9 (cuda 12.9 is >=575.57.08 and <580.65.06)
# 580.142 - cuda 13.0, 580.x is last version of pascal
# 595.58.03 - cuda 13.2, latest production version as of this writing

# latest - https://www.nvidia.com/en-us/drivers/unix/

# driver version to cuda mapping
# https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/#id7


# amount of different versions: truenas version * driver * open/proprietary

truenas_versions=(
  "25.04.2.6"
)

nvidia_versions=(
  "575.64.05"
  "580.142"
  "595.58.03"
)

module_types=(
  "proprietary"
  "open"
)

for truenas_version in "${truenas_versions[@]}"; do
  for nvidia_version in "${nvidia_versions[@]}"; do
    for module_type in "${module_types[@]}"; do
      TRUENAS_VERSION="$truenas_version" \
      NVIDIA_VERSION="$nvidia_version" \
      NVIDIA_MODULE_TYPE="$module_type" \
      ./devops-nvidia.sh
    done
  done
done
