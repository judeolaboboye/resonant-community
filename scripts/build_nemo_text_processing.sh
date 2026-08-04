#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_REPO="https://github.com/FluidInference/text-processing-rs"
UPSTREAM_REV="1b90efaef7585d9f07d0074eb4dd7b5232eb3c3d"
RUST_TOOLCHAIN="1.92.0"
WORK_DIR="$(mktemp -d)"
REPO_DIR="$WORK_DIR/text-processing-rs"
BUILD_DIR="$WORK_DIR/build"
OUTPUT_PATH="$ROOT_DIR/Vendor/NemoTextProcessing.xcframework"

trap 'rm -rf "$WORK_DIR"' EXIT

git clone "$UPSTREAM_REPO" "$REPO_DIR"
git -C "$REPO_DIR" checkout "$UPSTREAM_REV"

# Keep compiler and registry paths neutral so the distributed archive does not
# embed a maintainer's username or home directory.
export RUSTUP_HOME="${RESONANT_RUSTUP_HOME:-/tmp/resonant-rustup}"
export CARGO_HOME="${RESONANT_CARGO_HOME:-/tmp/resonant-cargo}"
rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
rustup target add --toolchain "$RUST_TOOLCHAIN" aarch64-apple-darwin x86_64-apple-darwin
export RUSTFLAGS="--remap-path-prefix=$WORK_DIR=/build --remap-path-prefix=$RUSTUP_HOME=/rustup --remap-path-prefix=$CARGO_HOME=/cargo -C debuginfo=0 ${RUSTFLAGS:-}"

cargo +"$RUST_TOOLCHAIN" build --locked --release --features ffi --target aarch64-apple-darwin --manifest-path "$REPO_DIR/Cargo.toml"
cargo +"$RUST_TOOLCHAIN" build --locked --release --features ffi --target x86_64-apple-darwin --manifest-path "$REPO_DIR/Cargo.toml"

mkdir -p "$BUILD_DIR"
lipo -create \
    "$REPO_DIR/target/aarch64-apple-darwin/release/libtext_processing_rs.a" \
    "$REPO_DIR/target/x86_64-apple-darwin/release/libtext_processing_rs.a" \
    -output "$BUILD_DIR/libtext_processing_rs.a"

rm -rf "$OUTPUT_PATH"
xcodebuild -create-xcframework \
    -library "$BUILD_DIR/libtext_processing_rs.a" \
    -headers "$REPO_DIR/swift/include" \
    -output "$OUTPUT_PATH"

if strings "$OUTPUT_PATH/macos-arm64_x86_64/libtext_processing_rs.a" | grep -Eq '/Users/[^/]+'; then
    echo "Error: rebuilt archive contains a personal macOS home path" >&2
    exit 1
fi

echo "$OUTPUT_PATH"
