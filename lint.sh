#!/bin/bash
# Format (SwiftFormat) + lint (SwiftLint) the Tally sources.
#   ./lint.sh          format in place, then lint
#   ./lint.sh --check  verify formatting without modifying (for CI), then lint
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${1:-}" == "--check" ]]; then
    echo "==> SwiftFormat (lint mode)"
    swiftformat . --lint
else
    echo "==> SwiftFormat (applying)"
    swiftformat .
fi

echo "==> SwiftLint"
swiftlint lint --quiet
echo "==> done"
