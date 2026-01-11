#!/usr/bin/env bash
# OCaml 5.3.0 build 0 specific fixes for Unix (Linux and macOS)
#
# Issue: OCaml 5.3.0_0 has hardcoded placeholder paths (~264 chars) from the
#        conda build environment baked into Makefile.config. These cause
#        linker command corruption when OCaml constructs commands.
#
# This file should be sourced from build.sh when building on Unix with
# OCaml 5.3.0_0. These fixes should be resolved in later OCaml builds.
#
# Required variables (must be set before sourcing):
#   OCAMLLIB, BUILD_PREFIX, BUILD_INC, BUILD_LIB
#
# Usage: source "${RECIPE_DIR}/ocaml-5.3.0_0-fixes/unix.sh"

set -euo pipefail

echo "=== Applying OCaml 5.3.0_0 Unix fixes ==="

# -----------------------------------------------------------------------------
# Fix: Placeholder paths in Makefile.config
# -----------------------------------------------------------------------------
# Problem: OCaml's Makefile.config contains paths like:
#   /home/conda/feedstock_root/build_artifacts/ocaml_1234567890/host_env_placehold.../lib
# These ~264 char placeholder paths cause command line corruption.
#
# Solution: Replace all placeholder paths with actual BUILD_PREFIX paths.
# -----------------------------------------------------------------------------

if [[ -f "${OCAMLLIB}/Makefile.config" ]]; then
  # Replace placeholder include paths
  sed -i -E "s#( )[^ ,]*_env[^ ]*inc#\1${BUILD_INC}#g" "${OCAMLLIB}/Makefile.config"

  # Replace placeholder library paths (handles -L, space, and comma prefixes)
  sed -i -E "s#(-L| |,)[^ ,]*_env[^ ]*lib#\1${BUILD_LIB}#g" "${OCAMLLIB}/Makefile.config"

  # Remove debug-prefix-map flags with placeholder paths (they break builds)
  sed -i -E "s#-fdebug-prefix-map=[^ ]*_env[^ ]*##g" "${OCAMLLIB}/Makefile.config"
  sed -i -E "s#-fdebug-prefix-map=[^ ]*_ocaml[^ ]*##g" "${OCAMLLIB}/Makefile.config"

  # Replace any remaining placeholder paths in variable assignments
  sed -i -E "s#(=\s*)[^ ]*_env[^ ]*#\1${BUILD_PREFIX}#g" "${OCAMLLIB}/Makefile.config"

  echo "  Makefile.config: Placeholder paths replaced"
else
  echo "  WARNING: ${OCAMLLIB}/Makefile.config not found"
fi

echo "=== OCaml 5.3.0_0 Unix fixes applied ==="
