#!/usr/bin/env bash
# Build local image for Pterodactyl (matches egg docker_images tags).
# Usage: ./scripts/build-image.sh 8.4
set -euo pipefail
PHP_VERSION="${1:-8.4}"
IMAGE="mediawiki-pterodactyl-egg:${PHP_VERSION}-latest"
docker build --build-arg "PHP_VERSION=${PHP_VERSION}" -t "${IMAGE}" .
echo "Built ${IMAGE}"
echo "Select this image in your server Startup tab (Docker Image)."
