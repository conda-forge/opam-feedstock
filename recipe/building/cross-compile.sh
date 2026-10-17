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
# Subshell: native OCaml environment applies to this phase only
(
  ocaml_use_native
  generate_native_man_pages "${NATIVE_MAN_DIR}" "${NATIVE_DUNE}"
)

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

  # mccs context_flags - pre-generate all sexp files that context_flags.exe would produce
  for dir in "src_ext/mccs/src" "src_ext/mccs/src/glpk"; do
    if [[ -d "$dir" ]]; then
      echo "(-Wall -Wextra -Wno-unused-parameter -x c++ -std=gnu++11 -DUSEGLPK)" > "$dir/cxxflags.sexp"
      echo "(-Wall -Wextra -Wno-unused-parameter -DUSEGLPK)" > "$dir/cflags.sexp"
      echo "(-lstdc++)" > "$dir/clibs.sexp"
      echo "()" > "$dir/flags.sexp"
      echo "  Created: $dir/{cxxflags,cflags,clibs,flags}.sexp"
    fi
  done

  python3 "${RECIPE_DIR}/building/remove_context_flags_stanzas.py"
fi

# ==========================================================================
# Remove menhir stanzas from dune files
# ==========================================================================
# Opam uses --with-vendored-deps, so menhir SOURCE is in src_ext/menhir.
# During cross-compile, vendored menhir would be compiled for arm64 and dune
# would try to run it → QEMU crash. Pre-generate parsers in Phase 1, then
# remove menhir stanzas so vendored menhir doesn't get built/run.
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

ocaml_use_cross
setup_cross_c_compilers
# The cross activation leaves the native lib ahead in OCAMLPATH, so dune
# resolves unix/compiler-libs from $BUILD_PREFIX/lib/ocaml and links them
# against the cross stdlib (inconsistent assumptions over Stdlib__Sys).
# Put the cross lib first. Bytecode run on the build machine (dune helpers)
# still needs the native stublibs.
OCAML_CROSS_LIB="$(ocamlc -where)"
export OCAMLPATH="${OCAML_CROSS_LIB}:${BUILD_PREFIX}/lib/ocaml"
export CAML_LD_LIBRARY_PATH="${BUILD_PREFIX}/lib/ocaml/stublibs"
echo "  Cross OCaml environment:"
echo "    ocamlc:  $(command -v ocamlc)  -where: ${OCAML_CROSS_LIB}"
echo "    ocamlopt arch: $(ocamlopt -config-var architecture 2>/dev/null)"
echo "    OCAMLLIB=${OCAMLLIB:-<unset>}"
echo "    OCAMLPATH=${OCAMLPATH}"
echo "    CAML_LD_LIBRARY_PATH=${CAML_LD_LIBRARY_PATH}"

patch_dune_for_cross
# patch_ocaml_makefile_config - not needed, cross-compiler uses conda-ocaml-cc wrapper
# Makefile.config OCAMLLIB is deliberately not patched: a cross OCAMLLIB there
# reaches dune's evaluation of OCaml-syntax dune files and mixes host and cross
# stdlib .cmi (CRC mismatch -> Persistent_env.Error).
clear_build_caches

# dune-workspace: target headers for C stubs; $PREFIX/lib for OCaml-driven links (-lzstd) and as rpath so helpers like context_flags.exe run under QEMU
cat > dune-workspace << WORKSPACE_EOF
(lang dune 3.0)
(env
  (_
    (c_flags (:standard -I${PREFIX}/include))
    (cxx_flags (:standard -I${PREFIX}/include))
    (link_flags (:standard -ccopt -L${PREFIX}/lib -ccopt -Wl,-rpath,${PREFIX}/lib -ccopt -Wl,-rpath-link,${PREFIX}/lib))))
WORKSPACE_EOF

echo "=== PHASE 4: Main Build ==="

echo "=== DIAG: cross dune diagnostics ==="
(
  set +e
  echo "--- tools"
  for t in ocaml ocamlc ocamlopt ocamlrun ocamlfind dune; do printf '  %-9s %s\n' "$t" "$(command -v $t)"; done
  ls "$(ocamlc -where)/stublibs" 2>&1 | head -20
  cat "$(ocamlc -where)/ld.conf" 2>&1
  echo "--- ocaml toplevel"
  ocaml -version
  echo "--- OCaml-syntax dune files"
  grep -rl --include=dune -e '-\*- tuareg -\*-' . 2>/dev/null | head -20
  echo "--- dune-workspace / dune-project files above and at root"
  ls -la dune-workspace* dune-project 2>/dev/null; ls -la .. | grep -i dune
  echo "--- dune env"; env | grep -E '^(DUNE|OCAML|CAML|INSIDE_DUNE)' | sort
  echo "--- dune-workspace content"; cat dune-workspace
  ls -la _build 2>&1 | head
  echo "--- direct dune build"
  "${BUILD_PREFIX}/bin/dune" build --profile=release --root . --display short --error-reporting=twice -- opam-installer.install opam.install > /tmp/diag_dune.out 2>&1
  echo "  dune exit=$?"
  echo "  output lines: $(wc -l < /tmp/diag_dune.out)"
  grep -n -iE 'error|exited|signal|fatal|killed|exception|cannot|failed|abort' /tmp/diag_dune.out | head -60
  echo "--- first error context"
  n=$(grep -n -m1 -iE '^Error|Error:|exited with|signal' /tmp/diag_dune.out | cut -d: -f1); if [ -n "$n" ]; then sed -n "$((n>25?n-25:1)),$((n+40))p" /tmp/diag_dune.out; fi
  echo "--- last 40 lines"; tail -n 40 /tmp/diag_dune.out
  echo "--- build dir"; ls -la _build 2>&1 | head; find / -xdev -path '*_build/log' -mmin -10 2>/dev/null | head
  tail -n 150 ./_build/log 2>&1
  echo "--- dune logs found"
  find . -path '*_build/log' -newer /tmp/diag_ok.ml 2>/dev/null | while read l; do echo "  == $l"; tail -n 120 "$l"; done
) || true
echo "=== DIAG end ==="

make CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" V=1 || { echo "=== dune build failed; tail of _build/log ==="; tail -n 150 "${SRC_DIR}/opam/_build/log" _build/log 2>/dev/null; exit 1; }

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
