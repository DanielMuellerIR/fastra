FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
ARG DEBIAN_FRONTEND=noninteractive
ARG RUST_VERSION=1.99.1
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl pkg-config python3 file binutils \
    libgtk-4-dev libgtksourceview-5-dev libwebkitgtk-6.0-dev dpkg-dev xz-utils xvfb xauth dbus-x11 \
    bubblewrap util-linux imagemagick librsvg2-bin poppler-utils \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
RUN curl --proto '=https' --tlsv1.2 -fsS https://sh.rustup.rs -o /tmp/rustup-init.sh \
    && sh /tmp/rustup-init.sh -y --profile minimal --default-toolchain ${RUST_VERSION} \
    && rm /tmp/rustup-init.sh
ENV PATH=/opt/cargo/bin:$PATH
WORKDIR /src
