#!/usr/bin/env bash
set -euo pipefail

# Customise via env
INDEX_URL="${INDEX_URL:-https://rocm.nightlies.amd.com/v2/gfx1151/}"
LLAMA_REPO="${LLAMA_REPO:-https://github.com/ROCm/llama.cpp.git}"
LLAMA_BRANCH="${LLAMA_BRANCH:-amd-integration}"
LLAMA_DIR="${LLAMA_DIR:-llama.cpp-rocm}"
GPU_ARCH="${GPU_ARCH:-gfx1151}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

echo "=== ROCm TheRock + llama.cpp (HIP via Clang) ==="

mkdir -p test && cd test
uv venv
source ./.venv/bin/activate

# ROCm toolchain (venv-local) + build helpers
uv pip install --index-url "$INDEX_URL" "rocm[libraries,devel]"
uv pip install ninja cmake

# Discover ROCm paths from the venv
ROCM_ROOT="$(python - <<'PY'
import subprocess,sys; print(subprocess.check_output(
  [sys.executable,"-P","-m","rocm_sdk","path","--root"], text=True).strip())
PY
)"
ROCM_BIN="$(python - <<'PY'
import subprocess,sys; print(subprocess.check_output(
  [sys.executable,"-P","-m","rocm_sdk","path","--bin"], text=True).strip())
PY
)"
LLVM_BIN="${ROCM_ROOT}/lib/llvm/bin"
ROCM_CMAKE="${ROCM_ROOT}/lib/cmake"
ROCM_BC="${ROCM_ROOT}/lib/llvm/amdgcn/bitcode"

# Export so CMake/Clang find ROCm inside the venv (no /opt/rocm)
export HIP_PLATFORM=amd
export ROCM_PATH="$ROCM_ROOT"
export HIP_PATH="$ROCM_ROOT"
export HIP_CLANG_PATH="$LLVM_BIN"
export HIP_DEVICE_LIB_PATH="$ROCM_BC"
export PATH="$ROCM_BIN:$LLVM_BIN:$PATH"
export LD_LIBRARY_PATH="${ROCM_ROOT}/lib:${ROCM_ROOT}/lib64:${LD_LIBRARY_PATH:-}"
export CMAKE_PREFIX_PATH="${ROCM_CMAKE}:${CMAKE_PREFIX_PATH:-}"
export AMDGPU_TARGETS="${GPU_ARCH}"
export GPU_TARGETS="${GPU_ARCH}"

# Clone / update llama.cpp
if [[ ! -d "$LLAMA_DIR" ]]; then
  git clone --depth=1 --branch "$LLAMA_BRANCH" "$LLAMA_REPO" "$LLAMA_DIR"
else
  (cd "$LLAMA_DIR" && git fetch origin "$LLAMA_BRANCH" && git reset --hard "origin/$LLAMA_BRANCH")
fi

cd "$LLAMA_DIR"
rm -rf build

cmake -S . -B build -G Ninja \
  -DGGML_HIP=ON \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DCMAKE_C_COMPILER="${LLVM_BIN}/clang" \
  -DCMAKE_CXX_COMPILER="${LLVM_BIN}/clang++" \
  -DCMAKE_HIP_ARCHITECTURES="${GPU_ARCH}" \
  -DCMAKE_HIP_FLAGS="--rocm-path=${ROCM_ROOT} --rocm-device-lib-path=${ROCM_BC}"

cmake --build build -- -j"$(nproc)"

echo
echo "✅ llama.cpp bult ok ; binaries at: $(pwd)/build/bin"

echo "=== Creating utility to activate environment ==="
cat > test/.venv/bin/activate-rocm <<'EOF'
#!/usr/bin/env bash
ROCM_ROOT="$(python - <<'PY'
import subprocess,sys
print(subprocess.check_output([sys.executable,"-P","-m","rocm_sdk","path","--root"], text=True).strip())
PY
)"
export ROCM_PATH="$ROCM_ROOT"
export HIP_PATH="$ROCM_ROOT"
export PATH="$ROCM_ROOT/bin:$ROCM_ROOT/lib/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$ROCM_ROOT/lib:$ROCM_ROOT/lib64:${LD_LIBRARY_PATH:-}"
export HIP_DEVICE_LIB_PATH="$ROCM_ROOT/lib/llvm/amdgcn/bitcode"
export AMDGPU_TARGETS="${AMDGPU_TARGETS:-gfx1151}"
export GPU_TARGETS="${GPU_TARGETS:-gfx1151}"
export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"
echo "✓ ROCm env ready at: $ROCM_ROOT"
EOF

echo "✅ all set -- run source test/.venv/bin.activate && source test/.venv/bin/activate-rocm to use your build"