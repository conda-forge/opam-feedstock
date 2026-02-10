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

# Windows workaround constant
readonly OPAM_STUB_HEADER_LINES=73


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

  echo "=== Pre-generating Man Pages with Native opam ==="
  mkdir -p "${native_man_dir}"

  # Build native opam using external dune (menhir/cppo from conda packages in PATH)
  echo "Building native opam for man page generation..."
  local opam_dir="${SRC_DIR}/opam"
  [[ -d "${opam_dir}" ]] || opam_dir="${SRC_DIR}"
  cd "${opam_dir}"

  # Force native OCaml environment - set CONDA_OCAML_* to build (native) compilers
  # This is critical for macOS cross-compilation where ocaml-cross-compilers is installed
  # The conda-ocaml-* wrappers read these variables to determine which actual compiler to use
  export OCAMLLIB="${BUILD_PREFIX}/lib/ocaml"
  export OCAMLPATH="${BUILD_PREFIX}/lib/ocaml"

  # Set CONDA_OCAML_* to native build compilers (not cross-compilers)
  local build_cc
  build_cc="$(get_build_c_compiler)"
  export CONDA_OCAML_CC="${build_cc:-cc}"
  export CONDA_OCAML_AS="${CONDA_TOOLCHAIN_BUILD:+${CONDA_TOOLCHAIN_BUILD}-}as"
  export CONDA_OCAML_AR="${CONDA_TOOLCHAIN_BUILD:+${CONDA_TOOLCHAIN_BUILD}-}ar"
  export CONDA_OCAML_LD="${CONDA_TOOLCHAIN_BUILD:+${CONDA_TOOLCHAIN_BUILD}-}ld"

  # Create native-only findlib.conf to prevent cross-compiler library discovery
  # The conda findlib package may have cross-compiler paths in its config
  local native_findlib_conf="${SRC_DIR}/_native_findlib.conf"
  if [[ -f "${BUILD_PREFIX}/etc/findlib.conf" ]]; then
    # Patch out cross-compiler paths, keep only native lib/ocaml
    sed -e "s|${BUILD_PREFIX}/lib/ocaml-cross-compilers/[^:\"]*|${BUILD_PREFIX}/lib/ocaml|g" \
        "${BUILD_PREFIX}/etc/findlib.conf" > "${native_findlib_conf}"
    export OCAMLFIND_CONF="${native_findlib_conf}"
  fi

  echo "Forcing native OCaml environment for man page generation:"
  echo "  OCAMLLIB=${OCAMLLIB}"
  echo "  OCAMLPATH=${OCAMLPATH}"
  echo "  OCAMLFIND_CONF=${OCAMLFIND_CONF:-<not set>}"
  echo "  CONDA_OCAML_CC=${CONDA_OCAML_CC}"
  echo "  CONDA_OCAML_AS=${CONDA_OCAML_AS}"

  if ! "${dune}" build --profile=release --root . --promote-install-files -- opam.install opam-installer.install 2>&1; then
    warn "Native build failed, skipping man page generation"
    touch "${native_man_dir}/.failed"
    return 1
  fi

  local native_opam="${opam_dir}/_build/default/src/client/opamMain.exe"
  local native_installer="${opam_dir}/_build/default/src/tools/opam_installer.exe"

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

  if [[ -x "${native_installer}" ]]; then
    "${native_installer}" --help=groff > "${native_man_dir}/opam-installer.1" 2>/dev/null || true
  fi

  # Preserve menhir-generated parser files before cleaning _build
  # Opam uses vendored menhir which would be compiled for arm64 during cross-compile.
  # Pre-generate parsers here with native menhir, then remove menhir stanzas later.
  echo "Preserving menhir-generated parser files..."
  local build_dir="${opam_dir}/_build/default"

  # opam-file-format parser (opamBaseParser.mly -> opamBaseParser.ml)
  if [[ -f "${build_dir}/src_ext/opam-file-format/src/opamBaseParser.ml" ]]; then
    cp -v "${build_dir}/src_ext/opam-file-format/src/opamBaseParser.ml" \
          "${opam_dir}/src_ext/opam-file-format/src/"
    cp -v "${build_dir}/src_ext/opam-file-format/src/opamBaseParser.mli" \
          "${opam_dir}/src_ext/opam-file-format/src/" 2>/dev/null || true
  fi

  # dose3 parsers - only copy files that have corresponding .mly sources
  for mly_file in "${opam_dir}"/src_ext/dose3/src/*/*.mly; do
    if [[ -f "$mly_file" ]]; then
      local dir=$(dirname "$mly_file")
      local base=$(basename "$mly_file" .mly)
      local rel_dir=${dir#${opam_dir}/}
      local build_subdir="${build_dir}/${rel_dir}"
      if [[ -f "${build_subdir}/${base}.ml" ]]; then
        cp -v "${build_subdir}/${base}.ml" "${dir}/"
        cp -v "${build_subdir}/${base}.mli" "${dir}/" 2>/dev/null || true
      fi
    fi
  done

  # vendored menhir's own parser (src_ext/menhir/src/stage2/parser.mly)
  if [[ -f "${build_dir}/src_ext/menhir/src/stage2/parser.ml" ]]; then
    cp -v "${build_dir}/src_ext/menhir/src/stage2/parser.ml" \
          "${opam_dir}/src_ext/menhir/src/stage2/"
    cp -v "${build_dir}/src_ext/menhir/src/stage2/parser.mli" \
          "${opam_dir}/src_ext/menhir/src/stage2/" 2>/dev/null || true
  fi

  # Clean native build artifacts before cross-compilation
  echo "Cleaning native _build..."
  rm -rf "${opam_dir}/_build"

  # Note: CONDA_OCAML_* and OCAMLLIB/OCAMLPATH will be set properly by
  # configure_cross_environment() for the cross-compilation phase

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

  local cross_ocaml_lib="${BUILD_PREFIX}/lib/ocaml-cross-compilers/${CONDA_TOOLCHAIN_HOST}/lib/ocaml"
  local native_ocaml_lib="${BUILD_PREFIX}/lib/ocaml"

  # CONDA_OCAML_* variables: Required for conda-ocaml-* wrappers
  # Dune reads tools from ocamlc -config (e.g., c_compiler="conda-ocaml-cc")
  # and calls them directly. These wrappers need environment variables to know
  # which actual cross-tools to use. Without these, they fall back to native tools.
  # macOS uses clang, Linux uses gcc
  if is_macos; then
    export CONDA_OCAML_CC="${CONDA_TOOLCHAIN_HOST}-clang"
  else
    export CONDA_OCAML_CC="${CONDA_TOOLCHAIN_HOST}-gcc"
  fi
  export CONDA_OCAML_AS="${CONDA_TOOLCHAIN_HOST}-as"
  export CONDA_OCAML_AR="${CONDA_TOOLCHAIN_HOST}-ar"
  export CONDA_OCAML_LD="${CONDA_TOOLCHAIN_HOST}-ld"
  if is_macos; then
    # Suppress linker warnings about deployment target mismatch
    # (OCaml has 10.13 baked in, but we're building for 11.0+)
    export LDFLAGS="${LDFLAGS:-} -Wl,-w"
    export CONDA_OCAML_MKEXE="${CONDA_OCAML_CC}"
    export CONDA_OCAML_MKDLL="${CONDA_OCAML_CC} -dynamiclib"
  else
    export CONDA_OCAML_MKEXE="${CONDA_OCAML_CC} -Wl,-E -ldl"
    export CONDA_OCAML_MKDLL="${CONDA_OCAML_CC} -shared"
  fi
  echo "    CONDA_OCAML_CC: ${CONDA_OCAML_CC}"
  echo "    CONDA_OCAML_MKEXE: ${CONDA_OCAML_MKEXE}"

  # OCAMLPATH: Dune library discovery (before compiler invocation)
  # Cross-first so compilation uses cross libs, native-fallback for module resolution
  export OCAMLPATH="${cross_ocaml_lib}:${native_ocaml_lib}"
  echo "    OCAMLPATH: ${OCAMLPATH}"

  # CAML_LD_LIBRARY_PATH: Native stubs for dune runtime
  # Dune (native x86_64) needs native .so stubs, not cross-compiled aarch64 ones
  local native_stublibs="${native_ocaml_lib}/stublibs"
  export CAML_LD_LIBRARY_PATH="${native_stublibs}"
  echo "    CAML_LD_LIBRARY_PATH: ${native_stublibs}"
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

patch_ocaml_makefile_config() {
  echo "  Patching OCaml Makefile.config for target architecture..."
  local ocaml_lib=$(ocamlc -where)
  local ocaml_config="${ocaml_lib}/Makefile.config"

  if [[ -f "${ocaml_config}" ]]; then
    echo "    Patching: ${ocaml_config}"
    cp "${ocaml_config}" "${ocaml_config}.bak"
    local target_cc="$(get_target_c_compiler)"
    sed -i "s|^CC=.*|CC=${target_cc}|" "${ocaml_config}"
    sed -i "s|^NATIVE_C_COMPILER=.*|NATIVE_C_COMPILER=${target_cc}|" "${ocaml_config}"
    sed -i "s|^BYTECODE_C_COMPILER=.*|BYTECODE_C_COMPILER=${target_cc}|" "${ocaml_config}"
    sed -i "s|^PACKLD=.*|PACKLD=${CONDA_TOOLCHAIN_HOST}-ld -r -o \$(EMPTY)|" "${ocaml_config}"
    sed -i "s|^ASM=.*|ASM=${CONDA_TOOLCHAIN_HOST}-as|" "${ocaml_config}"
    sed -i "s|^TOOLPREF=.*|TOOLPREF=${CONDA_TOOLCHAIN_HOST}-|" "${ocaml_config}"
    echo "    Patched config entries:"
    grep -E "^(CC|NATIVE_C_COMPILER|BYTECODE_C_COMPILER|PACKLD|ASM|TOOLPREF)=" "${ocaml_config}"
  else
    echo "    WARNING: OCaml Makefile.config not found at ${ocaml_config}"
  fi
}

patch_opam_makefile_config() {
  # Fix OCAMLLIB in opam's Makefile.config to point to cross-compiled libraries
  # configure captured native OCAMLLIB; we need cross path
  local makefile_config="${SRC_DIR}/opam/Makefile.config"
  [[ -f "${makefile_config}" ]] || makefile_config="${SRC_DIR}/Makefile.config"

  if [[ -f "${makefile_config}" ]]; then
    local cross_ocamllib=$(ocamlc -where)
    echo "  Patching opam Makefile.config OCAMLLIB to: ${cross_ocamllib}"
    sed -i "s|^OCAMLLIB = .*|OCAMLLIB = ${cross_ocamllib}|" "${makefile_config}"
    grep "^OCAMLLIB" "${makefile_config}"
  fi
}

clear_build_caches() {
  echo "  Clearing build caches for cross-compilation..."
  echo "  SRC_DIR=${SRC_DIR}"

  # Clear any _build directories from native man page generation
  rm -rf "${SRC_DIR}/_build" 2>/dev/null || true
  rm -rf "${SRC_DIR}/opam/_build" 2>/dev/null || true

  # Clear vendored library build caches
  for ext_dir in "${SRC_DIR}"/src_ext/*/; do
    rm -rf "${ext_dir}/_build" 2>/dev/null || true
  done
  for ext_dir in "${SRC_DIR}"/opam/src_ext/*/; do
    rm -rf "${ext_dir}/_build" 2>/dev/null || true
  done

  # Remove object files and static libraries from previous builds
  # CRITICAL: Dune promotes .a files to source tree during native build
  # These are x86_64 and will cause "skipping incompatible" errors during cross-compile
  echo "  Looking for .a files to remove..."
  find "${SRC_DIR}" -name "*.a" -not -path "*/ocaml/*" 2>/dev/null | head -10 || true
  find "${SRC_DIR}" -name "*.o" -delete 2>/dev/null || true
  find "${SRC_DIR}" -name "*.a" -not -path "*/ocaml/*" -delete 2>/dev/null || true
  echo "  Build caches cleared"
}

# ==============================================================================
# WINDOWS WORKAROUNDS
# ==============================================================================

# Apply Windows-specific workarounds for Dune build system
# Dune on Windows doesn't properly handle conditional rules during analysis phase.
apply_windows_workarounds() {
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
# Parser File Generation
# ==============================================================================

# Generate parser files for opam-file-format and dose3 using menhir from conda
generate_parser_files() {
  local menhir="${1}"

  echo "Pre-generating parser files with menhir..."
  local opam_dir="${SRC_DIR}/opam"
  [[ -d "${opam_dir}" ]] || opam_dir="${SRC_DIR}"
  cd "${opam_dir}"

  # opam-file-format: generates opamBaseParser.ml from opamBaseParser.mly
  if [[ -f "src_ext/opam-file-format/src/opamBaseParser.mly" ]]; then
    echo "  Generating opam-file-format parser..."
    "${menhir}" --ocamlc ocamlc \
      --base "src_ext/opam-file-format/src/opamBaseParser" \
      "src_ext/opam-file-format/src/opamBaseParser.mly" 2>&1 || echo "    Warning: failed"
  fi

  # dose3: generates several parsers
  for mly in src_ext/dose3/src/versioning/version*.mly src_ext/dose3/src/*/parser*.mly; do
    if [[ -f "$mly" ]]; then
      local dir=$(dirname "$mly")
      local base=$(basename "$mly" .mly)
      echo "  Generating parser: $mly"
      "${menhir}" --ocamlc ocamlc --base "${dir}/${base}" "$mly" 2>&1 || echo "    Warning: failed"
    fi
  done
}
