#!/bin/bash

set -e

# login
# docker login

if ! docker buildx inspect "insecure-builder" >/dev/null 2>&1; then
  echo "Creating buildx builder: insecure-builder"
  docker buildx create --use --name insecure-builder --driver docker-container --buildkitd-flags '--allow-insecure-entitlement security.insecure'
fi

TRUENAS_VERSION=${TRUENAS_VERSION-25.04.0}
TRUENAS_TRAIN=${TRUENAS_TRAIN-TrueNAS-SCALE-Fangtooth}
# 25.10 is TrueNAS-SCALE-Goldeye

PUSH_OR_LOAD="load"

if [[ "$PUBLISH" == "1" ]]; then
  PUSH_OR_LOAD="push"
fi

echo "Building for truenas $TRUENAS_VERSION"

if [[ "$PUBLISH" == "1" ]]; then
  if 2>/dev/null 1>&2 docker manifest inspect binaryperson/truenas-nvidia-raw-builder-base:$TRUENAS_VERSION; then
    echo "Image already exists"
    exit
  fi
fi

# build
docker buildx build --builder insecure-builder --allow security.insecure -f Dockerfile.base \
  --build-arg TRUENAS_VERSION=$TRUENAS_VERSION \
  --build-arg TRUENAS_TRAIN=$TRUENAS_TRAIN --progress=plain --$PUSH_OR_LOAD \
  -t binaryperson/truenas-nvidia-raw-builder-base:$TRUENAS_VERSION .

# clean up
docker buildx prune --builder insecure-builder -a --force
