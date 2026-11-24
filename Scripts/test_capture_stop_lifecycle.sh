#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$ROOT" "$TEST_DIR/source.swift" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
source = (root / 'Apps/Mac/Capture/WindowCapture.swift').read_text()
marker = '    func stream(_ stream: SCStream, didStopWithError error: Error) {'
start = source.index(marker)
brace = source.index('{', start)
depth = 0
end = None
for index in range(brace, len(source)):
    if source[index] == '{':
        depth += 1
    elif source[index] == '}':
        depth -= 1
        if depth == 0:
            end = index + 1
            break
if end is None:
    raise SystemExit('Unbalanced stream-stop delegate')
method = source[start:end]
harness = (root / 'Modules/VideoEnhancement/Tests/WindowCaptureStopLifecycleTests.swift').read_text()
pathlib.Path(sys.argv[2]).write_text(harness.replace('// ACTUAL_STREAM_STOP_DELEGATE', method))
PY
xcrun swiftc -parse-as-library "$ROOT/Apps/Mac/Capture/ContentFrameGate.swift" "$TEST_DIR/source.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
