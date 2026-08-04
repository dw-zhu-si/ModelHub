#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
BUILD_CONFIGURATION=${1:-release}
APP_NAME=ModelHub
WIDGET_NAME=ModelHubWidget
ACP_NAME=ModelHubACP
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_ROOT}/packaging/Info.plist")
DIST_APP_DIR="${PROJECT_ROOT}/dist/${APP_NAME}.app"
ZIP_PATH="${PROJECT_ROOT}/dist/${APP_NAME}-${APP_VERSION}-macos-universal.zip"
SIGNING_IDENTITY=${MODELHUB_SIGNING_IDENTITY:--}
STAGING_ROOT=$(mktemp -d /private/tmp/modelhub-package.XXXXXX)
APP_DIR="${STAGING_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PLUGINS_DIR="${CONTENTS_DIR}/PlugIns"
WIDGET_APP_DIR="${PLUGINS_DIR}/${WIDGET_NAME}.appex"
WIDGET_CONTENTS_DIR="${WIDGET_APP_DIR}/Contents"
WIDGET_MACOS_DIR="${WIDGET_CONTENTS_DIR}/MacOS"
WIDGET_RESOURCES_DIR="${WIDGET_CONTENTS_DIR}/Resources"
ICONSET_DIR="${PROJECT_ROOT}/.build/ModelHub.iconset"
ICON_SOURCE="${PROJECT_ROOT}/.build/ModelHub-1024.png"
PACKAGE_SCRATCH_DIR="${PROJECT_ROOT}/.build/package-swiftpm"
PACKAGE_CLANG_CACHE_DIR="${PROJECT_ROOT}/.build/package-clang-module-cache"
PACKAGE_SWIFTPM_CACHE_DIR="${PROJECT_ROOT}/.build/package-swiftpm-cache"

remove_item() {
    /usr/bin/swift -e 'import Foundation; let path = CommandLine.arguments[1]; if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }' "$1"
}

cleanup() {
    remove_item "${STAGING_ROOT}"
}
trap cleanup EXIT

cd "${PROJECT_ROOT}"
remove_item "${PACKAGE_CLANG_CACHE_DIR}"
remove_item "${PACKAGE_SWIFTPM_CACHE_DIR}"
remove_item "${PACKAGE_SCRATCH_DIR}"
mkdir -p "${PACKAGE_CLANG_CACHE_DIR}" "${PACKAGE_SWIFTPM_CACHE_DIR}" dist

for triple in arm64-apple-macosx x86_64-apple-macosx; do
    env CLANG_MODULE_CACHE_PATH="${PACKAGE_CLANG_CACHE_DIR}" \
        SWIFTPM_CACHE_PATH="${PACKAGE_SWIFTPM_CACHE_DIR}" \
        swift build -c "${BUILD_CONFIGURATION}" \
            --triple "${triple}" \
            --scratch-path "${PACKAGE_SCRATCH_DIR}"
done

remove_item "${ICONSET_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${ICONSET_DIR}" "${WIDGET_MACOS_DIR}" "${WIDGET_RESOURCES_DIR}"

lipo -create \
    "${PACKAGE_SCRATCH_DIR}/arm64-apple-macosx/${BUILD_CONFIGURATION}/ModelHub" \
    "${PACKAGE_SCRATCH_DIR}/x86_64-apple-macosx/${BUILD_CONFIGURATION}/ModelHub" \
    -output "${MACOS_DIR}/ModelHub"
lipo -create \
    "${PACKAGE_SCRATCH_DIR}/arm64-apple-macosx/${BUILD_CONFIGURATION}/${ACP_NAME}" \
    "${PACKAGE_SCRATCH_DIR}/x86_64-apple-macosx/${BUILD_CONFIGURATION}/${ACP_NAME}" \
    -output "${MACOS_DIR}/${ACP_NAME}"
lipo -create \
    "${PACKAGE_SCRATCH_DIR}/arm64-apple-macosx/${BUILD_CONFIGURATION}/${WIDGET_NAME}" \
    "${PACKAGE_SCRATCH_DIR}/x86_64-apple-macosx/${BUILD_CONFIGURATION}/${WIDGET_NAME}" \
    -output "${WIDGET_MACOS_DIR}/${WIDGET_NAME}"
lipo "${MACOS_DIR}/ModelHub" -verify_arch arm64 x86_64
lipo "${MACOS_DIR}/${ACP_NAME}" -verify_arch arm64 x86_64
lipo "${WIDGET_MACOS_DIR}/${WIDGET_NAME}" -verify_arch arm64 x86_64
cp "packaging/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "packaging/WidgetInfo.plist" "${WIDGET_CONTENTS_DIR}/Info.plist"

swift "scripts/generate_icon.swift" "${ICON_SOURCE}"
for spec in \
    "16:icon_16x16.png" \
    "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" \
    "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" \
    "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" \
    "512:icon_256x256@2x.png" \
    "512:icon_512x512.png" \
    "1024:icon_512x512@2x.png"; do
    size=${spec%%:*}
    filename=${spec##*:}
    sips -z "${size}" "${size}" "${ICON_SOURCE}" --out "${ICONSET_DIR}/${filename}" >/dev/null
done
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/ModelHub.icns"
xcrun xcstringstool installloc "${PROJECT_ROOT}/packaging/Localization" \
    --output-directory "${RESOURCES_DIR}" \
    --no-xcstrings-sources
xcrun xcstringstool installloc "${PROJECT_ROOT}/packaging/Localization" \
    --output-directory "${WIDGET_RESOURCES_DIR}" \
    --no-xcstrings-sources

xattr -cr "${APP_DIR}"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    codesign --force --sign - "${MACOS_DIR}/${ACP_NAME}"
    codesign --force --sign - --entitlements "${PROJECT_ROOT}/packaging/ModelHubWidget.entitlements" "${WIDGET_APP_DIR}"
    codesign --force --sign - --entitlements "${PROJECT_ROOT}/packaging/ModelHub.entitlements" "${APP_DIR}"
else
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" "${MACOS_DIR}/${ACP_NAME}"
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" \
        --entitlements "${PROJECT_ROOT}/packaging/ModelHubWidget.entitlements" "${WIDGET_APP_DIR}"
    codesign --force --options runtime --timestamp --sign "${SIGNING_IDENTITY}" \
        --entitlements "${PROJECT_ROOT}/packaging/ModelHub.entitlements" "${APP_DIR}"
fi
codesign --verify --strict "${MACOS_DIR}/${ACP_NAME}"
codesign --verify --strict "${WIDGET_APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

remove_item "${DIST_APP_DIR}"
ditto --noextattr "${APP_DIR}" "${DIST_APP_DIR}"
xattr -cr "${DIST_APP_DIR}"
codesign --verify --strict "${DIST_APP_DIR}/Contents/PlugIns/${WIDGET_NAME}.appex"
codesign --verify --deep --strict "${DIST_APP_DIR}"
remove_item "${ZIP_PATH}"
ditto -c -k --norsrc --keepParent "${DIST_APP_DIR}" "${ZIP_PATH}"

echo "${DIST_APP_DIR}"
echo "${ZIP_PATH}"
