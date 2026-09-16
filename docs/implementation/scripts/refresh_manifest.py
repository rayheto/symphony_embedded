#!/usr/bin/env python3
"""Re-index and reseal local implementation files; this does not validate semantics."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
files=sorted(p for p in root.rglob('*') if p.is_file() and '__pycache__' not in p.parts and p.name not in ['MANIFEST.sha256','FILE_INDEX.md'])
(root/'FILE_INDEX.md').write_text('# 文件索引\n\n路径相对实施包根目录。\n\n'+'\n'.join(f'- `{p.relative_to(root)}`' for p in files)+'\n- `FILE_INDEX.md`\n- `MANIFEST.sha256`\n',encoding='utf-8')
files.append(root/'FILE_INDEX.md')
(root/'MANIFEST.sha256').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+str(p.relative_to(root))+'\n' for p in sorted(files)),encoding='utf-8')
print(f'Sealed {len(files)} files; now run scripts/verify_pack.py --require-manifest. Product tests remain separate.')
