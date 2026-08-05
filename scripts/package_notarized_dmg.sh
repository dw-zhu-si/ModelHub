#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
APP_PATH=${MODELHUB_DMG_APP_PATH:-${PROJECT_ROOT}/dist/ModelHub.app}
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_ROOT}/packaging/Info.plist")
DMG_PATH=${PROJECT_ROOT}/dist/ModelHub-${APP_VERSION}-macos-universal.dmg
SHA256_PATH=${DMG_PATH}.sha256
SIGNING_IDENTITY=${MODELHUB_SIGNING_IDENTITY:-}
NOTARY_PROFILE=${MODELHUB_NOTARY_PROFILE:-}
STAGING_ROOT=$(mktemp -d /private/tmp/modelhub-dmg.XXXXXX)
VOLUME_ROOT=${STAGING_ROOT}/volume
NOTARY_RESULT=${STAGING_ROOT}/notary-result.json
MOUNT_ROOT=${STAGING_ROOT}/mount

remove_item() {
    /usr/bin/swift -e 'import Foundation; let path = CommandLine.arguments[1]; if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }' "$1"
}

cleanup() {
    if /sbin/mount | /usr/bin/grep -Fq "${MOUNT_ROOT}"; then
        /usr/bin/hdiutil detach "${MOUNT_ROOT}" -quiet || true
    fi
    remove_item "${STAGING_ROOT}"
}
trap cleanup EXIT

if [[ -z "${SIGNING_IDENTITY}" ]]; then
    echo "必须通过 MODELHUB_SIGNING_IDENTITY 指定 Developer ID Application 身份" >&2
    exit 2
fi
if [[ -z "${NOTARY_PROFILE}" ]]; then
    echo "必须通过 MODELHUB_NOTARY_PROFILE 指定已存在的 notarytool Keychain profile" >&2
    exit 2
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

/usr/bin/codesign --force --timestamp --sign "${SIGNING_IDENTITY}" "${DMG_PATH}"
/usr/bin/codesign --verify --verbose=2 "${DMG_PATH}"
/usr/bin/xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait \
    --output-format json > "${NOTARY_RESULT}"

NOTARY_STATUS=$(/usr/bin/jq -r '.status' "${NOTARY_RESULT}")
NOTARY_ID=$(/usr/bin/jq -r '.id' "${NOTARY_RESULT}")
if [[ "${NOTARY_STATUS}" != "Accepted" ]]; then
    echo "DMG 公证失败：${NOTARY_STATUS}（${NOTARY_ID}）" >&2
    /usr/bin/xcrun notarytool log "${NOTARY_ID}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
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
/usr/bin/hdiutil detach "${MOUNT_ROOT}" -quiet

DMG_SHA256=$(/usr/bin/shasum -a 256 "${DMG_PATH}" | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s  %s\n' "${DMG_SHA256}" "${DMG_PATH:t}" > "${SHA256_PATH}"

echo "dmg_path=${DMG_PATH}"
echo "sha256_path=${SHA256_PATH}"
echo "sha256=${DMG_SHA256}"
echo "notary_submission_id=${NOTARY_ID}"
echo "notary_status=${NOTARY_STATUS}"
echo "stapler_status=valid"
echo "gatekeeper_status=accepted"
