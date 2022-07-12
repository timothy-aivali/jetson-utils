ARG BASE_IMAGE=nvcr.io/nvidia/l4t-base:r32.7.1
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV SHELL /bin/bash

WORKDIR ./jetson-utils

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
            cmake libpython3-dev python3-numpy \
            libglew-dev glew-utils libgstreamer1.0-dev \
            libgstreamer-plugins-base1.0-dev libglib2.0-dev \
            dialog qtbase5-dev
    && rm -rf /var/lib/apt/lists/*

COPY . .

RUN mkdir build && \
    cd build && \
    cmake ../ && \
    make -j$(nproc) && \
    make install && \
    rm -rf /var/lib/apt/lists/*