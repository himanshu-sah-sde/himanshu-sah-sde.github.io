#!/usr/bin/env bash
set -e

IMAGE_NAME="personal-website"
CONTAINER_NAME="personal-website-dev"

# Stop existing container if running
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Build the image
docker build -t "$IMAGE_NAME" .

# Run with live reload and volume mount for hot reloading
docker run --name "$CONTAINER_NAME" \
  -p 4000:4000 \
  -p 35729:35729 \
  -v "$(pwd)":/site \
  "$IMAGE_NAME"
