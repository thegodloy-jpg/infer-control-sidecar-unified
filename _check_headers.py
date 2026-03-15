"""Find files with comment headers that lack docstrings."""
import os

SKIP = {'__pycache__', 'logs', 'outputs', '.git', 'templates', 'benchmark'}

for dp, ds, fs in os.walk('wings-control'):
    ds[:] = [d for d in ds if d not in SKIP]
    for f in sorted(fs):
        if not f.endswith('.py'):
            continue
        fp = os.path.join(dp, f)
        lines = open(fp, encoding='utf-8').readlines()
        if not lines:
            continue
        first = lines[0].strip()
        if not (first.startswith('# ==') or first.startswith('# --')):
            continue
        # Find where comment block ends
        has_docstring = False
        for line in lines:
            stripped = line.strip()
            if stripped.startswith('#') or stripped == '':
                continue
            if stripped.startswith('"""') or stripped.startswith("'''"):
                has_docstring = True
            break
        status = "HAS_DOCSTRING" if has_docstring else "NEEDS_DOCSTRING"
        print(f'{status}: {fp}')
