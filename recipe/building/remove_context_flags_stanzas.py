#!/usr/bin/env python3
"""
Remove context_flags-related stanzas from mccs dune files.

For macOS cross-compilation, we pre-generate the sexp files that context_flags.exe
would produce, then remove the dune rules that would build and run context_flags.exe
(which would fail because it's an arm64 binary on x86_64 build machine).
"""
import os


def remove_context_flags_stanzas(dune_path):
    """Remove executable and rule stanzas related to context_flags from dune file."""
    if not os.path.exists(dune_path):
        print(f"  Skipping (not found): {dune_path}")
        return

    with open(dune_path, 'r') as f:
        content = f.read()

    # Parse S-expressions and filter out context_flags-related ones
    result = []
    i = 0
    removed_count = 0

    while i < len(content):
        # Preserve whitespace
        if content[i] in ' \t\n':
            result.append(content[i])
            i += 1
            continue

        # Preserve comments
        if content[i] == ';':
            while i < len(content) and content[i] != '\n':
                result.append(content[i])
                i += 1
            continue

        # Parse S-expression
        if content[i] == '(':
            depth = 1
            start = i
            i += 1
            while i < len(content) and depth > 0:
                if content[i] == '(':
                    depth += 1
                elif content[i] == ')':
                    depth -= 1
                i += 1
            sexp = content[start:i]

            # Check if this is a context_flags related stanza or generates sexp files
            # we pre-generated (clibs.sexp, cxxflags.sexp, flags.sexp, cflags.sexp)
            # Use flexible matching - look for the filename anywhere in the stanza
            sexp_lower = sexp.lower()
            should_remove = (
                'context_flags' in sexp_lower or
                'clibs.sexp' in sexp_lower or
                'cxxflags.sexp' in sexp_lower or
                'cflags.sexp' in sexp_lower or
                # Be careful with flags.sexp - it's generic, only match if it's a target
                ('flags.sexp' in sexp_lower and '(target' in sexp_lower)
            )
            if should_remove:
                # Replace with comment showing what was removed
                first_line = sexp.split('\n')[0][:60]
                result.append(f'; DISABLED for cross-compilation: {first_line}...\n')
                removed_count += 1
            else:
                result.append(sexp)
        else:
            result.append(content[i])
            i += 1

    with open(dune_path, 'w') as f:
        f.write(''.join(result))

    print(f"  Rewrote: {dune_path} (removed {removed_count} stanzas)")


def main():
    src_dir = os.environ.get('SRC_DIR', '.')
    opam_dir = f"{src_dir}/opam"
    cwd = os.getcwd()

    # Check both possible locations (with and without opam subdirectory)
    # Also check relative to cwd (cross-compile.sh runs from ${SRC_DIR}/opam)
    if os.path.isdir(f"{opam_dir}/src_ext"):
        base = opam_dir
    elif os.path.isdir(f"{cwd}/src_ext"):
        base = cwd
    else:
        base = src_dir

    print(f"Removing context_flags stanzas from mccs dune files...")
    print(f"  SRC_DIR={src_dir}, cwd={cwd}, base={base}")
    remove_context_flags_stanzas(f"{base}/src_ext/mccs/src/dune")
    remove_context_flags_stanzas(f"{base}/src_ext/mccs/src/glpk/dune")


if __name__ == '__main__':
    main()
