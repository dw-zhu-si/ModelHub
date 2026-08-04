#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
SOURCE_APP=${PROJECT_ROOT}/dist/ModelHub.app
CANDIDATE_APP=${PROJECT_ROOT}/dist/ModelHub-AppStore-Candidate.app
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_ROOT}/packaging/Info.plist")
PKG_PATH=${PROJECT_ROOT}/dist/ModelHub-${APP_VERSION}-AppStore.pkg
APP_PROFILE=${MODELHUB_APPSTORE_APP_PROFILE:-}
WIDGET_PROFILE=${MODELHUB_APPSTORE_WIDGET_PROFILE:-}
APP_IDENTITY=${MODELHUB_APPSTORE_SIGNING_IDENTITY:-}
INSTALLER_IDENTITY=${MODELHUB_APPSTORE_INSTALLER_IDENTITY:-}

for value_name in APP_PROFILE WIDGET_PROFILE APP_IDENTITY INSTALLER_IDENTITY; do
    value=${(P)value_name}
    if [[ -z "${value}" ]]; then
        echo "缺少 ${value_name} 对应的 MODELHUB_APPSTORE_* 环境变量" >&2
        exit 2
    fi
done
if [[ ! -f "${APP_PROFILE}" || ! -f "${WIDGET_PROFILE}" ]]; then
    echo "主应用或 Widget 的 App Store provisioning profile 不存在" >&2
    exit 2
fi
if [[ ! -d "${SOURCE_APP}" ]]; then
    echo "缺少 Universal App，请先运行 scripts/package_app.sh release" >&2
    exit 2
fi

/usr/bin/ditto --noextattr "${SOURCE_APP}" "${CANDIDATE_APP}"
/bin/cp "${APP_PROFILE}" "${CANDIDATE_APP}/Contents/embedded.provisionprofile"
/bin/cp "${WIDGET_PROFILE}" \
    "${CANDIDATE_APP}/Contents/PlugIns/ModelHubWidget.appex/Contents/embedded.provisionprofile"

codesign --force --options runtime --timestamp --sign "${APP_IDENTITY}" \
    --entitlements "${PROJECT_ROOT}/packaging/ModelHubACPAppStore.entitlements" \
    "${CANDIDATE_APP}/Contents/MacOS/ModelHubACP"
codesign --force --options runtime --timestamp --sign "${APP_IDENTITY}" \
    --entitlements "${PROJECT_ROOT}/packaging/ModelHubWidget.entitlements" \
    "${CANDIDATE_APP}/Contents/PlugIns/ModelHubWidget.appex"
codesign --force --options runtime --timestamp --sign "${APP_IDENTITY}" \
    --entitlements "${PROJECT_ROOT}/packaging/ModelHubAppStore.entitlements" \
    "${CANDIDATE_APP}"
codesign --verify --deep --strict "${CANDIDATE_APP}"
lipo "${CANDIDATE_APP}/Contents/MacOS/ModelHub" -verify_arch arm64 x86_64

productbuild --component "${CANDIDATE_APP}" /Applications \
    --sign "${INSTALLER_IDENTITY}" \
    "${PKG_PATH}"
pkgutil --check-signature "${PKG_PATH}"
echo "${PKG_PATH}"
