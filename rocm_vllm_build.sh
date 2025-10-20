#!/usr/bin/env bash
set -euo pipefail

# Customise via env
INDEX_URL="${INDEX_URL:-https://rocm.nightlies.amd.com/v2/gfx1151/}"
VLLM_REPO="${VLLM_REPO:-https://github.com/vllm-project/vllm.git}"
VLLM_BRANCH="${VLLM_BRANCH:-main}"
VLLM_DIR="${VLLM_DIR:-vllm}"
GPU_ARCH="${GPU_ARCH:-gfx1151}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

echo "=== ROCm TheRock + vLLM Build ==="

mkdir -p test && cd test
uv venv
source ./.venv/bin/activate

# Core deps + ROCm toolchain
uv pip install --index-url "$INDEX_URL" "rocm[libraries,devel]"
uv pip install ninja cmake wheel pybind11
uv pip install --index-url "$INDEX_URL" torch torchvision
# Fix numpy version compatibility (numba requires <2.2)
uv pip install "numpy>=1.26,<2.2"
# Misc dependencies
uv pip install --upgrade numba scipy huggingface-hub[cli]

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
export PYTORCH_ROCM_ARCH="${GPU_ARCH}"
export TRITON_HIP_LLD_PATH="${LLVM_BIN}/ld.lld"
export HIP_VISIBLE_DEVICES="0"
export AMD_SERIALIZE_KERNEL="3"

# Clone / update vLLM
if [[ ! -d "$VLLM_DIR" ]]; then
  git clone --branch "$VLLM_BRANCH" "$VLLM_REPO" "$VLLM_DIR"
else
  (cd "$VLLM_DIR" && git fetch origin "$VLLM_BRANCH" && git reset --hard "origin/$VLLM_BRANCH")
fi

cd "$VLLM_DIR"

# Run use_existing_torch.py to configure for our PyTorch build
python use_existing_torch.py

# Apply gfx1151 patches
echo "=== Applying gfx1151 Patches ==="

# Add gfx1151 to CMakeLists.txt
echo "Adding gfx1151 to CMakeLists.txt..."
if ! grep -q "gfx1151" CMakeLists.txt; then
  sed -i 's/set(HIP_SUPPORTED_ARCHS "gfx906;gfx908;gfx90a;gfx942;gfx950;gfx1030;gfx1100;gfx1101;gfx1200;gfx1201")/set(HIP_SUPPORTED_ARCHS "gfx906;gfx908;gfx90a;gfx942;gfx950;gfx1030;gfx1100;gfx1101;gfx1151;gfx1200;gfx1201")/' CMakeLists.txt
  echo "✅ Added gfx1151 to CMakeLists.txt"
else
  echo "✅ gfx1151 already present in CMakeLists.txt"
fi

# Remove torch dependency from pyproject.toml
echo "Removing torch dependency from pyproject.toml..."
sed -i '/torch == 2.8.0,/d' pyproject.toml || true
echo "✅ Removed torch dependency from pyproject.toml"

# Remove amdsmi from rocm-build.txt (causes segfaults on gfx1151)
echo "Removing amdsmi from requirements..."
sed -i '/amdsmi==/d' requirements/rocm-build.txt || true
uv pip install -r requirements/rocm-build.txt

# Patch ROCm platform detection to use torch instead of amdsmi
echo "Patching ROCm platform detection..."
if ! grep -q "torch.version.hip" vllm/platforms/__init__.py; then
  # Replace amdsmi-based detection with torch-based detection
  sed -i '/def rocm_platform_plugin/,/return "vllm.platforms.rocm.RocmPlatform"/c\
def rocm_platform_plugin() -> str | None:\
    import torch\
    is_rocm = hasattr(torch, "version") and hasattr(torch.version, "hip") and torch.version.hip\
    return "vllm.platforms.rocm.RocmPlatform" if is_rocm else None' vllm/platforms/__init__.py
  echo "✅ Patched ROCm platform detection"
else
  echo "✅ ROCm platform detection already patched"
fi

echo "✅ All gfx1151 patches applied"

# Build vLLM with ROCm target device
echo ""
echo "=== Building vLLM ==="

# Get current torch version for constraints
TORCH_VERSION=$(python -c "import torch; print(torch.__version__)" 2>/dev/null || echo "unknown")
echo "Current PyTorch version: $TORCH_VERSION"

# Create constraints file to preserve ROCm torch
echo "torch==$TORCH_VERSION" > /tmp/vllm-constraints.txt
echo "Installing vLLM with constraints to preserve ROCm torch..."

VLLM_TARGET_DEVICE=rocm uv pip install -e . --no-build-isolation --constraint /tmp/vllm-constraints.txt

rm -f /tmp/vllm-constraints.txt

# Final numpy version check
uv pip install "numpy>=1.26,<2.2"

cd ..

echo
echo "✅ vLLM built ok"

echo "=== Creating utility to activate environment ==="
cat > ./.venv/bin/activate-rocm <<'EOF'
#!/usr/bin/env bash
ROCM_ROOT="$(python - <<'PY'
import subprocess,sys
print(subprocess.check_output([sys.executable,"-P","-m","rocm_sdk","path","--root"], text=True).strip())
PY
)"
ROCM_BIN="$(python - <<'PY'
import subprocess,sys
print(subprocess.check_output([sys.executable,"-P","-m","rocm_sdk","path","--bin"], text=True).strip())
PY
)"
LLVM_BIN="${ROCM_ROOT}/lib/llvm/bin"

export HIP_PLATFORM=amd
export ROCM_PATH="$ROCM_ROOT"
export HIP_PATH="$ROCM_ROOT"
export HIP_CLANG_PATH="$LLVM_BIN"
export HIP_DEVICE_LIB_PATH="$ROCM_ROOT/lib/llvm/amdgcn/bitcode"
export PATH="$ROCM_BIN:$LLVM_BIN:$PATH"
export LD_LIBRARY_PATH="$ROCM_ROOT/lib:$ROCM_ROOT/lib64:${LD_LIBRARY_PATH:-}"
export AMDGPU_TARGETS="${AMDGPU_TARGETS:-gfx1151}"
export GPU_TARGETS="${GPU_TARGETS:-gfx1151}"
export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0}"
export AMD_SERIALIZE_KERNEL="3"
export TRITON_HIP_LLD_PATH="$LLVM_BIN/ld.lld"
echo "✅ ROCm env ready at: $ROCM_ROOT"
EOF

chmod +x ./.venv/bin/activate-rocm

echo "✅ all set -- run 'source test/.venv/bin/activate && source test/.venv/bin/activate-rocm' to use your build"
echo ""
echo "To test vLLM:"
echo "  python -c \"import vllm; print('vLLM version:', vllm.__version__)\""
echo ""
echo "To run vLLM server (use --enforce-eager to disable torch.compile): "
echo "vllm serve Qwen/Qwen3-1.7B --gpu-memory-utilization 0.75 --enforce-eager"
