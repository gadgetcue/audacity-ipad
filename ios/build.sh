#!/usr/bin/env bash
# Builds the Rust static library for device + simulator and generates the Xcode project.
# Usage (macOS with Xcode, rustup and xcodegen): ios/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export IPHONEOS_DEPLOYMENT_TARGET=15.0
rustup target add aarch64-apple-ios aarch64-apple-ios-sim >/dev/null
cargo build --release --locked -p soundcue-ios --target aarch64-apple-ios 2>/dev/null || cargo build --release -p soundcue-ios --target aarch64-apple-ios
cargo build --release -p soundcue-ios --target aarch64-apple-ios-sim
mkdir -p ios/build/rust/device ios/build/rust/sim
cp target/aarch64-apple-ios/release/libsoundcue_ios.a ios/build/rust/device/
cp target/aarch64-apple-ios-sim/release/libsoundcue_ios.a ios/build/rust/sim/
cd ios && xcodegen generate
