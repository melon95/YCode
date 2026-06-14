#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
docker_config="$repo_root/e2e/.tmp/docker-config"
mkdir -p "$docker_config"
printf '{"auths":{}}\n' > "$docker_config/config.json"

docker_args=(run --rm)
if [ -t 0 ]; then
  docker_args+=(-it)
fi
if [ -n "${E2E_SKIP_BUILD:-}" ]; then
  docker_args+=(-e "E2E_SKIP_BUILD=$E2E_SKIP_BUILD")
fi

DOCKER_CONFIG="$docker_config" docker "${docker_args[@]}" \
  --shm-size=2g \
  -v "$repo_root":/work \
  -v ycode-e2e-node-modules:/work/node_modules \
  -v ycode-e2e-cargo-registry:/root/.cargo/registry \
  -v ycode-e2e-cargo-git:/root/.cargo/git \
  -v ycode-e2e-cargo-bin:/root/.cargo/bin \
  -v ycode-e2e-rustup:/root/.rustup \
  -w /work \
  node:20-bookworm \
  bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      libwebkit2gtk-4.1-dev \
      build-essential \
      curl wget file \
      libxdo-dev \
      libssl-dev \
      libayatana-appindicator3-dev \
      librsvg2-dev \
      webkit2gtk-driver \
      desktop-file-utils \
      dbus-x11 \
      xdg-utils \
      xvfb \
      xauth \
      pkg-config \
      ca-certificates
    export PATH="$HOME/.cargo/bin:$PATH"
    if ! command -v cargo >/dev/null 2>&1; then
      curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable
    fi
    if ! command -v tauri-driver >/dev/null 2>&1; then
      cargo install tauri-driver --locked
    fi
    npm ci
    xvfb-run -a npm run test:e2e
  '
