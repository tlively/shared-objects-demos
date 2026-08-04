#!/usr/bin/env python3
"""Generates Makefile .d dependency files from WAT import directives."""

import argparse
import os
import re
import sys

IMPORT_RE = re.compile(r'\(import\s+"([^"]+)"')

def resolve_import(mod, current_file, project_root="."):
    """Resolves an imported module name to its source file path on disk."""
    if current_file == "runtime.wat" and mod == "runtime":
        return "runtime.c"

    for ext in ('.wat', '.c', '.wasm', ''):
        candidate = os.path.join(project_root, mod + ext)
        if os.path.isfile(candidate):
            rel = os.path.relpath(candidate, project_root)
            return rel
    return None

def find_direct_imports(filepath, project_root="."):
    """Finds all local file imports in a WAT file."""
    abs_path = os.path.join(project_root, filepath)
    if not os.path.exists(abs_path):
        return []
    with open(abs_path, "r", encoding="utf-8") as f:
        content = f.read()
    deps = []
    for m in IMPORT_RE.finditer(content):
        mod = m.group(1)
        resolved = resolve_import(mod, filepath, project_root)
        if resolved and resolved not in deps:
            deps.append(resolved)
    return deps

def find_transitive_deps(filepath, project_root="."):
    """Recursively collects all transitive dependencies in topological order."""
    visited = []
    def visit(path):
        if path in visited:
            return
        if path.endswith('.wat'):
            for dep in find_direct_imports(path, project_root):
                visit(dep)
        if path not in visited:
            visited.append(path)
    visit(filepath)
    return visited

def main():
    parser = argparse.ArgumentParser(description="Generate .d dependency files from WAT imports.")
    parser.add_argument("input", help="Input WAT file")
    parser.add_argument("-o", "--output", required=True, help="Output .d file")
    parser.add_argument("--project-root", default=".", help="Project root directory")
    args = parser.parse_args()

    rel_input = os.path.relpath(args.input, args.project_root)
    if rel_input.startswith("./"):
        rel_input = rel_input[2:]

    direct_deps = find_direct_imports(rel_input, args.project_root)
    transitive_deps = [
        d for d in find_transitive_deps(rel_input, args.project_root)
        if d != rel_input
    ]

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        # Include scripts/gendep.py as a dependency
        gendep_script = "scripts/gendep.py"

        # If this is a demo entrypoint, emit target rules with all transitive dependencies
        parts = rel_input.split(os.sep)
        if len(parts) == 2 and parts[1] == "main.wat":
            demo_name = parts[0]
            wat_deps = [d for d in transitive_deps if d.endswith('.wat')]
            deps_str = f"{gendep_script} {' '.join(transitive_deps)}"
            wat_deps_str = f"{gendep_script} {' '.join(wat_deps)}"
            f.write(f"build/{demo_name}/wat.wasm: {wat_deps_str}\n")
            f.write(f"build/{demo_name}/main.wasm: {deps_str}\n\n")

        # Direct dependencies for the .wat source file
        if direct_deps:
            f.write(f"{rel_input}: {gendep_script} {' '.join(direct_deps)}\n\n")
        else:
            f.write(f"{rel_input}: {gendep_script}\n\n")

        # Dummy rules for all dependencies to prevent make errors if files are removed
        f.write(f"{gendep_script}:\n")
        for d in transitive_deps:
            f.write(f"{d}:\n")

    return 0

if __name__ == "__main__":
    sys.exit(main())
