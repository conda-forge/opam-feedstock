if is_linux_cross; then
  export CFLAGS="-ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe -isystem $PREFIX/include"
  export LDFLAGS="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--allow-shlib-undefined -Wl,-rpath,$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib -L$PREFIX/lib"
fi

# Configure for cross-compilation with explicit cross-compiler
./configure \
   --build="${CONDA_TOOLCHAIN_BUILD}" \
   --host="${CONDA_TOOLCHAIN_HOST}" \
   --prefix="${OPAM_INSTALL_PREFIX}" \
   --with-vendored-deps \
   2>&1 || { cat config.log; exit 1; }

# ==========================================================================
echo "=== PHASE 1: Build Native Tools ==="
# ==========================================================================
# Build tools that run on the BUILD machine during compilation:
# - dune: build system
# - cppo: C preprocessor for OCaml
# - menhir: parser generator
# ==========================================================================
(
  set -x  # Enable debug output
  # Use NATIVE compiler - these tools run on BUILD machine
  export CC="$(get_build_c_compiler)"
  export CXX="$(get_build_cxx_compiler)"
  export AR="${CONDA_TOOLCHAIN_BUILD}-ar"
  export AS="${CONDA_TOOLCHAIN_BUILD}-as"
  export LD="${CONDA_TOOLCHAIN_BUILD}-ld"

  echo "Phase 1 using native compiler: CC=${CC}"
  make src_ext/dune-local/_boot/dune.exe

  # Build cppo preprocessor using dune directly - must be native to run during build
  DUNE="${SRC_DIR}/src_ext/dune-local/_boot/dune.exe"
  echo "Building cppo with: ${DUNE}"
  (cd "${SRC_DIR}/src_ext/cppo" && "${DUNE}" build --root . src/cppo_main.exe 2>&1 || { echo "CPPO BUILD FAILED"; exit 1; })

  echo "Building menhir (@install targets) with: ${DUNE}"
  (cd "${SRC_DIR}/src_ext/menhir" && "${DUNE}" build --root . @install 2>&1 || { echo "MENHIR BUILD FAILED"; exit 1; })

  # Pre-generate menhir's own stage2 parser files and copy to source directory
  NATIVE_MENHIR="${SRC_DIR}/src_ext/menhir/_build/default/src/stage2/main.exe"

  # Copy menhir stage2 parser files to source directory
  copy_menhir_stage2_to_source

  # Pre-generate parser files for packages that use menhir
  generate_parser_files "${NATIVE_MENHIR}"

  # macOS cross-compile only: Pre-generate config files AND disable dune rules
  # On Linux, config tools are built native in Phase 1 and can run fine.
  # On macOS, we can't run arm64 binaries on x86_64, so pre-generate and disable rules.
  if is_macos; then
    # Pre-generate base64 config file for cross-compilation
    # The base64 package has a config tool that detects OCaml version to choose
    # between unsafe_stable.ml (OCaml >= 4.7) and unsafe_pre407.ml (OCaml < 4.7).
    # For OCaml 5.3+, the answer is always "unsafe_stable.ml".
    echo "Pre-generating base64 config for macOS cross-compilation..."
    mkdir -p "${SRC_DIR}/src_ext/base64/config"
    echo -n "unsafe_stable.ml" > "${SRC_DIR}/src_ext/base64/config/which-unsafe-file"
    # Disable the dune rule that generates this file (to avoid conflict)
    cat > "${SRC_DIR}/src_ext/base64/config/dune" << 'DUNE_EOF'
; Config executable disabled for cross-compilation - file pre-generated
DUNE_EOF
    echo "  Created: src_ext/base64/config/which-unsafe-file -> unsafe_stable.ml"
    echo "  Disabled: src_ext/base64/config/dune rules"

    # Pre-generate mccs context_flags output files for cross-compilation
    # The mccs package has context_flags.ml that generates compiler flags based on
    # MCCS_BACKENDS env var and OCaml Config module. Default is GLPK backend.
    echo "Pre-generating mccs context_flags for macOS cross-compilation..."
    for dir in "${SRC_DIR}/src_ext/mccs/src" "${SRC_DIR}/src_ext/mccs/src/glpk"; do
      if [[ -d "$dir" ]]; then
        echo "(-Wall -Wextra -Wno-unused-parameter -x c++ -std=gnu++11 -DUSEGLPK)" > "$dir/cxxflags.sexp"
        echo "(-lstdc++)" > "$dir/clibs.sexp"
        echo "()" > "$dir/flags.sexp"
        echo "  Created: $dir/{cxxflags,clibs,flags}.sexp"
      fi
    done

    # Remove context_flags stanzas from mccs dune files
    # sed doesn't handle multi-line S-expressions, use Python script
    python3 "${RECIPE_DIR}/building/remove_context_flags_stanzas.py"
  fi

  echo "=== Phase 1 complete: native build tools ready ==="
  echo "  dune: $(file ${SRC_DIR}/src_ext/dune-local/_boot/dune.exe)"
  echo "  cppo: $(file ${SRC_DIR}/src_ext/cppo/_build/default/src/cppo_main.exe)"
  echo "  menhir: $(file ${SRC_DIR}/src_ext/menhir/_build/default/src/stage2/main.exe)"
)

# ==========================================================================
# Disable man page generation dune rules (they try to run cross-compiled opam)
# ==========================================================================
MAN_DUNE="${SRC_DIR}/doc/man/dune"
if [[ -f "${MAN_DUNE}" ]]; then
  echo "Disabling man page generation in ${MAN_DUNE}..."
  cat > "${MAN_DUNE}" << 'DUNE_EOF'
; Man page generation disabled for cross-compilation.
; Pre-generated man pages will be installed manually from _native_man/
DUNE_EOF
fi

# Copy native build tools to BUILD_PREFIX/bin
echo "Copying native build tools to ${BUILD_PREFIX}/bin/"
cp -v "${SRC_DIR}/src_ext/dune-local/_boot/dune.exe" "${BUILD_PREFIX}/bin/dune"
cp -v "${SRC_DIR}/src_ext/cppo/_build/default/src/cppo_main.exe" "${BUILD_PREFIX}/bin/cppo"
cp -v "${SRC_DIR}/src_ext/menhir/_build/default/src/stage2/main.exe" "${BUILD_PREFIX}/bin/menhir"
chmod +x "${BUILD_PREFIX}/bin/dune" "${BUILD_PREFIX}/bin/cppo" "${BUILD_PREFIX}/bin/menhir"

# ==========================================================================
# PHASE 1.5: Pre-generate Man Pages with Native opam
# ==========================================================================
# Cross-compiled opam cannot run on build machine (QEMU segfaults).
# Man pages are architecture-independent, so we build native opam first.
# ==========================================================================
NATIVE_MAN_DIR="${SRC_DIR}/_native_man"
generate_native_man_pages "${NATIVE_MAN_DIR}" "${BUILD_PREFIX}/bin/dune"

# Make native tool build caches read-only to prevent rebuilding with cross-compiler
echo "Protecting native build caches..."
for build_cache in "${SRC_DIR}/src_ext/dune-local/_boot" "${SRC_DIR}/src_ext/cppo/_build" "${SRC_DIR}/src_ext/menhir/_build"; do
  if [[ -d "${build_cache}" ]]; then
    chmod -R a-w "${build_cache}" && echo "  Protected: ${build_cache}"
  fi
done

# Create wrapper scripts for native build tools
echo "Creating wrapper scripts to intercept cross-compiled executables..."
WRAPPER_DIR="${SRC_DIR}/.native-wrappers"
mkdir -p "${WRAPPER_DIR}"

for tool in menhir pack.exe config.exe context_flags.exe cppo; do
  NATIVE_TOOL="${BUILD_PREFIX}/bin/${tool}"
  if [[ -x "${NATIVE_TOOL}" ]]; then
    cat > "${WRAPPER_DIR}/${tool}" << WRAPPER_EOF
#!/usr/bin/env bash
# Wrapper to run native ${tool} instead of cross-compiled version
exec "${NATIVE_TOOL}" "\$@"
WRAPPER_EOF
    chmod +x "${WRAPPER_DIR}/${tool}"
    echo "  Created wrapper for ${tool}"
  fi
done
export PATH="${WRAPPER_DIR}:${PATH}"

# ==========================================================================
# Remove ALL menhir invocation stanzas from dune files
# ==========================================================================
echo "Removing ALL menhir-invoking stanzas from dune files..."
echo "Files containing 'menhir':"
grep -rl 'menhir' "${SRC_DIR}/src_ext" "${SRC_DIR}/src" --include='dune' 2>/dev/null || echo "  (none found)"

for dune_file in $(find "${SRC_DIR}/src_ext" "${SRC_DIR}/src" -name 'dune' -type f 2>/dev/null); do
  if grep -q 'menhir' "$dune_file"; then
    echo "PATCHING: $dune_file"
    python3 "${RECIPE_DIR}/building/remove_menhir_stanzas.py" "$dune_file"
    if grep -q '^(menhir' "$dune_file"; then
      echo "  WARNING: menhir stanza still present after patching!"
    fi
  fi
done

# ==========================================================================
echo "=== PHASE 2: Cross-Compiler Setup ==="
# ==========================================================================
# Swap OCaml compilers to cross-compiler variants and set environment.
# NOTE: Do NOT swap ocamlmklib/ocamllex - they don't exist in cross-compilers
# package and the native versions work fine (they read config from swapped ocamlc)
# ==========================================================================

swap_ocaml_compilers
setup_cross_c_compilers
configure_cross_environment

if is_macos; then
  create_macos_ocamlmklib_wrapper
fi

patch_dune_for_cross

# DEBUG: Check compiler config after swap
echo "=== OCaml compiler config after swap ==="
ocamlc -config | grep -E "^(c_compiler|native_c_compiler|ccomp_type|architecture):"

patch_ocaml_makefile_config
clear_build_caches

echo "Running make with explicit cross-compiler: CC=${CC}, AR=${AR}"

# Create dune-workspace to force cross-compiler for C code
cat > dune-workspace << WORKSPACE_EOF
(lang dune 3.0)
(env
  (_
    (c_flags (:standard -I${PREFIX}/include))
    (cxx_flags (:standard -I${PREFIX}/include))))
WORKSPACE_EOF
echo "Created dune-workspace with cross-compile flags"

echo "=== PHASE 3: Main Build ==="

make CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" V=1

# ==========================================================================
echo "=== PHASE 4: Manual Installation ==="
# ==========================================================================
# opam-installer cannot run on build machine, so we install manually.
# ==========================================================================

mkdir -p "${OPAM_INSTALL_PREFIX}/bin"

OPAM_BIN="${SRC_DIR}/_build/install/default/bin/opam"
if [[ -f "${OPAM_BIN}" ]]; then
  echo "Installing opam binary..."
  install -m 755 "${OPAM_BIN}" "${OPAM_INSTALL_PREFIX}/bin/opam"
  echo "  Installed: ${OPAM_INSTALL_PREFIX}/bin/opam"
  file "${OPAM_INSTALL_PREFIX}/bin/opam"
else
  echo "ERROR: opam binary not found at ${OPAM_BIN}"
  exit 1
fi

OPAM_INSTALLER_BIN="${SRC_DIR}/_build/install/default/bin/opam-installer"
if [[ -f "${OPAM_INSTALLER_BIN}" ]]; then
  echo "Installing opam-installer binary..."
  install -m 755 "${OPAM_INSTALLER_BIN}" "${OPAM_INSTALL_PREFIX}/bin/opam-installer"
  echo "  Installed: ${OPAM_INSTALL_PREFIX}/bin/opam-installer"
  file "${OPAM_INSTALL_PREFIX}/bin/opam-installer"
else
  echo "WARNING: opam-installer binary not found at ${OPAM_INSTALLER_BIN}"
fi

# Install pre-generated man pages
NATIVE_MAN_DIR="${SRC_DIR}/_native_man"
if [[ -d "${NATIVE_MAN_DIR}" && ! -f "${NATIVE_MAN_DIR}/.failed" ]]; then
  echo "Installing pre-generated man pages..."
  MAN_INSTALL_DIR="${OPAM_INSTALL_PREFIX}/share/man/man1"
  mkdir -p "${MAN_INSTALL_DIR}"

  for manpage in "${NATIVE_MAN_DIR}"/*.1; do
    if [[ -f "${manpage}" ]]; then
      echo "  Installing $(basename ${manpage})"
      install -m 644 "${manpage}" "${MAN_INSTALL_DIR}/"
    fi
  done

  echo "Man pages installed to ${MAN_INSTALL_DIR}"
  ls -la "${MAN_INSTALL_DIR}/"opam*.1 2>/dev/null | head -20 || echo "  (none installed)"
else
  echo "WARNING: No pre-generated man pages available"
fi
