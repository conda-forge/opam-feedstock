if is_linux_cross; then
  export CFLAGS="-ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O3 -pipe -isystem $PREFIX/include"
  export LDFLAGS="-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--allow-shlib-undefined -Wl,-rpath,$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib -L$PREFIX/lib"
fi

# ==========================================================================
# Use native build tools from conda packages (already in BUILD_PREFIX/bin)
# ==========================================================================
NATIVE_DUNE="${BUILD_PREFIX}/bin/dune"
NATIVE_MENHIR="${BUILD_PREFIX}/bin/menhir"
NATIVE_CPPO="${BUILD_PREFIX}/bin/cppo"

echo "=== Using conda packages for native build tools ==="
echo "  dune:   ${NATIVE_DUNE} ($(file ${NATIVE_DUNE} | cut -d: -f2))"
echo "  menhir: ${NATIVE_MENHIR} ($(file ${NATIVE_MENHIR} | cut -d: -f2))"
echo "  cppo:   ${NATIVE_CPPO} ($(file ${NATIVE_CPPO} | cut -d: -f2))"

# Verify tools exist
for tool in "${NATIVE_DUNE}" "${NATIVE_MENHIR}" "${NATIVE_CPPO}"; do
  if [[ ! -x "${tool}" ]]; then
    echo "ERROR: Required build tool not found: ${tool}"
    echo "Make sure dune, menhir, and cppo are in build dependencies"
    exit 1
  fi
done

# Configure for cross-compilation with external dune
./configure \
   --build="${CONDA_TOOLCHAIN_BUILD}" \
   --host="${CONDA_TOOLCHAIN_HOST}" \
   --prefix="${OPAM_INSTALL_PREFIX}" \
   --with-vendored-deps \
   --with-dune="${NATIVE_DUNE}" \
   2>&1 || { cat config.log; exit 1; }

# ==========================================================================
echo "=== PHASE 1: Pre-generate Man Pages ==="
# ==========================================================================
# Man pages are architecture-independent. Build native opam to generate them.
# This also generates parser files via dune/menhir which we preserve for cross-compile.
# ==========================================================================
NATIVE_MAN_DIR="$(pwd)/_native_man"
generate_native_man_pages "${NATIVE_MAN_DIR}" "${NATIVE_DUNE}"

# ==========================================================================
echo "=== PHASE 2: Prepare for Cross-Compilation ==="
# ==========================================================================

# macOS cross-compile only: Pre-generate config files
# On Linux, config tools run fine. On macOS, we can't run arm64 binaries on x86_64.
if is_macos; then
  echo "Pre-generating config files for macOS cross-compilation..."

  # base64 config
  mkdir -p "src_ext/base64/config"
  echo -n "unsafe_stable.ml" > "src_ext/base64/config/which-unsafe-file"
  cat > "src_ext/base64/config/dune" << 'DUNE_EOF'
; Config executable disabled for cross-compilation - file pre-generated
DUNE_EOF
  echo "  Created: src_ext/base64/config/which-unsafe-file"

  # mccs context_flags
  for dir in "src_ext/mccs/src" "src_ext/mccs/src/glpk"; do
    if [[ -d "$dir" ]]; then
      echo "(-Wall -Wextra -Wno-unused-parameter -x c++ -std=gnu++11 -DUSEGLPK)" > "$dir/cxxflags.sexp"
      echo "(-lstdc++)" > "$dir/clibs.sexp"
      echo "()" > "$dir/flags.sexp"
      echo "  Created: $dir/{cxxflags,clibs,flags}.sexp"
    fi
  done

  python3 "${RECIPE_DIR}/building/remove_context_flags_stanzas.py"
fi

# ==========================================================================
# Remove menhir stanzas from dune files
# ==========================================================================
# Parsers are pre-generated, so we disable menhir rules to prevent dune
# from trying to invoke menhir during the cross-compile build.
# ==========================================================================
echo "Removing menhir stanzas from dune files..."
for dune_file in $(find "src_ext" "src" -name 'dune' -type f 2>/dev/null); do
  if grep -q 'menhir' "$dune_file"; then
    python3 "${RECIPE_DIR}/building/remove_menhir_stanzas.py" "$dune_file"
  fi
done

# Disable man page generation dune rules (they try to run cross-compiled opam)
MAN_DUNE="doc/man/dune"
if [[ -f "${MAN_DUNE}" ]]; then
  cat > "${MAN_DUNE}" << 'DUNE_EOF'
; Man page generation disabled for cross-compilation.
; Pre-generated man pages installed from _native_man/
DUNE_EOF
fi

# ==========================================================================
echo "=== PHASE 3: Cross-Compiler Setup ==="
# ==========================================================================

swap_ocaml_compilers
setup_cross_c_compilers
configure_cross_environment

if is_macos; then
  create_macos_ocamlmklib_wrapper
fi

patch_dune_for_cross
patch_ocaml_makefile_config
patch_opam_makefile_config
clear_build_caches

# DEBUG: Check compiler config after swap
echo "=== OCaml compiler config after swap ==="
ocamlc -config | grep -E "^(c_compiler|native_c_compiler|ccomp_type|architecture):"

# Create dune-workspace to force cross-compiler for C code
cat > dune-workspace << WORKSPACE_EOF
(lang dune 3.0)
(env
  (_
    (c_flags (:standard -I${PREFIX}/include))
    (cxx_flags (:standard -I${PREFIX}/include))))
WORKSPACE_EOF

echo "=== PHASE 4: Main Build ==="

make CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" V=1

# ==========================================================================
echo "=== PHASE 5: Manual Installation ==="
# ==========================================================================

mkdir -p "${OPAM_INSTALL_PREFIX}/bin"

OPAM_BIN="_build/install/default/bin/opam"
if [[ -f "${OPAM_BIN}" ]]; then
  install -m 755 "${OPAM_BIN}" "${OPAM_INSTALL_PREFIX}/bin/opam"
  echo "Installed: ${OPAM_INSTALL_PREFIX}/bin/opam"
  file "${OPAM_INSTALL_PREFIX}/bin/opam"
else
  echo "ERROR: opam binary not found at ${OPAM_BIN}"
  exit 1
fi

OPAM_INSTALLER_BIN="_build/install/default/bin/opam-installer"
if [[ -f "${OPAM_INSTALLER_BIN}" ]]; then
  install -m 755 "${OPAM_INSTALLER_BIN}" "${OPAM_INSTALL_PREFIX}/bin/opam-installer"
  echo "Installed: ${OPAM_INSTALL_PREFIX}/bin/opam-installer"
fi

# Install pre-generated man pages
NATIVE_MAN_DIR="_native_man"
if [[ -d "${NATIVE_MAN_DIR}" && ! -f "${NATIVE_MAN_DIR}/.failed" ]]; then
  echo "Installing pre-generated man pages..."
  MAN_INSTALL_DIR="${OPAM_INSTALL_PREFIX}/share/man/man1"
  mkdir -p "${MAN_INSTALL_DIR}"

  for manpage in "${NATIVE_MAN_DIR}"/*.1; do
    if [[ -f "${manpage}" ]]; then
      install -m 644 "${manpage}" "${MAN_INSTALL_DIR}/"
    fi
  done
  echo "Man pages installed to ${MAN_INSTALL_DIR}"
else
  echo "WARNING: No pre-generated man pages available"
fi
