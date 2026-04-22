#!/bin/bash

set -e

# login
# docker login

# run this once
# docker buildx create --use --name insecure-builder --driver docker-container --buildkitd-flags '--allow-insecure-entitlement security.insecure'

TRUENAS_VERSION=${TRUENAS_VERSION-25.04.2.6}

echo "Building for truenas $TRUENAS_VERSION"

if [[ "$PUBLISH" == "1" ]]; then
  if 2>/dev/null 1>&2 docker manifest inspect binaryperson/truenas-nvidia-raw-builder:$TRUENAS_VERSION; then
    echo "Image already exists"
    exit
  fi
fi

# build
docker build --progress=plain \
  --build-arg TRUENAS_VERSION=$TRUENAS_VERSION \
  -t binaryperson/truenas-nvidia-raw-builder:$TRUENAS_VERSION .

# push

if [[ "$PUBLISH" == "1" ]]; then
  docker push binaryperson/truenas-nvidia-raw-builder:$TRUENAS_VERSION
  # docker system prune -a --force
fi
