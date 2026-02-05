#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# OPAM Build Script
# ==============================================================================
# This script handles both native and cross-compilation builds of opam.
# For cross-compilation, it builds native tools first (dune, cppo, menhir),
# then swaps to cross-compilers for the main opam build.
# ==============================================================================

# Source helper functions
source "${RECIPE_DIR}/building/build_functions.sh"

# ==============================================================================

echo "=== PHASE 0: Environment Setup ==="

# REMOVED: DYLD_FALLBACK_LIBRARY_PATH workaround - ocaml 5.3.0 _10 has correct rpath for libzstd

if is_linux || is_macos; then
  export OPAM_INSTALL_PREFIX="${PREFIX}"
else
  export OPAM_INSTALL_PREFIX="${_PREFIX_}/Library"
  BZIP2=$(find ${_BUILD_PREFIX_} ${_PREFIX_} \( -name bzip2 -o -name bzip2.exe \) \( -type f -o -type l \) -perm /111 | head -1)
  export BUNZIP2="${BZIP2} -d"
  export CC64=false

  # Ensure OCaml binaries are in PATH for dune bootstrap
  export PATH="${BUILD_PREFIX}/bin:${BUILD_PREFIX}/Library/bin:${PATH}"
fi

if is_cross_compile; then
  # ==============================================================================
  # Cross-compilation setup for OCaml
  # ==============================================================================
  # When cross-compiling (build_platform != target_platform), we need to:
  # 1. Build dune with native compiler (it runs on build machine)
  # 2. Swap to cross-compiler for the main opam build

  source "${RECIPE_DIR}"/building/cross-compile.sh
else
  ./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps > /dev/null 2>&1 || { cat config.log; exit 1; }

  # ==============================================================================
  # Windows: Dune workarounds
  # ==============================================================================

  if is_non_unix; then
    apply_non_unix_workarounds
    patch -p1 -d src_ext/dune-local < "${RECIPE_DIR}/patches/xxxx-fix-dune-which-double-exe-on-windows.patch"
  fi

  # ==============================================================================
  echo "=== PHASE 3: Main Build ==="
  # ==============================================================================

  make
  make install
fi

echo "=== PHASE 4: Install Activation Scripts ==="
# Install conda activation/deactivation scripts for opam integration
ACTIVATE_DIR="${PREFIX}/etc/conda/activate.d"
DEACTIVATE_DIR="${PREFIX}/etc/conda/deactivate.d"
mkdir -p "${ACTIVATE_DIR}" "${DEACTIVATE_DIR}"

if is_linux || is_macos; then
  cp "${RECIPE_DIR}/activation/activate.sh" "${ACTIVATE_DIR}/opam-activate.sh"
  cp "${RECIPE_DIR}/activation/deactivate.sh" "${DEACTIVATE_DIR}/opam-deactivate.sh"
else
  cp "${RECIPE_DIR}/activation/activate.bat" "${ACTIVATE_DIR}/opam-activate.bat"
  cp "${RECIPE_DIR}/activation/deactivate.bat" "${DEACTIVATE_DIR}/opam-deactivate.bat"
fi

echo "=== PHASE 5: Initialize opam root ==="
OPAMROOT="${OPAM_INSTALL_PREFIX}/share/opam"

if is_cross_compile || is_non_unix; then
  # Cross-compile: can't run target opam binary on build machine (QEMU segfaults
  # with OCaml 5.x GC). Windows: opam init fails with "Unix infrastructure" error.
  # Create the opam root structure manually instead.
  source "${RECIPE_DIR}/building/opam_root_init.sh"
  create_opam_root "${OPAMROOT}" "${OPAM_INSTALL_PREFIX}"
else
  # Native Unix build: use the just-installed opam binary.
  OPAM_NATIVE="${OPAM_INSTALL_PREFIX}/bin/opam"

  # Create an empty local repo to avoid downloading the full opam-repository index.
  # Users add their own repos with `opam repository add`.
  EMPTY_REPO="${SRC_DIR}/_empty_repo"
  mkdir -p "${EMPTY_REPO}"

  "${OPAM_NATIVE}" init --bare --no-setup --disable-sandboxing --no-opamrc --bypass-checks \
    --root "${OPAMROOT}" default "${EMPTY_REPO}" --kind local
  "${OPAM_NATIVE}" switch create conda --empty --root "${OPAMROOT}"
fi

# Remove binary caches — they contain non-relocatable paths and opam regenerates them.
find "${OPAMROOT}" -name "*.cache" -type f -delete

# Record build-time OCaml version for test skip logic (OCaml 5.3.0 GC bug on aarch64/ppc64le)
OCAML_BUILD_VERSION=$(ocaml -version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
echo "${OCAML_BUILD_VERSION}" > "${RECIPE_DIR}/testing/ocaml-build-version"
echo "Recorded OCaml build version: ${OCAML_BUILD_VERSION}"

echo "=== Build Complete ==="
