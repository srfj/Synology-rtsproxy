#!/bin/bash
#
# Build a Synology DSM 6.2.3 (.spk) package for RTSProxy.
#
# The binary is cross-compiled as a fully static x86_64/musl executable, so it
# runs on every DSM 6 x86_64 platform without depending on the NAS glibc.
#
# Usage:  ./build_synology.sh
# Output: bin/synology/rtsproxy-<version>.spk
#
set -e

PKG_NAME="rtsproxy"
PKG_VERSION="1.0.0-1"
# DSM 6 x86_64 platforms (same list as the official SynoCommunity x86_64 packages)
PKG_ARCH="apollolake avoton braswell broadwell broadwellnk bromolow cedarview denverton dockerx64 geminilake grantley purley kvmx64 v1000 x86 x86_64"

TOOLCHAIN="x86_64-unknown-linux-musl"
TOOLCHAIN_URL="https://github.com/cross-tools/musl-cross/releases/download/20250929/${TOOLCHAIN}.tar.xz"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPK_SRC="${SCRIPT_DIR}/spk"
BUILD_DIR="${SCRIPT_DIR}/build"
TOOLCHAIN_DIR="${REPO_DIR}/toolchains"
TOOLCHAIN_PATH="${TOOLCHAIN_DIR}/${TOOLCHAIN}"
OUT_DIR="${REPO_DIR}/bin/synology"

# 1. Host build dependencies
command -v meson >/dev/null 2>&1 || { echo "错误: 未找到 meson, 请先安装: pip install meson"; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "错误: 未找到 ninja, 请先安装"; exit 1; }

# 2. Cross toolchain (downloaded once, reused afterwards)
mkdir -p "${TOOLCHAIN_DIR}"
if [ ! -x "${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-g++" ]; then
    echo "正在下载交叉编译工具链 ${TOOLCHAIN} ..."
    curl -fL --retry 3 -o "${TOOLCHAIN_DIR}/${TOOLCHAIN}.tar.xz" "${TOOLCHAIN_URL}"
    tar xJf "${TOOLCHAIN_DIR}/${TOOLCHAIN}.tar.xz" -C "${TOOLCHAIN_DIR}"
else
    echo "工具链已存在，跳过下载。"
fi

mkdir -p "${BUILD_DIR}"

# 3. Meson cross file
CROSS_FILE="${BUILD_DIR}/${TOOLCHAIN}.ini"
cat > "${CROSS_FILE}" <<EOF
[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[binaries]
cpp = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-g++'
ar = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-ar'
as = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-as'
ld = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-ld'
nm = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-nm'
objcopy = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-objcopy'
objdump = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-objdump'
ranlib = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-ranlib'
strip = '${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-strip'
EOF

# 4. Compile the static binary
echo "开始交叉编译静态二进制文件 ..."
rm -rf "${BUILD_DIR}/build-static-x64"
meson setup "${BUILD_DIR}/build-static-x64" \
    --cross-file="${CROSS_FILE}" \
    --strip --buildtype=release \
    -Disstatic=true
meson compile -C "${BUILD_DIR}/build-static-x64"

BIN="${BUILD_DIR}/build-static-x64/rtsproxy"
[ -x "${BIN}" ] || { echo "错误: 未生成二进制文件 ${BIN}"; exit 1; }

# Strip debug symbols (meson only strips on install, which we do not run)
"${TOOLCHAIN_PATH}/bin/${TOOLCHAIN}-strip" "${BIN}"

# 5. Stage the package.tgz payload
#    bin/rtsproxy  : the static executable
#    webui/        : the /admin/ panel, loaded relative to the working directory
#    app/          : desktop icon config, port config and icons
STAGE="${BUILD_DIR}/stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/bin" "${STAGE}/webui"
cp "${BIN}" "${STAGE}/bin/rtsproxy"
cp "${REPO_DIR}"/webui/* "${STAGE}/webui/"
cp -r "${SPK_SRC}/app" "${STAGE}/app"

# 6. package.tgz (the inner gzipped payload)
tar czf "${BUILD_DIR}/package.tgz" -C "${STAGE}" .

# 7. Assemble the .spk tree
SPK_STAGE="${BUILD_DIR}/spk"
rm -rf "${SPK_STAGE}"
mkdir -p "${SPK_STAGE}"
cp "${BUILD_DIR}/package.tgz" "${SPK_STAGE}/"
cp -r "${SPK_SRC}/conf" "${SPK_SRC}/scripts" "${SPK_SRC}/WIZARD_UIFILES" "${SPK_STAGE}/"
cp "${SPK_SRC}/PACKAGE_ICON.PNG" "${SPK_SRC}/PACKAGE_ICON_256.PNG" "${SPK_STAGE}/"
chmod 755 "${SPK_STAGE}"/scripts/*

# LICENSE at the SPK root feeds the "License Agreement" page of the DSM
# install wizard. Without it that page renders blank and "Next" stays
# disabled, blocking a manual install. Make sure it is plain text ending
# with a newline, which is what the DSM license viewer expects.
if [ -n "$(tail -c 1 "${REPO_DIR}/LICENSE")" ]; then
    { cat "${REPO_DIR}/LICENSE"; echo; } > "${SPK_STAGE}/LICENSE"
else
    cp "${REPO_DIR}/LICENSE" "${SPK_STAGE}/LICENSE"
fi
chmod 644 "${SPK_STAGE}/LICENSE"

# 8. INFO with the md5 of package.tgz
CHECKSUM="$(md5sum "${SPK_STAGE}/package.tgz" | awk '{print $1}')"
sed -e "s/@VERSION@/${PKG_VERSION}/" \
    -e "s/@ARCH@/${PKG_ARCH}/" \
    -e "s/@CHECKSUM@/${CHECKSUM}/" \
    "${SPK_SRC}/INFO.template" > "${SPK_STAGE}/INFO"

# 9. Pack the .spk (uncompressed tar, exactly like the official packages)
mkdir -p "${OUT_DIR}"
SPK_FILE="${OUT_DIR}/${PKG_NAME}-${PKG_VERSION}.spk"
rm -f "${SPK_FILE}"
tar cf "${SPK_FILE}" -C "${SPK_STAGE}" \
    INFO package.tgz conf scripts WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG LICENSE

echo "======================================="
echo "编译成功！"
echo "套件包: ${SPK_FILE}"
echo "二进制: $(ls -lh "${BIN}" | awk '{print $5}')"
echo "校验和: ${CHECKSUM}"
