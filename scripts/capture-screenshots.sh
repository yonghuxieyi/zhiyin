#!/usr/bin/env bash
# Capture App Store screenshot source PNGs from iOS simulators.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="$ROOT/Zhiyin.xcodeproj"
SCHEME="Zhiyin"
DERIVED_DATA_PATH="$ROOT/build/DerivedData-Screenshots"
RESULTS_DIR="$ROOT/build/screenshot-results"
OUTPUT_ROOT="$ROOT/screenshots"

DEVICE_NAME="${DEVICE_NAME:-iPhone 17 Pro Max}"
OS_VERSION="${OS_VERSION:-26.4}"
LOCALE="${LOCALE:-en-US}"
LANGUAGE="${LANGUAGE:-en}"
REGION="${REGION:-US}"

command -v jq >/dev/null || { echo "error: jq is required to rename exported screenshot attachments." >&2; exit 1; }

mkdir -p "$RESULTS_DIR" "$OUTPUT_ROOT/$LOCALE"
rm -rf "$RESULTS_DIR/$LOCALE.xcresult"
rm -f "$OUTPUT_ROOT/$LOCALE"/*.png "$OUTPUT_ROOT/$LOCALE/manifest.json"

if [[ ! -d "$PROJECT_PATH" ]]; then
    if command -v xcodegen >/dev/null; then
        echo "==> Project not found; generating with xcodegen"
        (cd "$ROOT" && xcodegen generate)
    else
        echo "error: $PROJECT_PATH missing; run xcodegen generate first" >&2
        exit 1
    fi
fi

echo "==> Capturing screenshots on $DEVICE_NAME (iOS $OS_VERSION), locale $LOCALE"
ZHIYIN_SCREENSHOT_DIR="$OUTPUT_ROOT/$LOCALE" xcodebuild test \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$DEVICE_NAME,OS=$OS_VERSION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -only-testing:RunseUITests/RunseScreenshotUITests/testCaptureAppStoreScreenshots \
    -resultBundlePath "$RESULTS_DIR/$LOCALE.xcresult" \
    -testLanguage "$LANGUAGE" \
    -testRegion "$REGION"

xcrun xcresulttool export attachments \
    --path "$RESULTS_DIR/$LOCALE.xcresult" \
    --output-path "$OUTPUT_ROOT/$LOCALE"

jq -r '.[] .attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_0_.*$"; ".png"))] | @tsv' "$OUTPUT_ROOT/$LOCALE/manifest.json" |
    while IFS=$'\t' read -r src dest; do
        mv "$OUTPUT_ROOT/$LOCALE/$src" "$OUTPUT_ROOT/$LOCALE/$dest"
    done

echo "==> Screenshots written to $OUTPUT_ROOT/$LOCALE"
