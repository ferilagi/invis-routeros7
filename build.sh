#!/bin/bash

docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg ROUTEROS_VERSION="7.20.4" \
    -t ferilagi/ros7:7.20.4 \
    -t ferilagi/ros7:latest \
    --push .