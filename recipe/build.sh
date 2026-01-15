#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

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

  # Ensure OCaml binaries AND MinGW gcc are in PATH for dune bootstrap
  # Dune uses Bin.which to search PATH - it DOES respect PATH (contrary to old comments)
  # The copy workaround was broken because gcc needs cc1 from lib/gcc/...
  #
  # Key directories:
  # - BUILD_PREFIX/Library/bin: contains x86_64-w64-mingw32-gcc.exe
  # - BUILD_PREFIX/Library/mingw-w64/bin: alternative MinGW location
  # - BUILD_PREFIX/bin: OCaml tools
  export PATH="${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/Library/mingw-w64/bin:${BUILD_PREFIX}/bin:${PATH}"

  echo "=== Windows PATH setup (no copy workaround - gcc needs its full toolchain) ==="
  echo "PATH includes:"
  echo "  - ${BUILD_PREFIX}/Library/bin"
  echo "  - ${BUILD_PREFIX}/Library/mingw-w64/bin"
  echo "  - ${BUILD_PREFIX}/bin"

  # Make ocamlopt verbose to see ar/as/ld commands for debugging archive creation
  export OCAMLPARAM="verbose=1,_"
  echo "OCAMLPARAM=${OCAMLPARAM} (ocamlopt will show external commands)"

  # Fix MSYS2 argument passing issue with ar.exe
  # When ocamlopt calls ar.exe with multiple .o files, MSYS2's automatic path
  # conversion mangles the arguments, treating "file1.o file2.o file3.o" as ONE filename
  # Setting MSYS2_ARG_CONV_EXCL=* disables this conversion, allowing proper argument passing
  export MSYS2_ARG_CONV_EXCL="*"
  echo "MSYS2_ARG_CONV_EXCL=${MSYS2_ARG_CONV_EXCL} (disable MSYS2 path conversion to fix ar.exe argument passing)"
fi

# ==============================================================================
# Cross-compilation setup for OCaml
# ==============================================================================
# When cross-compiling (build_platform != target_platform), we need to:
# 1. Build dune with native compiler (it runs on build machine)
# 2. Swap to cross-compiler for the main opam build

if [[ "${target_platform}" != "${build_platform:-${target_platform}}" ]]; then
  # Configure first (uses native tools for detection)
  ./configure \
    --build="${CONDA_TOOLCHAIN_BUILD}" \
    --host="${CONDA_TOOLCHAIN_BUILD}" \
    --target="${CONDA_TOOLCHAIN_HOST}" \
    --prefix="${OPAM_INSTALL_PREFIX}" \
    --with-vendored-deps \
    || { cat config.log; exit 1; }

  # Phase 1: Build dune with native compiler
  file $BUILD_PREFIX/lib/ocaml/unix/unix.cma
  ocamlc -config
  (
    export CONDA_OCAML_AS="${CONDA_TOOLCHAIN_BUILD}"-as
    export CONDA_OCAML_AR="${CONDA_TOOLCHAIN_BUILD}"-gcc-ar
    export CONDA_OCAML_CC="${CONDA_TOOLCHAIN_BUILD}"-gcc
    export CONDA_OCAML_LD="${CONDA_TOOLCHAIN_BUILD}"-ld
    export CONDA_OCAML_RANLIB="${CONDA_TOOLCHAIN_BUILD}"-gcc-ranlib
    make src_ext/dune-local/_boot/dune.exe
  )
  ocamlc -config | grep target
  
  # Phase 2: Swap to cross-compilers for the main build
  # Dune discovers compilers by looking for ocamlc/ocamlopt in PATH
  # We swap the base and .opt variants to point to cross-compilers
  pushd "${BUILD_PREFIX}/bin"
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
  popd
else
  ./configure --prefix="${OPAM_INSTALL_PREFIX}" --with-vendored-deps || { cat config.log; exit 1; }
fi

# ==============================================================================
# Windows: Dune workarounds
# ==============================================================================
# Dune on Windows doesn't properly handle conditional rules during analysis.
# These fixes are required for any OCaml 5.x on Windows.

if [[ "${target_platform}" != "linux-"* ]] && [[ "${target_platform}" != "osx-"* ]]; then
  # ---------------------------------------------------------------------------
  # DEBUG: Comprehensive environment dump - UNDERSTANDING DUNE'S SEARCH
  # ---------------------------------------------------------------------------
  echo "========================================"
  echo "DEBUG: Windows build environment"
  echo "========================================"
  echo ""

  # CRITICAL: What does ocamlc -config say about the C compiler?
  echo "=== OCaml's C Compiler Configuration ==="
  echo "This is what Dune reads to find the compiler:"
  OCAML_C_COMPILER=$(ocamlc -config | grep "^c_compiler:" | sed 's/c_compiler: //')
  echo "  c_compiler: '${OCAML_C_COMPILER}'"
  echo ""

  # Does it have a path or just a name?
  if [[ "${OCAML_C_COMPILER}" == */* ]] || [[ "${OCAML_C_COMPILER}" == *\\* ]]; then
    echo "  -> Contains path separator - Dune will try to use as-is"
    echo "  -> Checking if file exists at that path:"
    if [[ -f "${OCAML_C_COMPILER}" ]]; then
      echo "     EXISTS: $(ls -la "${OCAML_C_COMPILER}")"
    else
      echo "     DOES NOT EXIST at '${OCAML_C_COMPILER}'"
      # Try with .exe
      if [[ -f "${OCAML_C_COMPILER}.exe" ]]; then
        echo "     BUT EXISTS WITH .exe: $(ls -la "${OCAML_C_COMPILER}.exe")"
      fi
    fi
  else
    echo "  -> Just a name (no path) - Dune will search PATH using Bin.which"
  fi
  echo ""

  # Show ALL compiler-related config
  echo "=== All compiler-related ocamlc -config entries ==="
  ocamlc -config | grep -E "(c_compiler|native_c_compiler|bytecomp_c_compiler|native_pack_linker|asm|ccomp_type|architecture|system|target|standard_library)"
  echo ""

  # Environment variables
  echo "=== Environment variables ==="
  echo "CC=${CC:-<unset>}"
  echo "CXX=${CXX:-<unset>}"
  echo "BUILD_PREFIX=${BUILD_PREFIX}"
  echo "_BUILD_PREFIX_=${_BUILD_PREFIX_:-<unset>}"
  echo "PREFIX=${PREFIX}"
  echo "_PREFIX_=${_PREFIX_:-<unset>}"
  echo ""

  # CRITICAL: Show FULL PATH (Dune's Bin.which iterates through this)
  echo "=== FULL PATH (Dune searches these IN ORDER) ==="
  echo "${PATH}" | tr ':' '\n' | nl -ba
  echo ""

  # Now manually simulate what Dune's Bin.which does
  echo "=== Simulating Dune's Bin.which for '${OCAML_C_COMPILER}' ==="
  SEARCH_NAME="${OCAML_C_COMPILER}"
  SEARCH_NAME_EXE="${OCAML_C_COMPILER}.exe"

  echo "Searching for: '${SEARCH_NAME}' or '${SEARCH_NAME_EXE}'"
  echo ""

  FOUND_AT=""
  IFS=':' read -ra PATH_DIRS <<< "${PATH}"
  for i in "${!PATH_DIRS[@]}"; do
    DIR="${PATH_DIRS[$i]}"
    if [[ -z "${DIR}" ]]; then
      echo "  [$((i+1))] (empty entry, skipped)"
      continue
    fi

    # Check without .exe
    CANDIDATE="${DIR}/${SEARCH_NAME}"
    if [[ -f "${CANDIDATE}" ]]; then
      echo "  [$((i+1))] FOUND: ${CANDIDATE}"
      ls -la "${CANDIDATE}" 2>/dev/null || true
      FOUND_AT="${CANDIDATE}"
      break
    fi

    # Check with .exe (Dune does this on Windows)
    CANDIDATE_EXE="${DIR}/${SEARCH_NAME_EXE}"
    if [[ -f "${CANDIDATE_EXE}" ]]; then
      echo "  [$((i+1))] FOUND (.exe): ${CANDIDATE_EXE}"
      ls -la "${CANDIDATE_EXE}" 2>/dev/null || true
      FOUND_AT="${CANDIDATE_EXE}"
      break
    fi

    # Show what's NOT there
    echo "  [$((i+1))] NOT in: ${DIR}/"
  done

  if [[ -z "${FOUND_AT}" ]]; then
    echo ""
    echo "  *** NOT FOUND IN ANY PATH DIRECTORY ***"
  fi
  echo ""

  # Show what gcc files actually exist
  echo "=== Actual gcc files in key locations ==="
  for DIR in "${BUILD_PREFIX}/Library/bin" "${BUILD_PREFIX}/Library/mingw-w64/bin" "${BUILD_PREFIX}/bin" "${_BUILD_PREFIX_}/Library/bin" "${_BUILD_PREFIX_}/Library/mingw-w64/bin"; do
    if [[ -d "${DIR}" ]]; then
      echo "In ${DIR}:"
      ls -la "${DIR}/"*gcc* 2>/dev/null | head -5 || echo "  (no gcc found)"
    fi
  done
  echo ""

  # Test if 'which' can find it (bash's PATH search)
  echo "=== Bash 'which' and 'command -v' tests ==="
  echo "which ${OCAML_C_COMPILER}:"
  which "${OCAML_C_COMPILER}" 2>&1 || echo "  (not found)"
  echo "which ${OCAML_C_COMPILER}.exe:"
  which "${OCAML_C_COMPILER}.exe" 2>&1 || echo "  (not found)"
  echo "command -v ${OCAML_C_COMPILER}:"
  command -v "${OCAML_C_COMPILER}" 2>&1 || echo "  (not found)"
  echo ""

  # Test if it's executable (could be found but not executable)
  echo "=== Executability test ==="
  if command -v "${OCAML_C_COMPILER}" &>/dev/null; then
    FOUND_PATH=$(command -v "${OCAML_C_COMPILER}")
    echo "Found at: ${FOUND_PATH}"
    echo "Permissions: $(ls -la "${FOUND_PATH}")"
    echo "File type: $(file "${FOUND_PATH}" 2>/dev/null || echo "unknown")"
    echo "Running --version:"
    "${FOUND_PATH}" --version 2>&1 | head -2 || echo "  (failed to run)"
  else
    echo "Cannot test executability - compiler not found in PATH"
  fi
  echo "========================================"
  echo ""

  # ---------------------------------------------------------------------------
  # Step 1: Ensure Dune can find the C compiler
  # ---------------------------------------------------------------------------
  # Dune reads OCaml's -config to get the C compiler name (e.g., x86_64-w64-mingw32-gcc)
  # and tries to find it in PATH. We need to ensure this compiler is available.

  EXPECTED_CC=$(ocamlc -config | grep "^c_compiler:" | awk '{print $2}')
  echo "OCaml expects C compiler: ${EXPECTED_CC}"

  # Add potential mingw locations to PATH
  export PATH="${BUILD_PREFIX}/Library/mingw-w64/bin:${BUILD_PREFIX}/Library/bin:${BUILD_PREFIX}/bin:${PATH}"

  # Check if expected compiler is available
  if ! command -v "${EXPECTED_CC}" &>/dev/null; then
    echo "WARNING: ${EXPECTED_CC} not found in PATH"
    echo "Current PATH: ${PATH}"
    echo ""
    echo "Searching for gcc variants..."

    # Search for any gcc in known locations
    GCC_FOUND=""
    for dir in "${BUILD_PREFIX}/Library/mingw-w64/bin" "${BUILD_PREFIX}/Library/bin" "${BUILD_PREFIX}/bin"; do
      if [[ -d "${dir}" ]]; then
        echo "  Checking ${dir}:"
        ls -la "${dir}/"*gcc* 2>/dev/null || echo "    (no gcc found)"

        # Look for the expected compiler or generic gcc
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
      # Create symlink/wrapper for expected compiler name if we found gcc under different name
      GCC_DIR=$(dirname "${GCC_FOUND}")
      GCC_BASE=$(basename "${GCC_FOUND}")

      if [[ "${GCC_BASE}" != "${EXPECTED_CC}"* ]]; then
        echo "Creating wrapper: ${GCC_DIR}/${EXPECTED_CC}.exe -> ${GCC_FOUND}"
        # On Windows/MSYS2, copy instead of symlink for compatibility
        cp "${GCC_FOUND}" "${GCC_DIR}/${EXPECTED_CC}.exe" 2>/dev/null || \
          ln -sf "${GCC_BASE}" "${GCC_DIR}/${EXPECTED_CC}" 2>/dev/null || \
          echo "WARNING: Could not create wrapper"
      fi
    else
      echo "ERROR: No gcc found in any expected location"
      echo "Falling back to removing foreign_stubs approach..."

      # Remove foreign_stubs section - CORRECTED PATTERN
      # Note: The section starts with "  (foreign_stubs" (2 spaces) and ends with "c-flags.sexp)))"
      sed -i '/^  (foreign_stubs$/,/c-flags\.sexp)))/d' src/core/dune

      # Since we removed foreign_stubs, Dune won't compile C code
      # We need to compile it manually and link via c_library_flags
      # This is complex and may not work for all cases
      echo "WARNING: Manual C compilation fallback - this may not work!"
    fi
  else
    echo "C compiler ${EXPECTED_CC} found in PATH"
    which "${EXPECTED_CC}" || true
  fi

  # ---------------------------------------------------------------------------
  # Step 2: Remove problematic dune rules for Windows
  # ---------------------------------------------------------------------------
  # These rules use features not available on Windows/MSYS2
  sed -i '/^(rule$/,/cc64)))/d' src/core/dune
  sed -i '/^(install$/,/opam-putenv\.exe))/d' src/core/dune

  # ---------------------------------------------------------------------------
  # Step 3: Pre-create generated .ml files
  # ---------------------------------------------------------------------------
  echo "let value = \"\"" > src/core/opamCoreConfigDeveloper.ml
  echo "let version = \"${PKG_VERSION}\"" > src/core/opamVersionInfo.ml
  cp src/core/opamStubs.ocaml5.ml src/core/opamStubs.ml
  cp src/core/opamWin32Stubs.win32.ml src/core/opamWin32Stubs.ml

  # ---------------------------------------------------------------------------
  # Step 4: Windows system libraries for linking
  # ---------------------------------------------------------------------------
  echo '(-ladvapi32 -lgdi32 -luser32 -lshell32 -lole32 -luuid -luserenv)' > src/core/c-libraries.sexp

  # ---------------------------------------------------------------------------
  # Step 5: Create opam_stubs.c by inlining included C files
  # ---------------------------------------------------------------------------
  # opamCommonStubs.c uses #include to inline other C files
  pushd src/core > /dev/null
  head -n 73 opamCommonStubs.c > opam_stubs.c
  cat opamInject.c >> opam_stubs.c
  cat opamWindows.c >> opam_stubs.c
  popd > /dev/null

  # ---------------------------------------------------------------------------
  # DEBUG: Environment right before make
  # ---------------------------------------------------------------------------
  echo ""
  echo "========================================"
  echo "DEBUG: Environment right before make"
  echo "========================================"
  echo "=== Final PATH check for expected compiler ==="
  echo "Looking for: ${EXPECTED_CC}"
  which "${EXPECTED_CC}" 2>/dev/null && echo "Found in PATH!" || echo "NOT FOUND in PATH"
  which "${EXPECTED_CC}.exe" 2>/dev/null && echo "Found .exe in PATH!" || echo ".exe NOT FOUND in PATH"
  echo ""
  echo "=== Checking if it's executable ==="
  if command -v "${EXPECTED_CC}" &>/dev/null; then
    echo "command -v finds it: $(command -v "${EXPECTED_CC}")"
    "${EXPECTED_CC}" --version 2>&1 | head -1 || echo "Failed to run --version"
  fi
  echo "========================================"
  echo ""

  # ---------------------------------------------------------------------------
  # DEBUG: Understand Dune's internal environment
  # ---------------------------------------------------------------------------
  echo ""
  echo "========================================"
  echo "DEBUG: Dune's perspective"
  echo "========================================"

  # Check if Dune has internal debug flags
  echo "=== Dune version and capabilities ==="
  dune --version 2>/dev/null || echo "dune command not available yet"

  # Check PATH in Windows format (semicolons)
  echo ""
  echo "=== PATH in Windows format (Dune might use this) ==="
  # On MSYS2, PATH uses colons internally but Windows uses semicolons
  echo "MSYS PATH (colons): ${PATH:0:200}..."
  # Convert to Windows format
  if command -v cygpath &>/dev/null; then
    echo "Windows PATH available via cygpath"
  fi

  # Check Dune's own PATH handling
  echo ""
  echo "=== Test: Can OCaml programs execute the compiler? ==="
  # This tests if OCaml's subprocess spawning can find the compiler
  cat > /tmp/test_cc.ml << 'OCAML_EOF'
let () =
  let config = Sys.command "ocamlc -config" in
  Printf.printf "ocamlc -config exit code: %d\n" config;
  (* Try to run the C compiler *)
  let cc_line =
    let ic = Unix.open_process_in "ocamlc -config" in
    let rec find () =
      try
        let line = input_line ic in
        if String.length line > 12 && String.sub line 0 12 = "c_compiler: " then
          String.sub line 12 (String.length line - 12)
        else find ()
      with End_of_file -> ""
    in
    let result = find () in
    ignore (Unix.close_process_in ic);
    result
  in
  Printf.printf "c_compiler from config: '%s'\n" cc_line;
  if cc_line <> "" then begin
    Printf.printf "Attempting to run: %s --version\n" cc_line;
    let exit_code = Sys.command (cc_line ^ " --version") in
    Printf.printf "Exit code: %d\n" exit_code
  end
OCAML_EOF
  echo "Running OCaml test to see if OCaml can spawn the compiler:"
  ocaml unix.cma /tmp/test_cc.ml 2>&1 || echo "(OCaml test failed)"

  echo "========================================"
  echo ""

  # Enable Dune verbose output to see exactly what it's searching for
  export DUNE_ARGS="--verbose"
fi

echo ""
echo "========================================"
echo "Starting make with DUNE_ARGS=${DUNE_ARGS:-<default>}"
echo "========================================"

if ! make; then
  echo ""
  echo "========================================"
  echo "DEBUG: make failed - checking .o files for opam_client"
  echo "========================================"

  # Check if the opam_client .o files exist
  OBJ_DIR="_build/default/src/client/.opam_client.objs/native"
  if [[ -d "${OBJ_DIR}" ]]; then
    echo "=== Contents of ${OBJ_DIR} ==="
    ls -la "${OBJ_DIR}/"*.o 2>/dev/null | head -30 || echo "(no .o files found)"
    echo ""
    echo "=== Count of .o files ==="
    ls "${OBJ_DIR}/"*.o 2>/dev/null | wc -l || echo "0"
  else
    echo "Directory ${OBJ_DIR} does not exist!"
  fi

  # Test ar directly with a simple case
  echo ""
  echo "=== Testing ar.exe directly ==="
  which x86_64-w64-mingw32-ar.exe 2>/dev/null || which ar.exe 2>/dev/null || echo "ar not found"

  # Try creating a simple archive
  if [[ -d "${OBJ_DIR}" ]]; then
    FIRST_O=$(ls "${OBJ_DIR}/"*.o 2>/dev/null | head -1)
    if [[ -n "${FIRST_O}" ]]; then
      echo "Testing ar with single file: ${FIRST_O}"
      x86_64-w64-mingw32-ar.exe rc /tmp/test_archive.a "${FIRST_O}" 2>&1 && echo "Single file archive: SUCCESS" || echo "Single file archive: FAILED"

      # Try with first 5 files
      echo ""
      echo "Testing ar with first 5 .o files:"
      FIVE_O=$(ls "${OBJ_DIR}/"*.o 2>/dev/null | head -5 | tr '\n' ' ')
      x86_64-w64-mingw32-ar.exe rc /tmp/test_archive5.a ${FIVE_O} 2>&1 && echo "5 file archive: SUCCESS" || echo "5 file archive: FAILED"

      # Try with all files
      echo ""
      echo "Testing ar with all .o files:"
      ALL_O=$(ls "${OBJ_DIR}/"*.o 2>/dev/null | tr '\n' ' ')
      x86_64-w64-mingw32-ar.exe rc /tmp/test_archive_all.a ${ALL_O} 2>&1 && echo "All files archive: SUCCESS" || echo "All files archive: FAILED with exit code $?"
    fi
  fi

  echo "========================================"
  exit 1
fi

make install
