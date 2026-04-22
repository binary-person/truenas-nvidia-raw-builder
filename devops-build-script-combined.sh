#!/bin/bash

set -e

# login
# docker login
if [[ "$PUBLISH" == "1" ]]; then
  docker_login_info=`jq '.auths | length' ~/.docker/config.json`
  if [ $docker_login_info -eq 0 ]; then
    echo "PUBLISH=1 but docker not authenticated"
    exit 1
  fi
fi

if ! docker buildx inspect "insecure-builder" >/dev/null 2>&1; then
  echo "Creating buildx builder: insecure-builder"
  docker buildx create --use --name insecure-builder --driver docker-container --buildkitd-flags '--allow-insecure-entitlement security.insecure'
fi

TRUENAS_VERSION=${TRUENAS_VERSION-25.04.0}
TRUENAS_TRAIN=${TRUENAS_TRAIN-TrueNAS-SCALE-Fangtooth}
# 25.10 is TrueNAS-SCALE-Goldeye

PUSH_ALSO="--load"

if [[ "$PUBLISH" == "1" ]]; then
  PUSH_ALSO="--load --push"
fi

echo "Building for truenas $TRUENAS_VERSION"

# build base image

if 2>/dev/null 1>&2 docker manifest inspect binaryperson/truenas-nvidia-raw-builder-base:$TRUENAS_VERSION; then
  echo "Base image already exists, pulling"
  docker pull binaryperson/truenas-nvidia-raw-builder-base:$TRUENAS_VERSION
else
  docker buildx build --builder insecure-builder --allow security.insecure -f Dockerfile.base \
    --build-arg TRUENAS_VERSION=$TRUENAS_VERSION \
    --build-arg TRUENAS_TRAIN=$TRUENAS_TRAIN --progress=plain $PUSH_ALSO \
    -t binaryperson/truenas-nvidia-raw-builder-base:$TRUENAS_VERSION .
    # don't need build cache after built because we can't reuse it for other truenas versions
    docker buildx prune --builder insecure-builder -a --force
fi

# build final image with nvidia script

if 2>/dev/null 1>&2 docker manifest inspect binaryperson/truenas-nvidia-raw-builder:$TRUENAS_VERSION; then
  echo "Image already exists, pulling"
  docker pull binaryperson/truenas-nvidia-raw-builder:$TRUENAS_VERSION
else
  # build
  docker build --progress=plain \
    --build-arg TRUENAS_VERSION=$TRUENAS_VERSION \
    -t binaryperson/truenas-nvidia-raw-builder:$TRUENAS_VERSION .

  # push
  if [[ "$PUBLISH" == "1" ]]; then
    docker push binaryperson/truenas-nvidia-raw-builder:$TRUENAS_VERSION
  fi
fi
