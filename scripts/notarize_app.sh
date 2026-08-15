#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
DIST_APP_PATH=${PROJECT_ROOT}/dist/ModelHub.app
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_ROOT}/packaging/Info.plist")
ZIP_PATH=${PROJECT_ROOT}/dist/ModelHub-${APP_VERSION}-macos-universal.zip
NOTARY_PROFILE=${MODELHUB_NOTARY_PROFILE:-}
NOTARY_KEY=${MODELHUB_NOTARY_KEY:-}
NOTARY_KEY_ID=${MODELHUB_NOTARY_KEY_ID:-}
NOTARY_ISSUER=${MODELHUB_NOTARY_ISSUER:-}
STAGING_ROOT=$(mktemp -d /private/tmp/modelhub-notarize.XXXXXX)
APP_PATH=${STAGING_ROOT}/ModelHub.app
NOTARIZED_ZIP=${STAGING_ROOT}/ModelHub-notarized.zip

remove_item() {
    /usr/bin/swift -e 'import Foundation; let path = CommandLine.arguments[1]; if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }' "$1"
}

cleanup() {
    remove_item "${STAGING_ROOT}"
}
trap cleanup EXIT

if [[ -z "${NOTARY_PROFILE}" && ( -z "${NOTARY_KEY}" || -z "${NOTARY_KEY_ID}" || -z "${NOTARY_ISSUER}" ) ]]; then
    echo "必须提供 MODELHUB_NOTARY_PROFILE，或完整的 MODELHUB_NOTARY_KEY / MODELHUB_NOTARY_KEY_ID / MODELHUB_NOTARY_ISSUER" >&2
    exit 2
fi
if [[ -n "${NOTARY_KEY}" && ! -f "${NOTARY_KEY}" ]]; then
    echo "指定的 App Store Connect API 私钥不存在" >&2
    exit 2
fi
if [[ ! -f "${ZIP_PATH}" ]]; then
    echo "缺少 Universal ZIP，请先运行 scripts/package_app.sh release" >&2
    exit 2
fi

/usr/bin/ditto -x -k "${ZIP_PATH}" "${STAGING_ROOT}"
codesign --verify --deep --strict "${APP_PATH}"
if [[ -n "${NOTARY_PROFILE}" ]]; then
    xcrun notarytool submit "${ZIP_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --no-s3-acceleration \
        --wait
else
    xcrun notarytool submit "${ZIP_PATH}" \
        --key "${NOTARY_KEY}" \
        --key-id "${NOTARY_KEY_ID}" \
        --issuer "${NOTARY_ISSUER}" \
        --no-s3-acceleration \
        --wait
fi
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
spctl --assess --type execute --verbose=4 "${APP_PATH}"

/usr/bin/ditto -c -k --norsrc --keepParent "${APP_PATH}" "${NOTARIZED_ZIP}"
/bin/mv "${NOTARIZED_ZIP}" "${ZIP_PATH}"

remove_item "${DIST_APP_PATH}"
/usr/bin/ditto --noextattr "${APP_PATH}" "${DIST_APP_PATH}"
for attempt in 1 2 3; do
    /usr/bin/xattr -cr "${DIST_APP_PATH}"
    if /usr/bin/codesign --verify --deep --strict "${DIST_APP_PATH}" 2>/dev/null; then
        break
    fi
    if [[ "${attempt}" == "3" ]]; then
        print -u2 "warning: FileProvider reattached metadata to ${DIST_APP_PATH}; use the verified ZIP"
    else
        /bin/sleep 0.1
    fi
done
echo "${ZIP_PATH}"
