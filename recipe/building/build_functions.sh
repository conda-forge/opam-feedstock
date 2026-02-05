# ==============================================================================
# OPAM Build Helper Functions
# ==============================================================================
# This file contains all reusable helper functions for the opam build process.
# Sourced by build.sh for cleaner organization.
# ==============================================================================

# ==============================================================================
# CONSTANTS
# ==============================================================================

# Man page commands to generate
readonly OPAM_COMMANDS=(init install remove upgrade switch pin source list show search info config env var exec repository update option lock clean reinstall admin)
readonly OPAM_ADMIN_COMMANDS=(cache check filter list)

# Limits for verification output
readonly PARSER_SAMPLE_LIMIT=20
readonly OCAML_RUNTIME_SAMPLE=5
readonly OPAM_STUB_HEADER_LINES=73

readonly SAVED_PARSERS_DIR="${SRC_DIR}/_saved_parsers"

# ==============================================================================
# PLATFORM DETECTION
# ==============================================================================

# Platform detection
is_macos() { [[ "${target_platform}" == "osx-"* ]]; }
is_linux() { [[ "${target_platform}" == "linux-"* ]]; }
is_linux_cross() { [[ "${target_platform}" == *"-aarch64" ]] || [[ "${target_platform}" == *"-ppc64le" ]] || [[ "${target_platform}" == *"-riscv64" ]]; }
is_non_unix() { [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; }
is_cross_compile() { [[ "${CONDA_BUILD_CROSS_COMPILATION:-}" == "1" ]]; }
build_is_macos() { [[ "${build_platform:-${target_platform}}" == "osx-"* ]]; }

# Convenience wrappers for readability
get_target_c_compiler() { get_compiler "c" "${CONDA_TOOLCHAIN_HOST:-}"; }
get_target_cxx_compiler() { get_compiler "cxx" "${CONDA_TOOLCHAIN_HOST:-}"; }
get_build_c_compiler() { get_compiler "c" "${CONDA_TOOLCHAIN_BUILD:-}"; }
get_build_cxx_compiler() { get_compiler "cxx" "${CONDA_TOOLCHAIN_BUILD:-}"; }

# ==============================================================================
# HELPER FUNCTIONS - Error Handling & Utilities
# ==============================================================================

warn() {
  echo "WARNING: $*" >&2
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

try_or_warn() {
  local msg="${1}"
  shift
  "$@" 2>/dev/null || warn "${msg}"
}

try_or_fail() {
  local msg="${1}"
  shift
  "$@" || fail "${msg}"
}

create_wrapper_script() {
  local wrapper_path="${1}"
  local target_binary="${2}"
  local extra_args="${3:-}"

  cat > "${wrapper_path}" << WRAPPER_EOF
#!/bin/bash
exec "${target_binary}" ${extra_args} "\$@"
WRAPPER_EOF
  chmod +x "${wrapper_path}"
  echo "  Created wrapper: ${wrapper_path} -> ${target_binary}"
}

generate_native_man_pages() {
  local native_man_dir="${1}"
  local dune="${2}"

  echo "=== PHASE 1.5: Pre-generate Man Pages with Native opam ==="
  mkdir -p "${native_man_dir}"

  # Save pre-generated parsers (for later cross-compile)
  save_parser_files

  # Remove parsers so native build regenerates them
  remove_parser_files

  # Build native opam
  echo "Building native opam for man page generation..."
  cd "${SRC_DIR}"
  if ! "${dune}" build --profile=release --root . --promote-install-files -- opam.install opam-installer.install 2>&1; then
    warn "Native build failed, skipping man page generation"
    touch "${native_man_dir}/.failed"
    restore_parser_files
    return 1
  fi

  local native_opam="${SRC_DIR}/_build/default/src/client/opamMain.exe"
  local native_installer="${SRC_DIR}/_build/default/src/tools/opam_installer.exe"

  # Generate man pages using the OPAM_COMMANDS and OPAM_ADMIN_COMMANDS constants
  if [[ -x "${native_opam}" ]]; then
    echo "Native opam built: $(file ${native_opam})"
    echo "Generating man pages..."
    "${native_opam}" --help=groff > "${native_man_dir}/opam.1" 2>/dev/null || true

    for cmd in "${OPAM_COMMANDS[@]}"; do
      "${native_opam}" "${cmd}" --help=groff > "${native_man_dir}/opam-${cmd}.1" 2>/dev/null || true
    done

    for subcmd in "${OPAM_ADMIN_COMMANDS[@]}"; do
      "${native_opam}" admin "${subcmd}" --help=groff > "${native_man_dir}/opam-admin-${subcmd}.1" 2>/dev/null || true
    done
  else
    warn "Native opam not found at ${native_opam}"
    touch "${native_man_dir}/.failed"
  fi

  # Generate installer man page
  if [[ -x "${native_installer}" ]]; then
    "${native_installer}" --help=groff > "${native_man_dir}/opam-installer.1" 2>/dev/null || true
  fi

  # Clean build artifacts and restore parsers for cross-compile
  echo "Cleaning native _build to prepare for cross-compilation..."
  rm -rf "${SRC_DIR}/_build"
  restore_parser_files

  echo "Pre-generated man pages:"
  ls -la "${native_man_dir}/"*.1 2>/dev/null | head -10 || echo "  (none generated)"
}

# Get compiler path based on type and toolchain
# Usage: get_compiler "c" [toolchain_prefix]  -> returns gcc/clang path
#        get_compiler "cxx" [toolchain_prefix] -> returns g++/clang++ path
get_compiler() {
  local compiler_type="${1}"  # "c" or "cxx"
  local toolchain_prefix="${2:-}"

  local c_compiler cxx_compiler
  if [[ -n "${toolchain_prefix}" ]]; then
    if [[ "${toolchain_prefix}" == *"apple-darwin"* ]]; then
      c_compiler="${toolchain_prefix}-clang"
      cxx_compiler="${toolchain_prefix}-clang++"
    else
      c_compiler="${toolchain_prefix}-gcc"
      cxx_compiler="${toolchain_prefix}-g++"
    fi
  else
    if is_macos; then
      c_compiler="clang"
      cxx_compiler="clang++"
    else
      c_compiler="gcc"
      cxx_compiler="g++"
    fi
  fi

  if [[ "${compiler_type}" == "c" ]]; then
    echo "${c_compiler}"
  else
    echo "${cxx_compiler}"
  fi
}

# ==============================================================================
# CROSS-COMPILATION SETUP FUNCTIONS
# ==============================================================================

swap_ocaml_compilers() {
  echo "  Swapping OCaml compilers to cross-compilers..."
  pushd "${BUILD_PREFIX}/bin" > /dev/null
    for tool in ocamlc ocamldep ocamlopt ocamlobjinfo; do
      if [[ -f "${tool}" ]] || [[ -L "${tool}" ]]; then
        mv "${tool}" "${tool}.build"
        ln -sf "${CONDA_TOOLCHAIN_HOST}-${tool}" "${tool}"
      fi
      if [[ -f "${tool}.opt" ]] || [[ -L "${tool}.opt" ]]; then
        mv "${tool}.opt" "${tool}.opt.build"
        ln -sf "${CONDA_TOOLCHAIN_HOST}-${tool}.opt" "${tool}.opt"
      fi
    done
  popd > /dev/null
}

setup_cross_c_compilers() {
  echo "  Setting up C/C++ cross-compiler symlinks..."
  local target_cc="$(get_target_c_compiler)"
  local target_cxx="$(get_target_cxx_compiler)"

  pushd "${BUILD_PREFIX}/bin" > /dev/null
    for tool in gcc cc; do
      if [[ -f "${tool}" ]] || [[ -L "${tool}" ]]; then
        mv "${tool}" "${tool}.build" 2>/dev/null || true
      fi
      ln -sf "${target_cc}" "${tool}"
      echo "    Linked ${tool} -> ${target_cc}"
    done
    for tool in g++ c++; do
      if [[ -f "${tool}" ]] || [[ -L "${tool}" ]]; then
        mv "${tool}" "${tool}.build" 2>/dev/null || true
      fi
      ln -sf "${target_cxx}" "${tool}"
      echo "    Linked ${tool} -> ${target_cxx}"
    done
  popd > /dev/null
}

configure_cross_environment() {
  echo "  Configuring cross-compilation environment variables..."

  # Override CONDA_OCAML_* for cross-compilation.
  # The ocaml activation script sets these to BUILD compiler, but for cross-compile
  # we need them pointing to TARGET compiler so Dune builds C stubs correctly.
  export CONDA_OCAML_CC="$(get_target_c_compiler)"
  export CONDA_OCAML_AR="${CONDA_TOOLCHAIN_HOST}-ar"
  export CONDA_OCAML_AS="${CONDA_TOOLCHAIN_HOST}-as"
  export CONDA_OCAML_LD="${CONDA_TOOLCHAIN_HOST}-ld"
  if is_macos; then
    export CONDA_OCAML_MKEXE="${CONDA_OCAML_CC}"
    export CONDA_OCAML_MKDLL="${CONDA_OCAML_CC} -dynamiclib"
  else
    export CONDA_OCAML_MKEXE="${CONDA_OCAML_CC} -Wl,-E -ldl"
    export CONDA_OCAML_MKDLL="${CONDA_OCAML_CC} -shared"
  fi

  echo "    Cross-compiler environment (overriding ocaml activation):"
  echo "      CC=${CC}, CXX=${CXX}, AR=${AR}"
  echo "      CONDA_OCAML_CC=${CONDA_OCAML_CC}"

  # Set QEMU_LD_PREFIX for binfmt_misc/QEMU to find aarch64 dynamic linker
  export QEMU_LD_PREFIX="${BUILD_PREFIX}/${CONDA_TOOLCHAIN_HOST}/sysroot"

  # Set OCAMLLIB, LIBRARY_PATH and LDFLAGS so ocamlmklib can find cross-compiled OCaml runtime
  # OCAMLLIB is CRITICAL - ocamlmklib uses it to find libasmrun.a and other runtime libs
  local cross_ocaml_lib="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${CONDA_TOOLCHAIN_HOST}/lib/ocaml"
  if [[ -d "${cross_ocaml_lib}" ]]; then
    export OCAMLLIB="${cross_ocaml_lib}"
    export LIBRARY_PATH="${cross_ocaml_lib}:${PREFIX}/lib:${LIBRARY_PATH:-}"
    export LDFLAGS="-L${cross_ocaml_lib} -L${PREFIX}/lib ${LDFLAGS:-}"
    echo "    Set OCAMLLIB for ocamlmklib: ${OCAMLLIB}"
    echo "    Set LIBRARY_PATH: ${cross_ocaml_lib}"
    echo "    Set LDFLAGS: ${LDFLAGS}"
    # Debug: show what's in the cross-compiler lib
    echo "    Cross-compiled OCaml runtime files:"
    ls -la "${cross_ocaml_lib}/"*.a 2>/dev/null | head -5 || echo "      (no .a files found)"
  fi
}

create_macos_ocamlmklib_wrapper() {
  # NOTE: Still needed - ocaml 5.3.0 _9 fix not sufficient for cross-compile
  echo "  Creating macOS ocamlmklib wrapper..."
  local real_ocamlmklib="${BUILD_PREFIX}/bin/ocamlmklib"

  if [[ -f "${real_ocamlmklib}" ]] && [[ ! -f "${real_ocamlmklib}.real" ]]; then
    mv "${real_ocamlmklib}" "${real_ocamlmklib}.real"
    cat > "${real_ocamlmklib}" << 'WRAPPER_EOF'
#!/bin/bash
# Wrapper to add -undefined dynamic_lookup for macOS shared lib creation
# This allows _caml_* symbols to remain unresolved until runtime
exec "${0}.real" -ldopt "-Wl,-undefined,dynamic_lookup" "$@"
WRAPPER_EOF
    chmod +x "${real_ocamlmklib}"
    echo "    Created wrapper: ${real_ocamlmklib}"
  fi
}

patch_dune_for_cross() {
  echo "  Patching Dune files for cross-compilation..."
  local native_cppo="${BUILD_PREFIX}/bin/cppo"
  local native_menhir="${BUILD_PREFIX}/bin/menhir"

  echo "    Patching vendored dune files to use native cppo: ${native_cppo}"
  find src_ext -name 'dune' -type f -exec grep -l '%{bin:cppo}' {} \; | while read f; do
    echo "      Patching cppo in: $f"
    sed -i "s|%{bin:cppo}|${native_cppo}|g" "$f"
  done

  export MENHIR="${native_menhir}"
  export PATH="${BUILD_PREFIX}/bin:${PATH}"
  echo "    Native menhir available at: $(which menhir)"
}

# REMOVED: patch_ocaml_makefile_config() - ocaml 5.3.0 _8+ provides correct Makefile.config for cross-compilers

clear_build_caches() {
  echo "  Clearing build caches..."

  # Clear Dune caches to force cross-compiler detection
  rm -rf "${SRC_DIR}/_build" 2>/dev/null || true
  for ext_dir in "${SRC_DIR}"/src_ext/*/; do
    ext_name=$(basename "$ext_dir")
    if [[ "${ext_name}" != "dune-local" && "${ext_name}" != "cppo" && "${ext_name}" != "menhir" ]]; then
      rm -rf "${ext_dir}/_build" 2>/dev/null || true
    fi
  done

  # Remove Phase 1 C stubs (will rebuild as cross-compiled)
  echo "    Removing Phase 1 C stubs (will rebuild as cross-compiled)..."
  find "${SRC_DIR}/src_ext" -name "*.a" -not -path "*/dune-local/*" -not -path "*/cppo/*" -not -path "*/menhir/*" -type f -delete 2>/dev/null || true
  find "${SRC_DIR}/src" -name "*.a" -type f -delete 2>/dev/null || true
  find "${SRC_DIR}" -name "*.o" -delete 2>/dev/null || true
  find "${SRC_DIR}" -name "*.a" -type f -delete 2>/dev/null || true
  echo "    Object files cleared - forcing fresh cross-compile rebuild"
}

# ==============================================================================
# WINDOWS WORKAROUNDS
# ==============================================================================

# Apply Windows-specific workarounds for Dune build system
# Dune on Windows doesn't properly handle conditional rules during analysis phase.
apply_non_unix_workarounds() {
  echo "=== Applying Windows Build Workarounds ==="

  EXPECTED_CC=$(ocamlc -config | grep "^c_compiler:" | awk '{print $2}')
  echo "OCaml expects C compiler: ${EXPECTED_CC}"

  export PATH="${BUILD_PREFIX}/Library/mingw-w64/bin:${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/bin:${PATH}"

  if ! command -v "${EXPECTED_CC}" &>/dev/null; then
    echo "WARNING: ${EXPECTED_CC} not found in PATH"
    echo "Searching for gcc variants..."

    GCC_FOUND=""
    for dir in "${BUILD_PREFIX}/Library/mingw-w64/bin" "${BUILD_PREFIX}/Library/bin" "${BUILD_PREFIX}/bin"; do
      if [[ -d "${dir}" ]]; then
        echo "  Checking ${dir}:"
        ls -la "${dir}/"*gcc* 2>/dev/null || echo "    (no gcc found)"

        for candidate in "${dir}/${EXPECTED_CC}.exe" "${dir}/${EXPECTED_CC}" "${dir}/gcc.exe" "${dir}/gcc"; do
          if [[ -f "${candidate}" ]]; then
            GCC_FOUND="${candidate}"
            echo "  Found: ${GCC_FOUND}"
            break 2
          fi
        done
      fi
    done

    if [[ -n "${GCC_FOUND}" ]]; then
      GCC_DIR=$(dirname "${GCC_FOUND}")
      GCC_BASE=$(basename "${GCC_FOUND}")

      if [[ "${GCC_BASE}" != "${EXPECTED_CC}"* ]]; then
        echo "Creating wrapper: ${GCC_DIR}/${EXPECTED_CC}.exe -> ${GCC_FOUND}"
        cp "${GCC_FOUND}" "${GCC_DIR}/${EXPECTED_CC}.exe" 2>/dev/null ||           ln -sf "${GCC_BASE}" "${GCC_DIR}/${EXPECTED_CC}" 2>/dev/null ||           echo "WARNING: Could not create wrapper"
      fi
    else
      echo "ERROR: No gcc found, falling back to removing foreign_stubs..."
      sed -i '/^  (foreign_stubs$/,/c-flags\.sexp)))/d' src/core/dune
      echo "WARNING: Manual C compilation fallback - this may not work!"
    fi
  else
    echo "C compiler ${EXPECTED_CC} found in PATH"
    which "${EXPECTED_CC}" || true
  fi

  # Remove problematic dune rules for Windows
  sed -i '/^(rule$/,/cc64)))/d' src/core/dune
  sed -i '/^(install$/,/opam-putenv\.exe))/d' src/core/dune

  # Pre-create generated .ml files
  echo "let value = \"\"" > src/core/opamCoreConfigDeveloper.ml
  echo "let version = \"${PKG_VERSION}\"" > src/core/opamVersionInfo.ml
  cp src/core/opamStubs.ocaml5.ml src/core/opamStubs.ml
  cp src/core/opamWin32Stubs.win32.ml src/core/opamWin32Stubs.ml

  # Windows system libraries for linking
  echo '(-ladvapi32 -lgdi32 -luser32 -lshell32 -lole32 -luuid -luserenv)' > src/core/c-libraries.sexp

  # Create opam_stubs.c by inlining included C files
  pushd src/core > /dev/null
  head -n "${OPAM_STUB_HEADER_LINES}" opamCommonStubs.c > opam_stubs.c
  cat opamInject.c >> opam_stubs.c
  cat opamWindows.c >> opam_stubs.c
  popd > /dev/null

  echo "Windows workarounds applied successfully"
}

# ==============================================================================
# Parser File Management
# ==============================================================================
# These functions manage pre-generated parser files for cross-compilation.
# Parser generators (menhir) produce .ml/.mli files that must be pre-generated
# with native tools since cross-compiled generators can't run on build machine.

# Copy menhir's own stage2 parser files from build dir to source dir
copy_menhir_stage2_to_source() {
  local menhir_build="${SRC_DIR}/src_ext/menhir/_build/default/src/stage2"
  local menhir_src="${SRC_DIR}/src_ext/menhir/src/stage2"

  echo "Copying menhir stage2 parser files to source directory..."
  if [[ -f "${menhir_build}/parser.ml" ]]; then
    cp -v "${menhir_build}/parser.ml" "${menhir_src}/"
    cp -v "${menhir_build}/parser.mli" "${menhir_src}/" 2>/dev/null || true
  fi
  if [[ -f "${menhir_build}/parserMessages.ml" ]]; then
    cp -v "${menhir_build}/parserMessages.ml" "${menhir_src}/"
  fi
  for f in parserMessages.auto.messages parserMessages.check; do
    if [[ -f "${menhir_build}/${f}" ]]; then
      cp -v "${menhir_build}/${f}" "${menhir_src}/"
    fi
  done
}

# Generate parser files for opam-file-format and dose3 using native menhir
generate_parser_files() {
  local native_menhir="${1}"

  echo "Pre-generating parser files with native menhir..."
  cd "${SRC_DIR}"

  # opam-file-format: generates opamBaseParser.ml from opamBaseParser.mly
  if [[ -f "src_ext/opam-file-format/src/opamBaseParser.mly" ]]; then
    echo "  Generating opam-file-format parser..."
    "${native_menhir}" --ocamlc ocamlc \
      --base "src_ext/opam-file-format/src/opamBaseParser" \
      "src_ext/opam-file-format/src/opamBaseParser.mly" 2>&1 || echo "    Warning: opam-file-format parser generation failed"
  fi

  # dose3: generates several parsers
  for mly in src_ext/dose3/src/versioning/version*.mly src_ext/dose3/src/*/parser*.mly; do
    if [[ -f "$mly" ]]; then
      local dir=$(dirname "$mly")
      local base=$(basename "$mly" .mly)
      echo "  Generating parser: $mly"
      "${native_menhir}" --ocamlc ocamlc --base "${dir}/${base}" "$mly" 2>&1 || echo "    Warning: failed"
    fi
  done
}

# Save pre-generated parser files for later restoration
save_parser_files() {
  echo "Saving pre-generated parser files for later restoration..."
  mkdir -p "${SAVED_PARSERS_DIR}"

  # opam-file-format
  cp -p "${SRC_DIR}/src_ext/opam-file-format/src/opamBaseParser.ml" "${SAVED_PARSERS_DIR}/" 2>/dev/null || true
  cp -p "${SRC_DIR}/src_ext/opam-file-format/src/opamBaseParser.mli" "${SAVED_PARSERS_DIR}/" 2>/dev/null || true

  # dose3 parsers
  for mly in "${SRC_DIR}"/src_ext/dose3/src/versioning/version*.mly "${SRC_DIR}"/src_ext/dose3/src/*/parser*.mly; do
    if [[ -f "$mly" ]]; then
      local dir=$(dirname "$mly")
      local base=$(basename "$mly" .mly)
      local reldir=${dir#${SRC_DIR}/}
      mkdir -p "${SAVED_PARSERS_DIR}/${reldir}"
      cp -p "${dir}/${base}.ml" "${SAVED_PARSERS_DIR}/${reldir}/" 2>/dev/null || true
      cp -p "${dir}/${base}.mli" "${SAVED_PARSERS_DIR}/${reldir}/" 2>/dev/null || true
    fi
  done

  # menhir stage2 parser files
  local menhir_stage2="${SRC_DIR}/src_ext/menhir/src/stage2"
  mkdir -p "${SAVED_PARSERS_DIR}/menhir_stage2"
  for f in parser.ml parser.mli parserMessages.ml parserMessages.auto.messages parserMessages.check; do
    cp -p "${menhir_stage2}/${f}" "${SAVED_PARSERS_DIR}/menhir_stage2/" 2>/dev/null || true
  done

  echo "Saved parsers:"
  find "${SAVED_PARSERS_DIR}" \( -name "*.ml" -o -name "*.mli" \) 2>/dev/null | head -20 || echo "  (none)"
}

# Remove parser files (native build can regenerate them)
remove_parser_files() {
  echo "Removing pre-generated parser files for native build..."

  # opam-file-format
  rm -f "${SRC_DIR}/src_ext/opam-file-format/src/opamBaseParser.ml" 2>/dev/null || true
  rm -f "${SRC_DIR}/src_ext/opam-file-format/src/opamBaseParser.mli" 2>/dev/null || true

  # dose3 parsers
  for base in version822 versioncudf parser822 parsercudf; do
    find "${SRC_DIR}/src_ext/dose3" -name "${base}.ml" -delete 2>/dev/null || true
    find "${SRC_DIR}/src_ext/dose3" -name "${base}.mli" -delete 2>/dev/null || true
  done

  # menhir stage2 parser files
  local menhir_stage2="${SRC_DIR}/src_ext/menhir/src/stage2"
  rm -f "${menhir_stage2}/parser.ml" 2>/dev/null || true
  rm -f "${menhir_stage2}/parser.mli" 2>/dev/null || true
  rm -f "${menhir_stage2}/parserMessages.ml" 2>/dev/null || true
  rm -f "${menhir_stage2}/parserMessages.auto.messages" 2>/dev/null || true
  rm -f "${menhir_stage2}/parserMessages.check" 2>/dev/null || true
}

# Restore parser files for cross-compilation
restore_parser_files() {
  echo "Restoring pre-generated parser files for cross-compilation..."

  if [[ ! -d "${SAVED_PARSERS_DIR}" ]]; then
    echo "  WARNING: No saved parsers found at ${SAVED_PARSERS_DIR}"
    return 1
  fi

  # opam-file-format
  cp -p "${SAVED_PARSERS_DIR}/opamBaseParser.ml" "${SRC_DIR}/src_ext/opam-file-format/src/" 2>/dev/null || true
  cp -p "${SAVED_PARSERS_DIR}/opamBaseParser.mli" "${SRC_DIR}/src_ext/opam-file-format/src/" 2>/dev/null || true

  # dose3 parsers
  for subdir in "${SAVED_PARSERS_DIR}"/src_ext/dose3/src/*/; do
    if [[ -d "${subdir}" ]]; then
      local dest_dir="${SRC_DIR}/${subdir#${SAVED_PARSERS_DIR}/}"
      cp -p "${subdir}"*.ml "${dest_dir}" 2>/dev/null || true
      cp -p "${subdir}"*.mli "${dest_dir}" 2>/dev/null || true
    fi
  done

  # menhir stage2 parser files
  if [[ -d "${SAVED_PARSERS_DIR}/menhir_stage2" ]]; then
    local menhir_stage2="${SRC_DIR}/src_ext/menhir/src/stage2"
    cp -p "${SAVED_PARSERS_DIR}/menhir_stage2/"* "${menhir_stage2}/" 2>/dev/null || true
    echo "  Restored menhir stage2 files"
  fi

  echo "Restored parsers"
}
