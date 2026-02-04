@echo off
REM Conda activation script for opam (Windows)
REM Sets env vars so opam uses a conda-local root and switch.
REM The opam root is pre-initialized at package build/install time.

REM Save pre-existing opam env vars
if defined OPAMROOT set "_CONDA_OPAM_SAVED_OPAMROOT=%OPAMROOT%"
if defined OPAMSWITCH set "_CONDA_OPAM_SAVED_OPAMSWITCH=%OPAMSWITCH%"
if defined OPAMNOENVNOTICE set "_CONDA_OPAM_SAVED_OPAMNOENVNOTICE=%OPAMNOENVNOTICE%"

REM Point opam at this conda environment
REM On Windows, conda packages install to Library\share, not share
set "OPAMROOT=%CONDA_PREFIX%\Library\share\opam"
set "OPAMSWITCH=conda"
set "OPAMNOENVNOTICE=true"
