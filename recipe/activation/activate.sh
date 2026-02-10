#!/bin/bash
# Conda activation script for opam
# Sets env vars so opam uses a conda-local root and switch.
# The opam root is pre-initialized at package build/install time.

# Save any pre-existing opam env vars for deactivation
if [ -n "${OPAMROOT:-}" ]; then
    export _CONDA_OPAM_SAVED_OPAMROOT="$OPAMROOT"
fi
if [ -n "${OPAMSWITCH:-}" ]; then
    export _CONDA_OPAM_SAVED_OPAMSWITCH="$OPAMSWITCH"
fi
if [ -n "${OPAMNOENVNOTICE:-}" ]; then
    export _CONDA_OPAM_SAVED_OPAMNOENVNOTICE="$OPAMNOENVNOTICE"
fi

# Point opam at this conda environment
export OPAMROOT="$CONDA_PREFIX/share/opam"
export OPAMSWITCH="conda"

# Suppress "Run eval $(opam env)" messages — conda manages the environment
export OPAMNOENVNOTICE=true
