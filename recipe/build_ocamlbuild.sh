#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# OCaml 5.3.0_0 - Environment Setup
# ==============================================================================

# Set up path variables for OCaml and libraries
if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export OCAMLLIB="${BUILD_PREFIX}/lib/ocaml"
  export BUILD_INC="${BUILD_PREFIX}/include"
  export BUILD_LIB="${BUILD_PREFIX}/lib"
  export HOST_PREFIX="${PREFIX}"
  export HOST_LIB="${HOST_PREFIX}/lib"
else
  # Windows paths use Library subdirectory
  export OCAML_PREFIX="${_BUILD_PREFIX_}/Library"
  export OCAMLLIB="${_BUILD_PREFIX_}/Library/lib/ocaml"
  export BUILD_INC="${_BUILD_PREFIX_}/Library/include"
  export BUILD_LIB="${_BUILD_PREFIX_}/Library/lib"
  export HOST_PREFIX="${_PREFIX_}/Library"
  export HOST_LIB="${HOST_PREFIX}/lib"
  # Stublibs path for bytecode DLLs (dllunixbyt.dll, etc.)
  export CAML_LD_LIBRARY_PATH="${OCAMLLIB}/stublibs"
fi

if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-"* ]]; then
  export HOST_PREFIX="${PREFIX}"
  if [[ "${target_platform}" == "osx-"* ]]; then
    # Ensure dynamic linker can find libraries at runtime
    export DYLD_FALLBACK_LIBRARY_PATH="${BUILD_LIB}:${HOST_LIB}${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
    export LIBRARY_PATH="${BUILD_LIB}:${HOST_LIB}${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export LDFLAGS="-L${BUILD_LIB} -L${HOST_LIB} ${LDFLAGS:-}"
  fi
else
  export HOST_PREFIX="${_PREFIX_}/Library"
fi

export OCAMLBUILD_PREFIX=${HOST_PREFIX}

export OCAMLBUILD_BINDIR=${OCAMLBUILD_PREFIX}/bin
export OCAMLBUILD_LIBDIR=${OCAMLBUILD_PREFIX}/lib/ocaml
export OCAMLBUILD_MANDIR=${OCAMLBUILD_PREFIX}/share/man

# # Modifying the assumption that ocaml is installed in PREFIX - Now, maybe it should (?)
# sed -i 's/OCAML_PREFIX = $(PREFIX)/OCAML_PREFIX = $(OCAML_PREFIX)/' configure.make

pushd ocamlbuild
  make -f configure.make
  if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
    sed -i -E "s#(=)[^\|]*rattler-build_ocaml_[^\|]*Library#\1${_PREFIX_}/Library#g" "${SRC_DIR}/ocamlbuild/Makefile.config"
    sed -i -E "s#(\|)[^\|]*rattler-build_ocaml_[^\|]*Library#\1${_PREFIX_}/Library#g" "${SRC_DIR}/ocamlbuild/src/ocamlbuild_config.ml"
  fi

  make configure
  LINKFLAGS="" make native byte man
  # This needs ocamlfind:
  # make tests
  make install-bin-native install-lib install-man
popd
