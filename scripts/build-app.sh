#!/usr/bin/env bash
#
# build-app.sh —— 把 SPM 编译产物组装成 DingDing.app
#
# 为什么需要这个脚本：
#   `swift build` 只产出一个裸可执行文件（.build/<config>/DingDing）。
#   macOS 的 menubar app 要求是一个 .app bundle —— 一个有固定目录结构、
#   带 Info.plist 的文件夹。没有完整 Xcode 时，这个组装工作就由本脚本做。
#
# 用法：
#   ./scripts/build-app.sh            # release 构建
#   ./scripts/build-app.sh debug      # debug 构建
#
# 产物：项目根目录下的 DingDing.app

set -euo pipefail

# 切到项目根目录（脚本在 scripts/ 下）
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="DingDing"
APP_BUNDLE="${APP_NAME}.app"

echo "==> swift build (${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "错误：找不到可执行文件 ${BIN_PATH}" >&2
    exit 1
fi

echo "==> 组装 ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}"            "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist"   "${APP_BUNDLE}/Contents/Info.plist"
# M6.x 加 app icon（"叮"字蓝色圆角 logo）
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

# ASR 模型从 M2 起拷进 Resources/。现在 models/ 可能还是空的，故容错处理。
if [[ -d "models" ]] && [[ -n "$(ls -A models 2>/dev/null | grep -v '^.gitkeep$' || true)" ]]; then
    echo "==> 拷贝 ASR 模型 models/ -> Contents/Resources/models/"
    mkdir -p "${APP_BUNDLE}/Contents/Resources/models"
    cp -R models/* "${APP_BUNDLE}/Contents/Resources/models/"
fi

echo ""
echo "✅ 完成：$(pwd)/${APP_BUNDLE}"
echo "   运行：open ${APP_BUNDLE}"
echo "   （首次运行 macOS 可能提示「未验证的开发者」——右键 -> 打开）"
