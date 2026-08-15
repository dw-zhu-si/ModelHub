#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
APP_PATH=${MODELHUB_DMG_APP_PATH:-${PROJECT_ROOT}/dist/ModelHub.app}
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_ROOT}/packaging/Info.plist")
APP_ZIP=${PROJECT_ROOT}/dist/ModelHub-${APP_VERSION}-macos-universal.zip
DMG_PATH=${PROJECT_ROOT}/dist/ModelHub-${APP_VERSION}-macos-universal.dmg
SHA256_PATH=${DMG_PATH}.sha256
SIGNING_IDENTITY=${MODELHUB_SIGNING_IDENTITY:-}
TIMESTAMP_URL=${MODELHUB_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}
NOTARY_PROFILE=${MODELHUB_NOTARY_PROFILE:-}
NOTARY_KEY=${MODELHUB_NOTARY_KEY:-}
NOTARY_KEY_ID=${MODELHUB_NOTARY_KEY_ID:-}
NOTARY_ISSUER=${MODELHUB_NOTARY_ISSUER:-}
STAGING_ROOT=$(mktemp -d /private/tmp/modelhub-dmg.XXXXXX)
VOLUME_ROOT=${STAGING_ROOT}/volume
NOTARY_RESULT=${STAGING_ROOT}/notary-result.json
MOUNT_ROOT=${STAGING_ROOT}/mount

remove_item() {
    /usr/bin/swift -e 'import Foundation; let path = CommandLine.arguments[1]; if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }' "$1"
}

detach_mount() {
    if ! /sbin/mount | /usr/bin/grep -Fq "${MOUNT_ROOT}"; then
        return 0
    fi
    if /usr/bin/hdiutil detach "${MOUNT_ROOT}" -quiet; then
        return 0
    fi
    /bin/sleep 1
    /usr/bin/hdiutil detach "${MOUNT_ROOT}" -force -quiet
}

cleanup() {
    detach_mount || true
    remove_item "${STAGING_ROOT}"
}
trap cleanup EXIT

if [[ -z "${SIGNING_IDENTITY}" ]]; then
    echo "必须通过 MODELHUB_SIGNING_IDENTITY 指定 Developer ID Application 身份" >&2
    exit 2
fi
if [[ -z "${NOTARY_PROFILE}" && ( -z "${NOTARY_KEY}" || -z "${NOTARY_KEY_ID}" || -z "${NOTARY_ISSUER}" ) ]]; then
    echo "必须提供 MODELHUB_NOTARY_PROFILE，或完整的 MODELHUB_NOTARY_KEY / MODELHUB_NOTARY_KEY_ID / MODELHUB_NOTARY_ISSUER" >&2
    exit 2
fi
if [[ -n "${NOTARY_KEY}" && ! -f "${NOTARY_KEY}" ]]; then
    echo "指定的 App Store Connect API 私钥不存在" >&2
    exit 2
fi
if [[ -z "${MODELHUB_DMG_APP_PATH:-}" && -f "${APP_ZIP}" ]]; then
    /bin/mkdir -p "${STAGING_ROOT}/source"
    /usr/bin/ditto -x -k "${APP_ZIP}" "${STAGING_ROOT}/source"
    APP_PATH=${STAGING_ROOT}/source/ModelHub.app
fi
if [[ ! -d "${APP_PATH}" ]]; then
    echo "缺少待打包 App：${APP_PATH}" >&2
    exit 2
fi

/usr/bin/codesign --verify --deep --strict "${APP_PATH}"
/usr/bin/xcrun stapler validate "${APP_PATH}"

/bin/mkdir -p "${VOLUME_ROOT}" "${MOUNT_ROOT}" "${PROJECT_ROOT}/dist"
/usr/bin/ditto --noextattr "${APP_PATH}" "${VOLUME_ROOT}/ModelHub.app"
/bin/ln -s /Applications "${VOLUME_ROOT}/Applications"
if [[ -f "${APP_PATH}/Contents/Resources/ModelHub.icns" ]]; then
    /bin/cp "${APP_PATH}/Contents/Resources/ModelHub.icns" "${VOLUME_ROOT}/.VolumeIcon.icns"
fi
/usr/bin/xattr -cr "${VOLUME_ROOT}/ModelHub.app"
/usr/bin/codesign --verify --deep --strict "${VOLUME_ROOT}/ModelHub.app"

remove_item "${DMG_PATH}"
remove_item "${SHA256_PATH}"
/usr/bin/hdiutil create \
    -volname "ModelHub ${APP_VERSION}" \
    -srcfolder "${VOLUME_ROOT}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "${DMG_PATH}"

/usr/bin/codesign --force --timestamp="${TIMESTAMP_URL}" --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
/usr/bin/codesign --verify --verbose=2 "${DMG_PATH}"
if [[ -n "${NOTARY_PROFILE}" ]]; then
    /usr/bin/xcrun notarytool submit "${DMG_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --no-s3-acceleration \
        --wait \
        --output-format json > "${NOTARY_RESULT}"
else
    /usr/bin/xcrun notarytool submit "${DMG_PATH}" \
        --key "${NOTARY_KEY}" \
        --key-id "${NOTARY_KEY_ID}" \
        --issuer "${NOTARY_ISSUER}" \
        --no-s3-acceleration \
        --wait \
        --output-format json > "${NOTARY_RESULT}"
fi

NOTARY_STATUS=$(/usr/bin/jq -r '.status' "${NOTARY_RESULT}")
NOTARY_ID=$(/usr/bin/jq -r '.id' "${NOTARY_RESULT}")
if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
    echo "DMG 公证失败：${NOTARY_STATUS}（${NOTARY_ID}）" >&2
    if [[ -n "${NOTARY_PROFILE}" ]]; then
        /usr/bin/xcrun notarytool log "${NOTARY_ID}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
    else
        /usr/bin/xcrun notarytool log "${NOTARY_ID}" \
            --key "${NOTARY_KEY}" \
            --key-id "${NOTARY_KEY_ID}" \
            --issuer "${NOTARY_ISSUER}" >&2 || true
    fi
    exit 1
fi

/usr/bin/xcrun stapler staple "${DMG_PATH}"
/usr/bin/xcrun stapler validate "${DMG_PATH}"
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG_PATH}"
/usr/bin/hdiutil verify "${DMG_PATH}"

/usr/bin/hdiutil attach "${DMG_PATH}" -readonly -nobrowse -noautoopen -mountpoint "${MOUNT_ROOT}" -quiet
/usr/bin/codesign --verify --deep --strict "${MOUNT_ROOT}/ModelHub.app"
/usr/bin/xcrun stapler validate "${MOUNT_ROOT}/ModelHub.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "${MOUNT_ROOT}/ModelHub.app"
detach_mount

DMG_SHA256=$(/usr/bin/shasum -a 256 "${DMG_PATH}" | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s  %s\n' "${DMG_SHA256}" "${DMG_PATH:t}" > "${SHA256_PATH}"

echo "dmg_path=${DMG_PATH}"
echo "sha256_path=${SHA256_PATH}"
echo "sha256=${DMG_SHA256}"
echo "notary_submission_id=${NOTARY_ID}"
echo "notary_status=${NOTARY_STATUS}"
echo "stapler_status=valid"
echo "gatekeeper_status=accepted"
