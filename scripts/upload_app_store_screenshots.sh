#!/bin/zsh
set -euo pipefail

ASC_API_ROOT=https://api.appstoreconnect.apple.com/v1
ASC_ISSUER_ID=${ASC_ISSUER_ID:-}
ASC_KEY_ID=${ASC_KEY_ID:-}
ASC_PRIVATE_KEY_PATH=${ASC_PRIVATE_KEY_PATH:-}
ASC_SCREENSHOT_SET_ID=${ASC_SCREENSHOT_SET_ID:-}

if [[ -z "${ASC_ISSUER_ID}" || -z "${ASC_KEY_ID}" || -z "${ASC_PRIVATE_KEY_PATH}" || -z "${ASC_SCREENSHOT_SET_ID}" ]]; then
    echo "必须设置 ASC_ISSUER_ID、ASC_KEY_ID、ASC_PRIVATE_KEY_PATH 和 ASC_SCREENSHOT_SET_ID" >&2
    exit 2
fi
if [[ ! -f "${ASC_PRIVATE_KEY_PATH}" ]]; then
    echo "App Store Connect 私钥文件不存在" >&2
    exit 2
fi
if (( $# == 0 )); then
    echo "至少需要一个截图文件" >&2
    exit 2
fi

generate_token() {
    /usr/bin/swift -e 'import Foundation
import CryptoKit

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let keyID = CommandLine.arguments[1]
let issuerID = CommandLine.arguments[2]
let keyPath = CommandLine.arguments[3]
let key = try P256.Signing.PrivateKey(
    pemRepresentation: String(contentsOfFile: keyPath, encoding: .utf8)
)
let now = Int(Date().timeIntervalSince1970)
let header = try JSONSerialization.data(withJSONObject: [
    "alg": "ES256", "kid": keyID, "typ": "JWT"
])
let payload = try JSONSerialization.data(withJSONObject: [
    "iss": issuerID, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"
])
let signingInput = base64URL(header) + "." + base64URL(payload)
let signature = try key.signature(for: Data(signingInput.utf8))
print(signingInput + "." + base64URL(signature.rawRepresentation))
' "${ASC_KEY_ID}" "${ASC_ISSUER_ID}" "${ASC_PRIVATE_KEY_PATH}"
}

upload_operation() {
    local file_path=$1
    local operation_json=$2
    local method url length offset
    local -a header_args

    method=$(jq -r '.method' <<<"${operation_json}")
    url=$(jq -r '.url' <<<"${operation_json}")
    length=$(jq -r '.length' <<<"${operation_json}")
    offset=$(jq -r '.offset' <<<"${operation_json}")
    header_args=()
    while IFS=$'\t' read -r header_name header_value; do
        header_args+=(--header "${header_name}: ${header_value}")
    done < <(jq -r '.requestHeaders[]? | [.name, .value] | @tsv' <<<"${operation_json}")

    /bin/dd if="${file_path}" bs=1 skip="${offset}" count="${length}" 2>/dev/null \
        | /usr/bin/curl --silent --show-error --fail \
            --request "${method}" \
            "${header_args[@]}" \
            --data-binary @- \
            "${url}" >/dev/null
}

ASC_TOKEN=$(generate_token)
trap 'unset ASC_TOKEN' EXIT

for screenshot_path in "$@"; do
    if [[ ! -f "${screenshot_path}" ]]; then
        echo "截图不存在：${screenshot_path}" >&2
        exit 2
    fi

    file_name=${screenshot_path:t}
    file_size=$(/usr/bin/stat -f '%z' "${screenshot_path}")
    create_payload=$(jq -n \
        --arg file_name "${file_name}" \
        --argjson file_size "${file_size}" \
        --arg screenshot_set_id "${ASC_SCREENSHOT_SET_ID}" \
        '{data:{type:"appScreenshots",attributes:{fileName:$file_name,fileSize:$file_size},relationships:{appScreenshotSet:{data:{type:"appScreenshotSets",id:$screenshot_set_id}}}}}')

    create_response=$(/usr/bin/curl --silent --show-error --fail \
        --request POST \
        --header "Authorization: Bearer ${ASC_TOKEN}" \
        --header 'Content-Type: application/json' \
        --data "${create_payload}" \
        "${ASC_API_ROOT}/appScreenshots")
    screenshot_id=$(jq -r '.data.id' <<<"${create_response}")

    while IFS= read -r operation_base64; do
        operation_json=$(printf '%s' "${operation_base64}" | /usr/bin/base64 --decode)
        upload_operation "${screenshot_path}" "${operation_json}"
    done < <(jq -r '.data.attributes.uploadOperations[] | @base64' <<<"${create_response}")

    commit_payload=$(jq -n --arg screenshot_id "${screenshot_id}" \
        '{data:{type:"appScreenshots",id:$screenshot_id,attributes:{uploaded:true}}}')
    commit_response=$(/usr/bin/curl --silent --show-error --fail \
        --request PATCH \
        --header "Authorization: Bearer ${ASC_TOKEN}" \
        --header 'Content-Type: application/json' \
        --data "${commit_payload}" \
        "${ASC_API_ROOT}/appScreenshots/${screenshot_id}")

    asset_state=$(jq -r '.data.attributes.assetDeliveryState.state // "PROCESSING"' <<<"${commit_response}")
    echo "uploaded=${file_name} id=${screenshot_id} state=${asset_state}"
done
