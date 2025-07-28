#!/usr/bin/env bash
set -x
__DIR="$(dirname "$(realpath "$0")")"
if ! command -v shfmt &> /dev/null; then
  echo "Installing shfmt..."
  sleep 1
  sudo apt-get -qq update && sudo apt-get -qq install -y shfmt
fi
find "$__DIR" -name "*.sh" -exec shfmt -w -i 2 -ci -sr -bn {} + -sr -bn {} +
