#!/bin/bash
# Conda deactivation script for opam
# Restores pre-existing opam env vars or unsets them.

# Restore or unset OPAMROOT
if [ -n "${_CONDA_OPAM_SAVED_OPAMROOT:-}" ]; then
    export OPAMROOT="$_CONDA_OPAM_SAVED_OPAMROOT"
    unset _CONDA_OPAM_SAVED_OPAMROOT
else
    unset OPAMROOT
fi

# Restore or unset OPAMSWITCH
if [ -n "${_CONDA_OPAM_SAVED_OPAMSWITCH:-}" ]; then
    export OPAMSWITCH="$_CONDA_OPAM_SAVED_OPAMSWITCH"
    unset _CONDA_OPAM_SAVED_OPAMSWITCH
else
    unset OPAMSWITCH
fi

# Restore or unset OPAMNOENVNOTICE
if [ -n "${_CONDA_OPAM_SAVED_OPAMNOENVNOTICE:-}" ]; then
    export OPAMNOENVNOTICE="$_CONDA_OPAM_SAVED_OPAMNOENVNOTICE"
    unset _CONDA_OPAM_SAVED_OPAMNOENVNOTICE
else
    unset OPAMNOENVNOTICE
fi
