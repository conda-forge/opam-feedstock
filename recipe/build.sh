#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# Environment Setup
# ==============================================================================

# Set up path variables for OCaml and libraries
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OCAMLLIB="${BUILD_PREFIX}/lib/ocaml"
  export BUILD_INC="${BUILD_PREFIX}/include"
  export BUILD_LIB="${BUILD_PREFIX}/lib"
  export HOST_LIB="${PREFIX}/lib"
else
  # Windows paths use Library subdirectory
  export OCAML_PREFIX="${_BUILD_PREFIX_}/Library"
  export OCAMLLIB="${_BUILD_PREFIX_}/Library/lib/ocaml"
  export BUILD_INC="${_BUILD_PREFIX_}/Library/include"
  export BUILD_LIB="${_BUILD_PREFIX_}/Library/lib"
  export HOST_LIB="${_PREFIX_}/Library/lib"
fi

# ==============================================================================
# OPAM Build
# ==============================================================================

if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OPAM_INSTALL_PREFIX="${PREFIX}"
else
  export OPAM_INSTALL_PREFIX="${_PREFIX_}/Library"
  BZIP2=$(find ${_BUILD_PREFIX_} ${_PREFIX_} \( -name bzip2 -o -name bzip2.exe \) \( -type f -o -type l \) -perm /111 | head -1)
  export BUNZIP2="${BZIP2} -d"
  export CC64=false
fi

./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps || { cat config.log; exit 1; }

make
make install
