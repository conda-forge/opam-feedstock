#!/usr/bin/env bash
# Create an opam root structure manually without running the opam binary.
# Used for cross-compilation where the target opam binary can't run on the
# build machine (OCaml 5.x GC segfaults under QEMU).
#
# This replicates what `opam init --bare` + `opam switch create conda --empty`
# produce, with paths pointing to $PREFIX for conda relocation.

create_opam_root() {
  local OPAMROOT="$1"
  local PREFIX="$2"
  local SRC_DIR="${3:-${SRC_DIR}}"
  local SHELLSCRIPTS="${SRC_DIR}/opam/src/state/shellscripts"
  local USERNAME
  USERNAME="$(id -un 2>/dev/null || echo user)"
  local GROUPNAME
  GROUPNAME="$(id -gn 2>/dev/null || echo group)"

  # --- Root structure ---
  mkdir -p "${OPAMROOT}"
  mkdir -p "${OPAMROOT}/opam-init/hooks"
  mkdir -p "${OPAMROOT}/repo/default"
  mkdir -p "${OPAMROOT}/conda/.opam-switch/packages"

  # Lock files (empty)
  touch "${OPAMROOT}/lock"
  touch "${OPAMROOT}/config.lock"
  touch "${OPAMROOT}/repo/lock"
  touch "${OPAMROOT}/conda/.opam-switch/lock"

  # --- Root config ---
  cat > "${OPAMROOT}/config" <<'CONFIG_EOF'
opam-version: "2.0"
opam-root-version: "2.2"
repositories: "default"
installed-switches: "conda"
switch: "conda"
download-jobs: 3
eval-variables: [
  [
    sys-ocaml-version
    ["ocamlc" "-vnum"]
    "OCaml version present on your system independently of opam, if any"
  ]
  [
    sys-ocaml-system
    [
      "sh"
      "-c"
      "ocamlc -config 2>/dev/null | tr -d '\\r' | sed -n -e 's/system: //p'"
    ]
    "Target system of the OCaml compiler present on your system"
  ]
  [
    sys-ocaml-arch
    [
      "sh"
      "-c"
      "ocamlc -config 2>/dev/null | tr -d '\\r' | sed -n -e 's/i386/i686/;s/amd64/x86_64/;s/^architecture: //p'"
    ]
    "Target architecture of the OCaml compiler present on your system"
  ]
  [
    sys-ocaml-cc
    [
      "sh"
      "-c"
      "ocamlc -config 2>/dev/null | tr -d '\\r' | sed -n -e 's/^ccomp_type: //p'"
    ]
    "Host C Compiler type of the OCaml compiler present on your system"
  ]
  [
    sys-ocaml-libc
    [
      "sh"
      "-c"
      "ocamlc -config 2>/dev/null | tr -d '\\r' | sed -n -e 's/^os_type: Win32/msvc/p;s/^os_type: .*/libc/p'"
    ]
    "Host C Runtime Library type of the OCaml compiler present on your system"
  ]
]
default-compiler: ["ocaml-base-compiler"]
default-invariant: [
  "ocaml" {>= "4.05.0"}
]
depext: true
depext-run-installs: true
depext-cannot-install: false
swh-fallback: false
CONFIG_EOF

  # --- Repository config ---
  cat > "${OPAMROOT}/repo/repos-config" <<REPOS_EOF
opam-version: "2.0"
repositories: "default" {"file://${OPAMROOT}/repo/default"}
REPOS_EOF

  cat > "${OPAMROOT}/repo/default/repo" <<'REPO_EOF'
opam-version: "2.0"
REPO_EOF

  # --- Switch config ---
  cat > "${OPAMROOT}/conda/.opam-switch/switch-config" <<SWITCH_EOF
opam-version: "2.0"
synopsis: "conda"
opam-root: "${OPAMROOT}"
paths {

}
variables {
  user: "${USERNAME}"
  group: "${GROUPNAME}"
}
SWITCH_EOF

  # --- Switch environment ---
  cat > "${OPAMROOT}/conda/.opam-switch/environment" <<ENV_EOF
OPAM_SWITCH_PREFIX	=	${OPAMROOT}/conda	:	target	Prefix\ of\ the\ current\ opam\ switch
MANPATH	=:	${OPAMROOT}/conda/man	:	host	Current\ opam\ switch\ man\ dir
PATH	=+=	${OPAMROOT}/conda/bin	:	target	Binary\ dir\ for\ opam\ switch\ conda
ENV_EOF

  # --- Shell init scripts (source completions and variables) ---
  cat > "${OPAMROOT}/opam-init/init.sh" <<INIT_EOF
if [ -t 0 ]; then
  test -r '${OPAMROOT}/opam-init/complete.sh' && . '${OPAMROOT}/opam-init/complete.sh' > /dev/null 2> /dev/null || true

  test -r '${OPAMROOT}/opam-init/env_hook.sh' && . '${OPAMROOT}/opam-init/env_hook.sh' > /dev/null 2> /dev/null || true
fi

test -r '${OPAMROOT}/opam-init/variables.sh' && . '${OPAMROOT}/opam-init/variables.sh' > /dev/null 2> /dev/null || true
INIT_EOF

  cat > "${OPAMROOT}/opam-init/init.zsh" <<INIT_EOF
if [[ -o interactive ]]; then
  [[ ! -r '${OPAMROOT}/opam-init/complete.zsh' ]] || source '${OPAMROOT}/opam-init/complete.zsh' > /dev/null 2> /dev/null

  [[ ! -r '${OPAMROOT}/opam-init/env_hook.zsh' ]] || source '${OPAMROOT}/opam-init/env_hook.zsh' > /dev/null 2> /dev/null
fi

[[ ! -r '${OPAMROOT}/opam-init/variables.sh' ]] || source '${OPAMROOT}/opam-init/variables.sh' > /dev/null 2> /dev/null
INIT_EOF

  cat > "${OPAMROOT}/opam-init/init.csh" <<INIT_EOF
if ( \$?prompt ) then
  if ( -f '${OPAMROOT}/opam-init/env_hook.csh' ) source '${OPAMROOT}/opam-init/env_hook.csh' >& /dev/null
endif

if ( -f '${OPAMROOT}/opam-init/variables.csh' ) source '${OPAMROOT}/opam-init/variables.csh' >& /dev/null
INIT_EOF

  cat > "${OPAMROOT}/opam-init/init.fish" <<INIT_EOF
if status is-interactive
  test -r '${OPAMROOT}/opam-init/env_hook.fish' && source '${OPAMROOT}/opam-init/env_hook.fish' > /dev/null 2> /dev/null; or true
end

test -r '${OPAMROOT}/opam-init/variables.fish' && source '${OPAMROOT}/opam-init/variables.fish' > /dev/null 2> /dev/null; or true
INIT_EOF

  cat > "${OPAMROOT}/opam-init/init.ps1" <<INIT_EOF
if Test-Path "${OPAMROOT}/opam-init/variables.ps1" { . "${OPAMROOT}/opam-init/variables.ps1" *> \$null }
INIT_EOF

  cat > "${OPAMROOT}/opam-init/init.cmd" <<INIT_EOF
if exist "${OPAMROOT}/opam-init/variables.cmd" call "${OPAMROOT}/opam-init/variables.cmd" >NUL 2>NUL
INIT_EOF

  # --- Shell variables scripts (set OPAM_SWITCH_PREFIX, MANPATH, PATH) ---
  cat > "${OPAMROOT}/opam-init/variables.sh" <<VARS_EOF
test -z "\${OPAM_SWITCH_PREFIX:+x}" || return
# Prefix of the current opam switch
OPAM_SWITCH_PREFIX='${OPAMROOT}/conda'; export OPAM_SWITCH_PREFIX;
# Current opam switch man dir
MANPATH="\$MANPATH":'${OPAMROOT}/conda/man'; export MANPATH;
# Binary dir for opam switch conda
PATH='${OPAMROOT}/conda/bin':"\$PATH"; export PATH;
VARS_EOF

  cat > "${OPAMROOT}/opam-init/variables.csh" <<VARS_EOF
if ( \${?OPAM_SWITCH_PREFIX} ) then
  if ( "\$OPAM_SWITCH_PREFIX" != "") exit
endif
# Prefix of the current opam switch
setenv OPAM_SWITCH_PREFIX '${OPAMROOT}/conda'
# Current opam switch man dir
if ( \${?MANPATH} ) then
  setenv MANPATH "\${MANPATH}":${OPAMROOT}/conda/man
else
  setenv MANPATH :${OPAMROOT}/conda/man
endif
# Binary dir for opam switch conda
setenv PATH ${OPAMROOT}/conda/bin:"\${PATH}"
VARS_EOF

  cat > "${OPAMROOT}/opam-init/variables.fish" <<VARS_EOF
test -z "\$OPAM_SWITCH_PREFIX"; or return
# Prefix of the current opam switch
set -gx OPAM_SWITCH_PREFIX '${OPAMROOT}/conda';
# Current opam switch man dir
if [ (count \$MANPATH) -gt 0 ]; set -gx MANPATH \$MANPATH '${OPAMROOT}/conda/man'; end;
# Binary dir for opam switch conda
set -gx PATH '${OPAMROOT}/conda/bin' \$PATH;
VARS_EOF

  cat > "${OPAMROOT}/opam-init/variables.ps1" <<VARS_EOF
if (\$env:OPAM_SWITCH_PREFIX -ne \$null -and \$env:OPAM_SWITCH_PREFIX -ne '') { return }
# Prefix of the current opam switch
\$env:OPAM_SWITCH_PREFIX='${OPAMROOT}/conda'
# Current opam switch man dir
\$env:MANPATH="\$env:MANPATH" + ':${OPAMROOT}/conda/man'
# Binary dir for opam switch conda
\$env:PATH='${OPAMROOT}/conda/bin' + [IO.Path]::PathSeparator + \$env:PATH
VARS_EOF

  cat > "${OPAMROOT}/opam-init/variables.cmd" <<VARS_EOF
if defined OPAM_SWITCH_PREFIX if "%OPAM_SWITCH_PREFIX%" neq "" goto :EOF
:: Prefix of the current opam switch
set "OPAM_SWITCH_PREFIX=${OPAMROOT}/conda"
:: Current opam switch man dir
set "MANPATH=%MANPATH%:${OPAMROOT}/conda/man"
:: Binary dir for opam switch conda
set "PATH=${OPAMROOT}/conda/bin;%PATH%"
VARS_EOF

  # --- Shell completion scripts and sandbox (copy from opam source tree) ---
  cp "${SHELLSCRIPTS}/complete.sh" "${OPAMROOT}/opam-init/complete.sh"
  cp "${SHELLSCRIPTS}/complete.zsh" "${OPAMROOT}/opam-init/complete.zsh"
  cp "${SHELLSCRIPTS}/sandbox_exec.sh" "${OPAMROOT}/opam-init/hooks/sandbox.sh"
  chmod +x "${OPAMROOT}/opam-init/hooks/sandbox.sh"

  # Compute sandbox hash
  md5sum "${OPAMROOT}/opam-init/hooks/sandbox.sh" | awk '{print "md5=" $1}' > "${OPAMROOT}/opam-init/hooks/sandbox.sh.hash"

  echo "opam root manually initialized at ${OPAMROOT}"
}
