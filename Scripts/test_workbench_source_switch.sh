#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT" "$TEST_DIR/source.swift" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
source = (root / 'Apps/Mac/UI/Enhancement/EnhancementWorkbench.swift').read_text()

def extract(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f'Unbalanced method: {marker}')

methods = {
    '// ACTUAL_SOURCE_KIND_CHANGED': extract('    @objc private func sourceKindChanged() {'),
    '// ACTUAL_STOP_IMMEDIATELY': extract('    private func stopImmediately(stopPipeline: Bool = true) {'),
    '// ACTUAL_REFRESH_ACTIONS': extract('    private func refreshActions() {'),
}
harness = (root / 'Modules/VideoEnhancement/Tests/WorkbenchSourceSwitchTests.swift').read_text()
for placeholder, method in methods.items():
    harness = harness.replace(placeholder, method)
pathlib.Path(sys.argv[2]).write_text(harness)
PY
xcrun swiftc -parse-as-library "$TEST_DIR/source.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
