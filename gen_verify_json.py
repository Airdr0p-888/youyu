#!/usr/bin/env python3
"""
Generate standard-input.json for BscScan contract verification.
Includes SimpleToken.sol and all OpenZeppelin dependencies.
"""
import json, os, re

def read_file(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()

def find_imports(source, base_dir):
    """Find all import paths in a Solidity source file."""
    imports = []
    for line in source.splitlines():
        m = re.match(r'\s*import\s+["\']([^"\']+)["\']', line)
        if m:
            imports.append(m.group(1))
    return imports

def resolve_import(import_path, base_dir):
    """Resolve an import path to a file path."""
    if import_path.startswith('@openzeppelin/contracts/'):
        # Resolve from node_modules
        nm = os.path.join(base_dir, 'node_modules')
        return os.path.join(nm, import_path)
    elif import_path.startswith('./') or import_path.startswith('../'):
        return os.path.normpath(os.path.join(base_dir, import_path))
    else:
        return os.path.join(base_dir, import_path)

def collect_sources(file_path, base_dir, sources, visited):
    """Recursively collect all source files."""
    abs_path = os.path.abspath(file_path)
    if abs_path in visited:
        return
    visited.add(abs_path)
    
    # Use relative path as key (for BscScan)
    rel_path = os.path.relpath(abs_path, base_dir)
    if rel_path not in sources:
        sources[rel_path] = {'content': read_file(abs_path)}
    
    # Find and resolve imports
    source = sources[rel_path]['content']
    for imp in find_imports(source, base_dir):
        try:
            resolved = resolve_import(imp, os.path.dirname(abs_path))
            collect_sources(resolved, base_dir, sources, visited)
        except Exception as e:
            print(f"Warning: Could not resolve import {imp}: {e}")

# Base directory
base_dir = 'C:/Users/Administrator/WorkBuddy/2026-06-07-22-33-14/squid-launch'

# Collect all sources
sources = {}
visited = set()
main_file = os.path.join(base_dir, 'contracts-simple/SimpleToken.sol')
collect_sources(main_file, base_dir, sources, visited)

# Build standard-input.json
standard_input = {
    'language': 'Solidity',
    'sources': sources,
    'settings': {
        'optimizer': {
            'enabled': True,
            'runs': 200
        },
        'outputSelection': {
            '*': {
                '*': ['*']
            }
        }
    }
}

# Write output
output_path = os.path.join(base_dir, 'standard-input.json')
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(standard_input, f, indent=2, ensure_ascii=False)

print(f"✅ Generated {output_path}")
print(f"   Total source files: {len(sources)}")
for name in sorted(sources.keys()):
    print(f"   - {name}")
