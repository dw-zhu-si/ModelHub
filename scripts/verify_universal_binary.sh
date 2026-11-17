#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "用法：$0 <Mach-O 二进制路径>" >&2
    exit 2
fi

BINARY_PATH=$1
if [[ ! -f "${BINARY_PATH}" ]]; then
    echo "待校验的 Mach-O 二进制不存在：${BINARY_PATH}" >&2
    exit 2
fi

for architecture in arm64 x86_64; do
    /usr/bin/lipo "${BINARY_PATH}" -verify_arch "${architecture}"
done
