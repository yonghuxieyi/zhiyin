#!/usr/bin/env bash
# Build the Zhiyin Release iOS app bundle, optionally installing it onto a connected device.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_PATH="$ROOT/Zhiyin.xcodeproj"
SCHEME="Zhiyin"
CONFIGURATION="Release"
DERIVED_DATA_PATH="$ROOT/build/DerivedData"
SOURCE_PACKAGES_PATH="$ROOT/build/SourcePackages"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}-iphoneos/Zhiyin.app"
LOCAL_XCCONFIG_PATH="$ROOT/Config/Local.xcconfig"

DEVICE_ID=""
INSTALL_APP=0
ALLOW_PROVISIONING_UPDATES=1
CLEAN_BUILD=0
TEAM_ID="${DEVELOPMENT_TEAM:-}"

read_xcconfig_value() {
    local key="$1"
    local file="$2"

    [[ -f "$file" ]] || return 1

    awk -F '=' -v key="$key" '
        $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
            value = $2
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            gsub(/"/, "", value)
            print value
            exit
        }
    ' "$file"
}

usage() {
    cat <<'EOF'
Usage: ./scripts/build-release.sh [options]

Build the Zhiyin Release app bundle for iPhoneOS.

Options:
  --xcconfig <path>              Override Config/Local.xcconfig.
  --team <team-id>               Override DEVELOPMENT_TEAM for signing.
  --device <device-id>           Build for a specific connected device.
  --install                      Install the built .app onto the device from --device.
  --no-provisioning-updates      Do not pass -allowProvisioningUpdates to xcodebuild.
  --clean                        Remove repo-local DerivedData and SourcePackages first.
  -h, --help                     Show this help text.

Examples:
  ./scripts/build-release.sh
  ./scripts/build-release.sh --device <device-id> --install
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --xcconfig)
            LOCAL_XCCONFIG_PATH="${2:-}"
            shift 2
            ;;
        --team)
            TEAM_ID="${2:-}"
            shift 2
            ;;
        --device)
            DEVICE_ID="${2:-}"
            shift 2
            ;;
        --install)
            INSTALL_APP=1
            shift
            ;;
        --no-provisioning-updates)
            ALLOW_PROVISIONING_UPDATES=0
            shift
            ;;
        --clean)
            CLEAN_BUILD=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -f "$LOCAL_XCCONFIG_PATH" && -z "$TEAM_ID" ]]; then
    TEAM_ID="$(read_xcconfig_value "DEVELOPMENT_TEAM" "$LOCAL_XCCONFIG_PATH" || true)"
fi

if [[ -z "$TEAM_ID" ]]; then
    echo "note: DEVELOPMENT_TEAM not found in Config/Local.xcconfig or environment; Xcode will use the project's current signing configuration."
fi

if [[ "$INSTALL_APP" -eq 1 && -z "$DEVICE_ID" ]]; then
    echo "error: --install requires --device <device-id>." >&2
    exit 1
fi

if [[ "$CLEAN_BUILD" -eq 1 ]]; then
    rm -rf "$DERIVED_DATA_PATH" "$SOURCE_PACKAGES_PATH"
fi

mkdir -p "$ROOT/build"

if [[ ! -d "$PROJECT_PATH" ]]; then
    if command -v xcodegen >/dev/null; then
        echo "==> Project not found; generating with xcodegen"
        (cd "$ROOT" && xcodegen generate)
    else
        echo "error: $PROJECT_PATH missing; run xcodegen generate first" >&2
        exit 1
    fi
fi


DESTINATION="generic/platform=iOS"
if [[ -n "$DEVICE_ID" ]]; then
    DESTINATION="id=$DEVICE_ID"
fi

XCODEBUILD_ARGS=(
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH"
    build
)

if [[ -f "$LOCAL_XCCONFIG_PATH" ]]; then
    XCODEBUILD_ARGS=(-xcconfig "$LOCAL_XCCONFIG_PATH" "${XCODEBUILD_ARGS[@]}")
fi

if [[ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
    XCODEBUILD_ARGS=(-allowProvisioningUpdates "${XCODEBUILD_ARGS[@]}")
fi

if [[ -n "$TEAM_ID" ]]; then
    XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$TEAM_ID")
fi

echo "==> Building $SCHEME ($CONFIGURATION)"
echo "==> Destination: $DESTINATION"
if [[ -f "$LOCAL_XCCONFIG_PATH" ]]; then
    echo "==> Local xcconfig: $LOCAL_XCCONFIG_PATH"
fi
if [[ -n "$TEAM_ID" ]]; then
    echo "==> Signing team: $TEAM_ID"
fi
xcodebuild "${XCODEBUILD_ARGS[@]}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: expected app bundle missing at $APP_PATH" >&2
    exit 1
fi

echo "==> Release app bundle: $APP_PATH"

if [[ "$INSTALL_APP" -eq 1 ]]; then
    echo "==> Installing app onto device $DEVICE_ID"
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
fi
