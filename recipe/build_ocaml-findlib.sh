#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# CRITICAL: Ensure we're using conda bash 5.2+, not system bash
# ==============================================================================
if [[ ${BASH_VERSINFO[0]} -lt 5 || (${BASH_VERSINFO[0]} -eq 5 && ${BASH_VERSINFO[1]} -lt 2) ]]; then
  echo "re-exec with conda bash..."
  if [[ -x "${BUILD_PREFIX}/bin/bash" ]]; then
    exec "${BUILD_PREFIX}/bin/bash" "$0" "$@"
  else
    echo "ERROR: Could not find conda bash at ${BUILD_PREFIX}/bin/bash"
    exit 1
  fi
fi

source "${RECIPE_DIR}/building/build_functions.sh"

if is_non_unix; then
  LIBDIR="${PREFIX}/Library"
else
  LIBDIR="${PREFIX}"
fi

pushd ocaml-findlib
  ./configure \
    -bindir "${LIBDIR}"/bin \
    -sitelib "${LIBDIR}"/lib/ocaml/site-lib \
    -config "${LIBDIR}"/etc/findlib.conf \
    -mandir "${LIBDIR}"/share/man || { cat ocargs.log; exit 1; }

  # Patch findlib_config.mlp BEFORE compilation to use runtime env vars
  # This ensures both bytecode (.cma) and native (.cmxa) use dynamic paths
  # Use Sys.getenv_opt with fallback to avoid crashes if OCAMLLIB not set
  sed -i 's#let ocaml_stdlib = "@STDLIB@";;#let ocaml_stdlib = match Sys.getenv_opt "OCAMLLIB" with Some v -> v | None -> failwith "OCAMLLIB environment variable not set";;#g' src/findlib/findlib_config.mlp

  if is_cross_compile; then
    # CROSS-COMPILATION STRATEGY:
    # The cross-compilers package bundles native OCaml alongside cross-compilers.
    # - ocamlfind is a BUILD TOOL - must be built with NATIVE compiler (runs on x86_64)
    # - Libraries (.cma, .cmxa) should be built with CROSS compiler (for aarch64 target)
    #
    # libcamlrun.a is x86_64 (for native bytecode runtime) - this is correct!
    # libasmrun.a is aarch64 (for cross-compiled native code) - this is correct!

    echo "=== STEP 1: Build ocamlfind with NATIVE compiler (runs on build machine) ==="
    # Don't swap compilers yet - use native ocaml to build the tool
    make all

    echo "=== STEP 2: Build cross-compiled libraries ==="
    # Now swap to cross-compilers for building target libraries
    swap_ocaml_compilers
    setup_cross_c_compilers
    configure_cross_environment
    patch_ocaml_makefile_config

    # Build native-code libraries for target (uses aarch64 libasmrun.a)
    make opt CC="${CC}" AR="${AR}" RANLIB="${RANLIB}"

    make install
  else
    make all
    make opt
    make install
  fi

  # Move topfind to correct location and fix hardcoded paths
  # On Unix: topfind is at ${BUILD_PREFIX}/lib/ocaml/topfind
  # On non-unix: topfind is at ${BUILD_PREFIX}/Library/lib/ocaml/topfind
  TOPFIND_SRC=""
  if [[ -f "${BUILD_PREFIX}/lib/ocaml/topfind" ]]; then
    TOPFIND_SRC="${BUILD_PREFIX}/lib/ocaml/topfind"
  elif [[ -f "${BUILD_PREFIX}/Library/lib/ocaml/topfind" ]]; then
    TOPFIND_SRC="${BUILD_PREFIX}/Library/lib/ocaml/topfind"
  fi

  if [[ -n "${TOPFIND_SRC}" ]]; then
    mv "${TOPFIND_SRC}" "${LIBDIR}/lib/ocaml/"
  fi

  # For non-unix: use forward slashes consistently (rattler-build uses forward slashes for prefix)
  if is_non_unix; then
    # Write findlib.conf with forward slashes - Windows OCaml handles this fine
    sed -i "s@destdir=\"[^\"]*\"@destdir=\"${_PREFIX_}/Library/lib/ocaml/site-lib\"@g" "${LIBDIR}"/etc/findlib.conf
    sed -i "s@path=\"[^\"]*\"@path=\"${_PREFIX_}/Library/lib/ocaml;${_PREFIX_}/Library/lib/ocaml/site-lib\"@g" "${LIBDIR}"/etc/findlib.conf

    # Replace build_env with h_env in Makefile.config, keep forward slashes
    sed -i 's@build_env@h_env@g' "${LIBDIR}"/lib/ocaml/site-lib/findlib/Makefile.config
  else
    sed -i "s@${BUILD_PREFIX}@${PREFIX}@g" "${LIBDIR}"/etc/findlib.conf "${LIBDIR}"/lib/ocaml/site-lib/findlib/Makefile.config
  fi

  for CHANGE in "activate" "deactivate"
  do
    mkdir -p "${PREFIX}/etc/conda/${CHANGE}.d"
    if is_non_unix; then
      cp "${RECIPE_DIR}/activation/ocaml-findlib-${CHANGE}.bat" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.bat"
    else
      cp "${RECIPE_DIR}/activation/ocaml-findlib-${CHANGE}.sh" "${PREFIX}/etc/conda/${CHANGE}.d/${PKG_NAME}_${CHANGE}.sh"
    fi
  done
popd
