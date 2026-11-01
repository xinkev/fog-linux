# SPDX-License-Identifier: GPL-2.0-only
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross \
    device-tree-compiler \
    cpio gzip xz-utils \
    python3 \
    git make bc bison flex \
    libssl-dev libelf-dev openssl \
    rsync file zip unzip \
    ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
