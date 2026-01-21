#!/usr/bin/env python3
"""Remove menhir-invoking stanzas from dune files.

This script removes top-level stanzas that invoke menhir, including:
- (menhir ...) stanzas - direct parser generation
- (rule ...) stanzas that contain 'menhir' - error message generation, etc.

Parser files should be pre-generated before calling this script.

Usage:
    python remove_menhir_stanzas.py <dune_file>
"""
import re
import sys


def remove_menhir_stanzas(content: str) -> str:
    """Remove top-level stanzas that invoke menhir.

    Removes:
    - (menhir ...) stanzas
    - (rule ...) stanzas that contain 'menhir' anywhere inside
    """
    lines = content.split('\n')
    result = []

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Check if this is a top-level stanza start (starts at column 0 with '(')
        if line.startswith('('):
            # Collect the entire stanza to check its contents
            stanza_lines = [line]
            depth = line.count('(') - line.count(')')
            j = i + 1

            while depth > 0 and j < len(lines):
                stanza_lines.append(lines[j])
                depth += lines[j].count('(') - lines[j].count(')')
                j += 1

            stanza_content = '\n'.join(stanza_lines)

            # Check if this stanza invokes menhir
            should_remove = False
            reason = ""

            # Direct menhir stanza
            if stripped.startswith('(menhir'):
                should_remove = True
                reason = "menhir stanza"
            # Rule that runs menhir
            elif stripped.startswith('(rule') and re.search(r'\bmenhir\b', stanza_content):
                should_remove = True
                reason = "rule invoking menhir"

            if should_remove:
                # Comment out the entire stanza
                for sl in stanza_lines:
                    result.append(f"; REMOVED ({reason}): {sl}")
                i = j
                continue
            else:
                # Keep the stanza
                result.extend(stanza_lines)
                i = j
                continue

        result.append(line)
        i += 1

    return '\n'.join(result)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <dune_file>", file=sys.stderr)
        return 1

    dune_file = sys.argv[1]

    try:
        with open(dune_file, 'r') as f:
            content = f.read()
    except FileNotFoundError:
        print(f"Error: File not found: {dune_file}", file=sys.stderr)
        return 1
    except IOError as e:
        print(f"Error reading {dune_file}: {e}", file=sys.stderr)
        return 1

    patched = remove_menhir_stanzas(content)

    try:
        with open(dune_file, 'w') as f:
            f.write(patched)
    except IOError as e:
        print(f"Error writing {dune_file}: {e}", file=sys.stderr)
        return 1

    # Report what was changed
    patched_lines = patched.split('\n')
    removed_count = sum(1 for l in patched_lines if l.startswith('; REMOVED'))
    print(f"  Processed {dune_file}: {removed_count} lines commented out")

    return 0


if __name__ == '__main__':
    sys.exit(main())
