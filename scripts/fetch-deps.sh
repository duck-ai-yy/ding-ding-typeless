#!/usr/bin/env bash
#
# fetch-deps.sh —— 拉取 sherpa-onnx 静态库 + Zipformer 中文模型到本地
#
# 为什么需要：
#   - 宪法 #1（全本地零网络）：模型必须预先落地，运行时绝不联网下载
#   - 宪法 #6（构建可复现）：版本号 + SHA256 写死，任何人 clone repo 跑此脚本
#     都能复刻出一模一样的依赖树
#   - 库 + 模型不进 git（库 ~50MB / 模型 ~80MB），靠此脚本复现，库目录已 gitignored
#
# 用法：
#   ./scripts/fetch-deps.sh         # 拉所有缺失依赖；已存在且 SHA 对就跳过
#
# 产物：
#   Vendor/sherpa-onnx/{lib, include}    sherpa-onnx v1.13.2 静态库 + headers
#   models/zipformer-zh/                  zipformer-multi-zh-hans 2023-9-2
#
# [PATCH #4] SHA256 校验是硬要求（详见 m2-plan §2）：
#   - 不能省（违反宪法 #1 信任根）
#   - 不能 echo 通过就过（必须真 shasum -a 256 取值比对）
#   - 不能 fallback skip（校验失败 → exit 1，不是 warning）

set -euo pipefail

# 切到项目根（脚本在 scripts/ 下）
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ---- 资产版本 & SHA256（来源：decisions.md 2026-05-23 sherpa-onnx spike 事实清单）----

SHERPA_VERSION="v1.13.2"
SHERPA_TARBALL="sherpa-onnx-${SHERPA_VERSION}-osx-x64-static-no-tts.tar.bz2"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/${SHERPA_TARBALL}"
SHERPA_SHA256="1cf9a3061e9393e511f5a0a44f44aa0426c94673f60dff7ddf3e69ea668ee80f"
# 解压后顶层目录名（sherpa 官方约定 = tarball 去掉 .tar.bz2）
SHERPA_EXTRACTED_DIR="sherpa-onnx-${SHERPA_VERSION}-osx-x64-static-no-tts"

MODEL_NAME="sherpa-onnx-zipformer-multi-zh-hans-2023-9-2"
MODEL_TARBALL="${MODEL_NAME}.tar.bz2"
MODEL_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${MODEL_TARBALL}"
MODEL_SHA256="c4925a6b0f998800d16f80caf90d2decff7b7a8c156d044c6cffdf141c847d94"

# ---- M4-1 标点恢复模型（v4.2 第三方 ranger810 HF 镜像 int8 量化）----
#
# 模型源：ranger810/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8
# 形态：HF 单文件直下（非 tarball），需 2 个文件
# Supply chain 信任根：SHA256 锁版本（详见 m4-plan §10 / decisions.md M4-0 spike §1）
# 上游变更 → SHA256 不匹配 → fetch 硬失败 → 人工审过 ranger810 commit 才更新 SHA256
# 一次性下载永不更新（标点模型不会过时，详见 plan §10 "永不更新机制"）
PUNCT_BASE="https://huggingface.co/ranger810/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/resolve/main"
PUNCT_MODEL_URL="${PUNCT_BASE}/model.int8.onnx"
PUNCT_TOKENS_URL="${PUNCT_BASE}/tokens.json"
# SHA256 由架构师 2026-05-24 19:30 实测 + dev M4-0 spike 复核（decisions.md M4-0 §1）
PUNCT_MODEL_SHA256="65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1"
PUNCT_TOKENS_SHA256="c960ab87bccea4aa15cf49a59f71973c2c330b46668048cd8da253749ec71ee3"

# ---- 路径常量 ----

VENDOR_DIR="${ROOT}/Vendor/sherpa-onnx"
MODEL_DIR="${ROOT}/models/zipformer-zh"
PUNCT_DIR="${ROOT}/models/punct-zh-en"
CACHE_DIR="${ROOT}/Vendor/.cache"

mkdir -p "${VENDOR_DIR}" "${MODEL_DIR%/*}" "${PUNCT_DIR%/*}" "${CACHE_DIR}"

# ---- 辅助：硬校验 SHA256（[PATCH #4]）----
# 用法：verify_sha256 <file> <expected>
# 失败明确打印 "expected X got Y" 并 exit 1（宪法 #3 异常不静默）
verify_sha256() {
    local file="$1"
    local expected="$2"
    if [[ ! -f "${file}" ]]; then
        echo "ERROR: 校验对象不存在: ${file}" >&2
        exit 1
    fi
    # shasum -a 256 输出 "<hex>  <path>"，awk 取第一列拿纯 hex
    local actual
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "ERROR: SHA256 校验失败（refusing to proceed）" >&2
        echo "  file:     ${file}" >&2
        echo "  expected: ${expected}" >&2
        echo "  got:      ${actual}" >&2
        echo "可能原因：网络劫持、release 资产被替换、或上游发了新版本忘记更新本脚本" >&2
        exit 1
    fi
    echo "  SHA256 OK: ${actual}"
}

# ---- 辅助：下载（带 SHA 校验和断点续传兜底）----
# 用法：fetch <url> <dest_file> <expected_sha256>
# 如果文件已存在且 SHA 对就跳过；不对就删了重下；下完仍不对就 exit 1
fetch() {
    local url="$1"
    local dest="$2"
    local expected="$3"

    if [[ -f "${dest}" ]]; then
        echo "==> 已存在，先校验：${dest}"
        local actual
        actual="$(shasum -a 256 "${dest}" | awk '{print $1}')"
        if [[ "${actual}" == "${expected}" ]]; then
            echo "  SHA256 OK（跳过下载）"
            return 0
        fi
        echo "  SHA256 不匹配（expected ${expected}, got ${actual}），删除后重新下载"
        rm -f "${dest}"
    fi

    echo "==> 下载 ${url}"
    # -L 跟随 GitHub release 重定向；--fail 让 HTTP 4xx/5xx 直接报错
    # 用 .part 临时文件，下完才 mv，避免 ctrl-C 留半成品被下次误判
    curl -L --fail --progress-bar -o "${dest}.part" "${url}"
    mv "${dest}.part" "${dest}"

    echo "==> 校验下载产物"
    verify_sha256 "${dest}" "${expected}"
}

# ============================================================
# Step 1: sherpa-onnx 静态库
# ============================================================

echo ""
echo "########## sherpa-onnx ${SHERPA_VERSION} ##########"

SHERPA_TARBALL_PATH="${CACHE_DIR}/${SHERPA_TARBALL}"

# 如果 Vendor/sherpa-onnx/lib 已经有库就跳过解压（幂等）
# 用 libsherpa-onnx-c-api.a 作为安装完成标志
if [[ -f "${VENDOR_DIR}/lib/libsherpa-onnx-c-api.a" ]]; then
    echo "==> 已安装：${VENDOR_DIR}/lib/libsherpa-onnx-c-api.a（跳过）"
else
    fetch "${SHERPA_URL}" "${SHERPA_TARBALL_PATH}" "${SHERPA_SHA256}"

    echo "==> 解压到 Vendor/sherpa-onnx/"
    # 先清空 Vendor/sherpa-onnx/ 内容（保留目录本身），再解压
    rm -rf "${VENDOR_DIR}"
    mkdir -p "${VENDOR_DIR}"
    # 解压到 cache 目录，再把 lib/include 挪到 Vendor 下（扁平结构，
    # 方便 Package.swift 写相对路径 Vendor/sherpa-onnx/lib，不带版本号）
    tar -xjf "${SHERPA_TARBALL_PATH}" -C "${CACHE_DIR}"
    EXTRACTED="${CACHE_DIR}/${SHERPA_EXTRACTED_DIR}"
    if [[ ! -d "${EXTRACTED}" ]]; then
        echo "ERROR: 解压后找不到预期目录 ${EXTRACTED}" >&2
        echo "（上游可能改了顶层目录命名，需更新本脚本 SHERPA_EXTRACTED_DIR）" >&2
        exit 1
    fi
    # 挪 lib/ 和 include/
    if [[ ! -d "${EXTRACTED}/lib" ]] || [[ ! -d "${EXTRACTED}/include" ]]; then
        echo "ERROR: 解压后缺少 lib/ 或 include/ 子目录" >&2
        ls -la "${EXTRACTED}" >&2
        exit 1
    fi
    mv "${EXTRACTED}/lib"     "${VENDOR_DIR}/lib"
    mv "${EXTRACTED}/include" "${VENDOR_DIR}/include"
    # 清理解压剩余物
    rm -rf "${EXTRACTED}"

    # 二次确认关键产物
    if [[ ! -f "${VENDOR_DIR}/lib/libsherpa-onnx-c-api.a" ]]; then
        echo "ERROR: 解压后找不到 libsherpa-onnx-c-api.a（上游包结构可能变了）" >&2
        exit 1
    fi
    if [[ ! -f "${VENDOR_DIR}/include/sherpa-onnx/c-api/c-api.h" ]]; then
        echo "ERROR: 解压后找不到 sherpa-onnx/c-api/c-api.h（上游 header 路径可能变了）" >&2
        exit 1
    fi
    echo "==> sherpa-onnx 安装完成：${VENDOR_DIR}"
fi

# ============================================================
# Step 2: Zipformer 中文 ASR 模型
# ============================================================

echo ""
echo "########## ${MODEL_NAME} ##########"

MODEL_TARBALL_PATH="${CACHE_DIR}/${MODEL_TARBALL}"

# 用 tokens.txt 作为模型安装完成标志
if [[ -f "${MODEL_DIR}/tokens.txt" ]]; then
    echo "==> 已安装：${MODEL_DIR}（跳过）"
else
    fetch "${MODEL_URL}" "${MODEL_TARBALL_PATH}" "${MODEL_SHA256}"

    echo "==> 解压到 models/zipformer-zh/"
    rm -rf "${MODEL_DIR}"
    # 先解压到 cache，再把内部目录挪过来 + 重命名为 zipformer-zh
    tar -xjf "${MODEL_TARBALL_PATH}" -C "${CACHE_DIR}"
    MODEL_EXTRACTED="${CACHE_DIR}/${MODEL_NAME}"
    if [[ ! -d "${MODEL_EXTRACTED}" ]]; then
        echo "ERROR: 解压后找不到预期目录 ${MODEL_EXTRACTED}" >&2
        exit 1
    fi
    mv "${MODEL_EXTRACTED}" "${MODEL_DIR}"

    # 二次确认关键文件（spike 已验过的 4 个文件 + tokens）
    for f in tokens.txt \
             encoder-epoch-20-avg-1.int8.onnx \
             decoder-epoch-20-avg-1.int8.onnx \
             joiner-epoch-20-avg-1.int8.onnx; do
        if [[ ! -f "${MODEL_DIR}/${f}" ]]; then
            echo "ERROR: 模型文件缺失：${MODEL_DIR}/${f}（上游模型包结构可能变了）" >&2
            exit 1
        fi
    done
    echo "==> 模型安装完成：${MODEL_DIR}"
fi

# ============================================================
# Step 3: CT-Transformer 标点恢复模型（M4-1，v4.2 第三方 ranger810 int8 镜像）
# ============================================================
#
# 与 Step 2 ASR 模型的区别：
#   - 不是 tarball，是 HF 单文件直下（model.int8.onnx + tokens.json 各下一次）
#   - 信任根：SHA256 锁版本（plan §10 supply chain 决策）
#   - 失败不致命：punct 加载失败 → AppDelegate 走 fallback 粘 ASR 原文
#
# 幂等：双文件（model.int8.onnx + tokens.json）都存在才算装好，缺一就重下
# （v4.1 tarball 时单文件标志足够因为 tar 解压原子；v4.2 单文件直下需双校验避免
#  半成品状态——例如下完 model 但没下完 tokens 就被 ctrl-C）

echo ""
echo "########## sherpa-onnx punct ct-transformer-zh-en int8 (ranger810) ##########"

if [[ -f "${PUNCT_DIR}/model.int8.onnx" ]] && [[ -f "${PUNCT_DIR}/tokens.json" ]]; then
    echo "==> 已安装：${PUNCT_DIR}（双文件齐全，跳过；如需重下请手动 rm -rf ${PUNCT_DIR}）"
else
    # 缺一就两个都重新跑（fetch helper 自身幂等：若文件存在且 SHA 对会跳过）
    mkdir -p "${PUNCT_DIR}"
    fetch "${PUNCT_MODEL_URL}"  "${PUNCT_DIR}/model.int8.onnx" "${PUNCT_MODEL_SHA256}"
    fetch "${PUNCT_TOKENS_URL}" "${PUNCT_DIR}/tokens.json"     "${PUNCT_TOKENS_SHA256}"

    # 二次确认双文件齐全（防御性，若 fetch 内部出错应已 exit，留兜底）
    for f in model.int8.onnx tokens.json; do
        if [[ ! -f "${PUNCT_DIR}/${f}" ]]; then
            echo "ERROR: 标点模型文件缺失：${PUNCT_DIR}/${f}" >&2
            exit 1
        fi
    done
    echo "==> 标点模型安装完成：${PUNCT_DIR}"
fi

echo ""
echo "✅ 所有依赖就绪："
echo "   sherpa-onnx 库：${VENDOR_DIR}/lib  (libsherpa-onnx-c-api.a + 10 个静态库)"
echo "   sherpa-onnx 头：${VENDOR_DIR}/include/sherpa-onnx/c-api/c-api.h"
echo "   ASR 模型：     ${MODEL_DIR}"
echo "   标点模型：     ${PUNCT_DIR} (model.int8.onnx 72MB + tokens.json 4MB)"
echo ""
echo "下一步：swift build"
