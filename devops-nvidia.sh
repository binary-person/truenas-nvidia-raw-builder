#!/bin/bash

set -e

# gh auth login
if [[ "$PUBLISH" == "1" ]]; then
  if ! gh auth status >/dev/null 2>&1; then
    echo "PUBLISH=1 but gh is not authenticated"
    exit 1
  fi
fi


TRUENAS_VERSION=${TRUENAS_VERSION-25.04.2.6}
NVIDIA_MODULE_TYPE=${NVIDIA_MODULE_TYPE-proprietary}
NVIDIA_VERSION=${NVIDIA_VERSION-580.142}
USE_TMP_DIR=${USE_TMP_DIR-0}

NVIDIA_RUN_URL=https://download.nvidia.com/XFree86/Linux-x86_64/$NVIDIA_VERSION/NVIDIA-Linux-x86_64-$NVIDIA_VERSION.run
NVIDIA_FILE=truenas-$TRUENAS_VERSION-nvidia-$NVIDIA_VERSION-$NVIDIA_MODULE_TYPE.raw

OUT_DIR="$OUT_DIR"

if [[ "$USE_TMP_DIR" == "1" ]]; then
  mkdir -p tmp
  OUT_DIR=$(mktemp -d ./tmp/out-XXXXXXXXXX)
fi

if [ -f "$PWD/$NVIDIA_FILE" ]; then
  echo "Already exists: $PWD/$NVIDIA_FILE"
  exit
fi

echo "Building for truenas $TRUENAS_VERSION"
echo "Building for nvidia driver $NVIDIA_VERSION ($NVIDIA_MODULE_TYPE)"

echo "Checking nvidia driver exists"
curl -I $NVIDIA_RUN_URL

docker run --rm --privileged \
  -e NVIDIA_DRIVER_RUN_URL="$NVIDIA_RUN_URL" \
  -e NVIDIA_KERNEL_MODULE_TYPE=$NVIDIA_MODULE_TYPE \
  -v "$OUT_DIR:/out" \
  binaryperson/truenas-nvidia-raw-builder:$TRUENAS_VERSION

echo "Built .raw. Renaming, putting in cwd, and cleaning up"

mv "$OUT_DIR/nvidia.raw" truenas-$TRUENAS_VERSION-nvidia-$NVIDIA_VERSION-$NVIDIA_MODULE_TYPE.raw

if [[ "$USE_TMP_DIR" == "1" ]]; then
  rm -rf "$OUT_DIR"
else
  rm "$OUT_DIR/nvidia.raw"
  rm "$OUT_DIR/nvidia.raw.sha256"
  rm "$OUT_DIR/rootfs.squashfs"
fi

if [[ "$PUBLISH" == "1" ]]; then
  gh release upload "builds" \
    "truenas-$TRUENAS_VERSION-nvidia-$NVIDIA_VERSION-$NVIDIA_MODULE_TYPE.raw" \
    -R "https://github.com/binary-person/truenas-nvidia-raw-builder"
  rm "truenas-$TRUENAS_VERSION-nvidia-$NVIDIA_VERSION-$NVIDIA_MODULE_TYPE.raw"
fi
