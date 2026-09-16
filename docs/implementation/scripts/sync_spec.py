#!/usr/bin/env python3
"""Rebuild the combined reading copy; never rewrite the upstream snapshot."""
from pathlib import Path
r=Path(__file__).resolve().parents[1]
(r/'SPEC.md').write_bytes((r/'upstream/SPEC.original.md').read_bytes()+b'\n\n---\n\n'+(r/'docs/SPEC_EXTENSION.md').read_bytes())
print('SPEC.md synchronized. Re-run package validation and renew MANIFEST.sha256 before redistribution.')
