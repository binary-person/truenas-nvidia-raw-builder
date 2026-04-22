ARG TRUENAS_VERSION=25.04.2.6

FROM binaryperson/truenas-nvidia-raw-builder-base:${TRUENAS_VERSION}

WORKDIR ${SCALE_BUILD_DIR}

COPY build-truenas-nvidia.sh /usr/local/bin/build-truenas-nvidia.sh
RUN chmod +x /usr/local/bin/build-truenas-nvidia.sh

VOLUME ["/out"]
ENTRYPOINT ["/usr/local/bin/build-truenas-nvidia.sh"]
