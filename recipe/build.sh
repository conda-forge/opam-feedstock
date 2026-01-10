# from https://github.com/Homebrew/homebrew-core/blob/master/Formula/opam.rb#L24-L27

# OCaml has hardcoded placeholder paths (~264 chars) baked into the binary for standard_library.
# This causes command line corruption when OCaml constructs linker commands.
# Override with OCAMLLIB to use actual BUILD_PREFIX path.
export OCAMLLIB="${BUILD_PREFIX}/lib/ocaml"
echo "OCAMLLIB=${OCAMLLIB}"

# Verify OCaml can find its libraries
ocamlc -where

# OCaml has hardcoded zstd library paths from its build environment that may not exist.
# The OCaml compiler stores library paths in its config that include placeholder paths
# that weren't properly relocated. We need to ensure the linker can find zstd.
if [[ "${target_platform}" == "osx-"* ]]; then
    # Find OCaml's lib directory and check its config
    OCAML_LIB=$(ocamlc -where)
    echo "OCaml lib directory: ${OCAML_LIB}"

    # Show OCaml's configuration for debugging
    ocamlc -config | grep -i lib || true

    # Check both BUILD_PREFIX (where OCaml is) and PREFIX (where zstd might be)
    # OCaml is in build env, zstd might be in build or host env
    BUILD_LIB="${BUILD_PREFIX}/lib"
    HOST_LIB="${PREFIX}/lib"

    # # Backup and fix ld.conf if it exists and contains placeholder paths
    # if [[ -f "${OCAML_LIB}/ld.conf" ]]; then
    #     echo "Original ld.conf:"
    #     cat "${OCAML_LIB}/ld.conf"
    #     # Replace placeholder paths with BUILD_PREFIX (where zstd should be in build env)
    #     sed -i.bak "s|.*/host_env_placehold[^/]*/lib|${BUILD_LIB}|g" "${OCAML_LIB}/ld.conf"
    #     echo "Fixed ld.conf:"
    #     cat "${OCAML_LIB}/ld.conf"
    # fi

    # # Fix Makefile.config if it contains placeholder paths
    # if [[ -f "${OCAML_LIB}/Makefile.config" ]]; then
    #     sed -i.bak "s|.*/host_env_placehold[^/]*/lib|${BUILD_LIB}|g" "${OCAML_LIB}/Makefile.config"
    # fi

    # Ensure linker can find zstd via environment - check both build and host prefixes
    export LIBRARY_PATH="${BUILD_LIB}:${HOST_LIB}${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export LDFLAGS="-L${BUILD_LIB} -L${HOST_LIB} ${LDFLAGS:-}"

    # echo "LIBRARY_PATH=${LIBRARY_PATH}"
    # echo "LDFLAGS=${LDFLAGS}"
    # echo "Checking for zstd:"
    # ls -la "${BUILD_LIB}"/libzstd* 2>/dev/null || echo "No zstd in BUILD_PREFIX"
    # ls -la "${HOST_LIB}"/libzstd* 2>/dev/null || echo "No zstd in PREFIX"
fi

  echo "=== OCaml Makefile.config ZSTD/BYTECCLIBS ==="
  grep -E "ZSTD|BYTECCLIBS" "${BUILD_PREFIX}/lib/ocaml/Makefile.config"
  echo "=== Check for any @ in Makefile.config ==="
  grep "@" "${BUILD_PREFIX}/lib/ocaml/Makefile.config" || echo "No @ found"
  echo "=== Full LDFLAGS line ==="
  grep "^LDFLAGS" "${BUILD_PREFIX}/lib/ocaml/Makefile.config"
  echo "=== end debug ==="
  strings "${BUILD_PREFIX}/bin/ocamlopt" | grep -E "BYTECCLIBS|ZSTD|lib@" | head -10
  echo "PREFIX=$PREFIX"
  echo "BUILD_PREFIX=$BUILD_PREFIX"
  ls -la "${BUILD_PREFIX}/lib/ocaml/Makefile.config"
  # export OCAMLPARAM='verbose=1,_'
  # export DUNE_CONFIG__DISPLAY=verbose
  export CC64=false
./configure --prefix=$PREFIX --with-vendored-deps
make
make install

# if [[ "${target_platform}" == "linux-"* ]] || [[ "${target_platform}" == "osx-64" ]]; then
#   make libinstall
# fi
