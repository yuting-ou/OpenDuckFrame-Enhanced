#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$ROOT/.build/r8-development"
mkdir -p "$OUT"
python3 - "$ROOT" "$OUT/fixture-decoder-test.swift" <<'PY'
import pathlib, sys
root=pathlib.Path(sys.argv[1]); source=(root/'Apps/Mac/Capture/WindowCapture.swift').read_text()
fixture=(root/'Modules/VideoEnhancement/Tests/R8FixtureDecoderTests.swift').read_text()
decoder = source[:source.index('@objc(SPSelfWindowCaptureBridge)')]
motion = source[source.index('enum R8FixtureMotionProbe {'):source.index('private final class PoolTicket:')]
pathlib.Path(sys.argv[2]).write_text(decoder + motion + '\n' + fixture)
PY
xcrun swiftc -parse-as-library "$OUT/fixture-decoder-test.swift" -o "$OUT/fixture-decoder-test"
"$OUT/fixture-decoder-test"
