#!/bin/zsh
set -euo pipefail

repo_root=${0:A:h:h:h}
reporter="$repo_root/scripts/report-board-chrome-diagnostics.py"
fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT

cat > "$fixture_root/stable.ndjson" <<'EOF'
{"diagnosticKind":"interaction-frame","topMenu":{"x":16,"width":100},"topToolbar":{"x":20,"width":50},"bottomLeft":{"x":16,"y":80,"width":20},"viewport":{"width":100,"height":100}}
{"diagnosticKind":"interaction-frame","topMenu":{"x":16,"width":100},"topToolbar":{"x":20,"width":50},"bottomLeft":{"x":16,"y":80,"width":20},"viewport":{"width":100,"height":100}}
EOF

cat > "$fixture_root/moved.ndjson" <<'EOF'
{"diagnosticKind":"interaction-frame","topMenu":{"x":16,"width":100},"topToolbar":{"x":20,"width":50},"bottomLeft":{"x":16,"y":80,"width":20},"viewport":{"width":100,"height":100}}
{"diagnosticKind":"interaction-frame","topMenu":{"x":16,"width":100},"topToolbar":{"x":30,"width":50},"bottomLeft":{"x":16,"y":80,"width":20},"viewport":{"width":100,"height":100}}
EOF

python3 -B "$reporter" "$fixture_root/stable.ndjson" >/dev/null
if python3 -B "$reporter" "$fixture_root/moved.ndjson" >/dev/null; then
    echo "Expected moved Board chrome to fail the diagnostic gate." >&2
    exit 1
fi

echo "Board chrome diagnostic report contracts passed."
