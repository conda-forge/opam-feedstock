#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# OPAM Build Script
# ==============================================================================
# This script handles both native and cross-compilation builds of opam.
# For cross-compilation, it uses native tools (dune, cppo, menhir) and a native
# opam for man pages (ocaml_use_native), then ocaml_use_cross for the main build.
# ==============================================================================

# Source helper functions
source "${RECIPE_DIR}/building/build_functions.sh"

# ==============================================================================

echo "=== PHASE 0: Environment Setup ==="

# Recent dune enables its shared cache by default; on Windows it resolves to a
# relative path and dune crashes creating it. Not useful for a one-shot build.
export DUNE_CACHE=disabled

# macOS: OCaml compiler has @rpath/libzstd.1.dylib embedded but rpath doesn't
# resolve in build environment. Set DYLD_FALLBACK_LIBRARY_PATH so executables
# built by OCaml can find libzstd at runtime.
if is_macos; then
  export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_PREFIX}/lib:${PREFIX}/lib:${DYLD_FALLBACK_LIBRARY_PATH:-}"
  echo "Set DYLD_FALLBACK_LIBRARY_PATH for macOS: ${DYLD_FALLBACK_LIBRARY_PATH}"
fi

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
  # 1. Generate man pages / parsers with the native OCaml (ocaml_use_native)
  # 2. Switch to the cross-compiler for the main opam build (ocaml_use_cross)

  cd "${SRC_DIR}/opam"
  source "${RECIPE_DIR}"/building/cross-compile.sh
else
  cd "${SRC_DIR}/opam"

  # ==============================================================================
  # Native Build: Use external tools from our packages
  # ==============================================================================
  # Pre-built dune, cppo, menhir are in PATH (from subpackage dependencies).
  # Configure opam to use external dune, and let dune discover cppo/menhir
  # from PATH automatically (Dune's tool discovery checks PATH).
  # ==============================================================================

  echo "=== Checking for external build tools ==="
  EXTERNAL_DUNE=""
  if command -v dune &>/dev/null; then
    EXTERNAL_DUNE="$(command -v dune)"
    echo "  dune: ${EXTERNAL_DUNE}"
  fi
  if command -v cppo &>/dev/null; then
    echo "  cppo: $(command -v cppo)"
  fi
  if command -v menhir &>/dev/null; then
    echo "  menhir: $(command -v menhir)"
  fi

  # win-arm64: configure looks for an x86 cl.exe to build opam-putenv and fails
  # hard under ARM64 MSVC. apply_windows_workarounds drops the putenv dune rules
  # anyway, so neutralise that one check.
  if [[ "${target_platform}" == "win-arm64" ]]; then
    sed -i 's/as_fn_error \$? "\${COMP_ARCH} C compiler not found - opam-putenv cannot be built"/:/' configure
    # zig activation only exports ZIG_*; the vs (c_stdlib) activation then sets
    # CC/CXX=cl.exe. Point everything at the zig wrappers.
    export CC="$(cygpath -m "${ZIG_CC}")"
    export CXX="$(cygpath -m "${ZIG_CXX}")"
    export CONDA_OCAML_CC="${CC}"
    echo "win-arm64: CC=${CC} CXX=${CXX} FLEXLINKFLAGS=${FLEXLINKFLAGS:-}"
  fi

  CONFIGURE_EXTRA=""
  if [[ "${target_platform}" == "win-arm64" ]]; then
    # Static mingw link line assumes native gcc (-lunixnat, -l:libstdc++.a);
    # ocaml here is bytecode-only with zig. Let dune autolink instead.
    CONFIGURE_EXTRA="--disable-static"
  fi

  # Configure with external dune (if available) + vendored OCaml libraries
  if [[ -n "${EXTERNAL_DUNE}" ]]; then
    echo "Using external dune: ${EXTERNAL_DUNE}"
    ./configure --prefix="${OPAM_INSTALL_PREFIX}" \
      --with-vendored-deps \
      ${CONFIGURE_EXTRA:+"${CONFIGURE_EXTRA}"} \
      --with-dune="${EXTERNAL_DUNE}" > /dev/null 2>&1 || { cat config.log; exit 1; }
  else
    echo "WARNING: dune not in PATH, using vendored (slower)"
    ./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps ${CONFIGURE_EXTRA:+"${CONFIGURE_EXTRA}"} > /dev/null 2>&1 || { cat config.log; exit 1; }
  fi

  # ==============================================================================
  # Windows: Dune workarounds
  # ==============================================================================

  if is_non_unix; then
    apply_windows_workarounds
    if [[ "${target_platform}" == "win-arm64" ]]; then
      setup_win_arm64_mccs_cxx
    fi
    # opam --help=groff (man page rules) resolves its default root via HOME and
    # falls back to SHGetKnownFolderPath, which fails on CI. Give it a real home.
    OPAM_BUILD_HOME="$(cygpath -m "${SRC_DIR}/_home")"
    mkdir -p "${OPAM_BUILD_HOME}/.opam"
    export HOME="${OPAM_BUILD_HOME}"
    export USERPROFILE="${OPAM_BUILD_HOME}"
    export OPAMROOT="${OPAM_BUILD_HOME}/.opam"
    # MSVC ocamlopt runs ml64 through cmd.exe, which stops resolving commands once
    # PATH nears its ~8191 char limit; vcvars pushes it there. Drop duplicate and
    # missing dirs, and keep the MSVC bin dir first.
    if [[ "$(ocamlc -config-var c_compiler 2>/dev/null)" == cl* ]]; then
      MSVC_BIN_DIR="$(dirname "$(command -v cl.exe)")"
      _short_path=""
      IFS=: read -ra _path_dirs <<< "${MSVC_BIN_DIR}:${PATH}"
      for _d in "${_path_dirs[@]}"; do
        [[ -d "${_d}" ]] || continue
        case ":${_short_path}:" in
          *":${_d}:"*) ;;
          *) _short_path="${_short_path:+${_short_path}:}${_d}" ;;
        esac
      done
      export PATH="${_short_path}"
    fi
    # Vendored dune patch only needed if not using external dune
    if [[ -z "${EXTERNAL_DUNE}" ]] && [[ -d "src_ext/dune-local" ]]; then
      patch -p1 -d src_ext/dune-local < "${RECIPE_DIR}/patches/xxxx-fix-dune-which-double-exe-on-windows.patch"
    else
      echo "Note: Using external dune, skipping vendored dune patch"
    fi
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
rm -rf "${OPAM_INSTALL_PREFIX}"/share/opam/conda/.opam-switch/packages/cache

echo "=== Build Complete ==="
