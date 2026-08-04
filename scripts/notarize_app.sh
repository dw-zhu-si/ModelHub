#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
APP_PATH=${PROJECT_ROOT}/dist/ModelHub.app
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_ROOT}/packaging/Info.plist")
ZIP_PATH=${PROJECT_ROOT}/dist/ModelHub-${APP_VERSION}-macos-universal.zip
NOTARY_PROFILE=${MODELHUB_NOTARY_PROFILE:-}

if [[ -z "${NOTARY_PROFILE}" ]]; then
    echo "必须通过 MODELHUB_NOTARY_PROFILE 指定已存在的 notarytool Keychain profile" >&2
    exit 2
fi
if [[ ! -d "${APP_PATH}" || ! -f "${ZIP_PATH}" ]]; then
    echo "缺少 Universal App 或 ZIP，请先运行 scripts/package_app.sh release" >&2
    exit 2
fi

codesign --verify --deep --strict "${APP_PATH}"
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
xcrun stapler staple "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
spctl --assess --type execute --verbose=4 "${APP_PATH}"

/usr/bin/ditto -c -k --norsrc --keepParent "${APP_PATH}" "${ZIP_PATH}.notarized"
/bin/mv "${ZIP_PATH}.notarized" "${ZIP_PATH}"
echo "${ZIP_PATH}"
