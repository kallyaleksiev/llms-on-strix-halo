#!/usr/bin/env bash
set -euo pipefail

# Customise via env
BUILD_TYPE="${BUILD_TYPE:-Release}"

# export AMD_VULKAN_ICD=RADV

echo "=== Vulkan + llama.cpp Build ==="

# Install dependencies
echo "Installing dependencies..."
sudo dnf -y install git cmake ninja-build pkgconf-pkg-config libcurl-devel
sudo dnf -y install vulkan-tools vulkan-loader mesa-vulkan-drivers \
                    vulkan-loader-devel vulkan-headers
sudo dnf -y install glslc glslang spirv-tools python3 python3-pip

# Clone llama.cpp
git clone https://github.com/ggml-org/llama.cpp/ llama.cpp-vulkan

cd llama.cpp-vulkan
rm -rf build

# Configure with Vulkan support
cmake -S . -B build -G Ninja \
  -DGGML_VULKAN=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE"

# Build
ninja -C build

echo
echo "✅ llama.cpp built with Vulkan support; binaries at: $(pwd)/build/bin"
