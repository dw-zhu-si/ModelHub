#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_ROOT=${SCRIPT_DIR:h}
SOURCE_APP=${PROJECT_ROOT}/dist/ModelHub.app
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PROJECT_ROOT}/packaging/Info.plist")
PKG_PATH=${PROJECT_ROOT}/dist/ModelHub-${APP_VERSION}-AppStore.pkg
APP_PROFILE=${MODELHUB_APPSTORE_APP_PROFILE:-}
WIDGET_PROFILE=${MODELHUB_APPSTORE_WIDGET_PROFILE:-}
APP_IDENTITY=${MODELHUB_APPSTORE_SIGNING_IDENTITY:-}
INSTALLER_IDENTITY=${MODELHUB_APPSTORE_INSTALLER_IDENTITY:-}
TIMESTAMP_URL=${MODELHUB_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}
STAGING_ROOT=$(mktemp -d /private/tmp/modelhub-app-store.XXXXXX)
CANDIDATE_APP=${STAGING_ROOT}/ModelHub.app

remove_item() {
    /usr/bin/swift -e 'import Foundation; let path = CommandLine.arguments[1]; if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }' "$1"
}

cleanup() {
    remove_item "${STAGING_ROOT}"
}
trap cleanup EXIT

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

remove_item "${CANDIDATE_APP}"
/usr/bin/ditto --noextattr "${SOURCE_APP}" "${CANDIDATE_APP}"
/bin/cp "${PROJECT_ROOT}/packaging/Info.plist" "${CANDIDATE_APP}/Contents/Info.plist"
/bin/cp "${APP_PROFILE}" "${CANDIDATE_APP}/Contents/embedded.provisionprofile"
/bin/cp "${WIDGET_PROFILE}" \
    "${CANDIDATE_APP}/Contents/PlugIns/ModelHubWidget.appex/Contents/embedded.provisionprofile"
/usr/bin/xattr -cr "${CANDIDATE_APP}"
if /usr/bin/xattr -lr "${CANDIDATE_APP}" | /usr/bin/grep -q 'com.apple.quarantine'; then
    echo "App Store 候选仍包含 com.apple.quarantine 扩展属性" >&2
    exit 2
fi

codesign --force --options runtime --timestamp="${TIMESTAMP_URL}" --sign "${APP_IDENTITY}" \
    --entitlements "${PROJECT_ROOT}/packaging/ModelHubACPAppStore.entitlements" \
    "${CANDIDATE_APP}/Contents/MacOS/ModelHubACP"
codesign --force --options runtime --timestamp="${TIMESTAMP_URL}" --sign "${APP_IDENTITY}" \
    --entitlements "${PROJECT_ROOT}/packaging/ModelHubWidgetAppStore.entitlements" \
    "${CANDIDATE_APP}/Contents/PlugIns/ModelHubWidget.appex"
codesign --force --options runtime --timestamp="${TIMESTAMP_URL}" --sign "${APP_IDENTITY}" \
    --entitlements "${PROJECT_ROOT}/packaging/ModelHubAppStore.entitlements" \
    "${CANDIDATE_APP}"
codesign --verify --deep --strict "${CANDIDATE_APP}"
lipo "${CANDIDATE_APP}/Contents/MacOS/ModelHub" -verify_arch arm64 x86_64
if ! nm -u "${CANDIDATE_APP}/Contents/PlugIns/ModelHubWidget.appex/Contents/MacOS/ModelHubWidget" | \
    /usr/bin/grep -q '_NSExtensionMain'; then
    echo "Widget 缺少 App Extension 入口 _NSExtensionMain" >&2
    exit 2
fi

APP_SIGNED_IDENTIFIER=$(codesign -d --entitlements :- "${CANDIDATE_APP}" 2>/dev/null | \
    plutil -extract 'com\.apple\.application-identifier' raw -o - -)
WIDGET_SIGNED_IDENTIFIER=$(codesign -d --entitlements :- \
    "${CANDIDATE_APP}/Contents/PlugIns/ModelHubWidget.appex" 2>/dev/null | \
    plutil -extract 'com\.apple\.application-identifier' raw -o - -)
if [[ "${APP_SIGNED_IDENTIFIER}" != "L4G2HAQ5B5.com.local.modelhub" ]]; then
    echo "主应用签名缺少正确的 application identifier" >&2
    exit 2
fi
if [[ "${WIDGET_SIGNED_IDENTIFIER}" != "L4G2HAQ5B5.com.local.modelhub.widget" ]]; then
    echo "Widget 签名缺少正确的 application identifier" >&2
    exit 2
fi

remove_item "${PKG_PATH}"
productbuild --component "${CANDIDATE_APP}" /Applications \
    --sign "${INSTALLER_IDENTITY}" \
    "${PKG_PATH}"
pkgutil --check-signature "${PKG_PATH}"
echo "${PKG_PATH}"
