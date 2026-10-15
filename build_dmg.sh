#!/bin/bash
# TVBox macOS 构建 + DMG 打包脚本
#
# 用法:
#   ./build_dmg.sh                         # Release 构建（universal），ad-hoc 签名，打 DMG
#   ./build_dmg.sh --arch arm64            # 只构建 Apple Silicon
#   ./build_dmg.sh --app path/TVBox.app    # 跳过构建，直接把已有 App 打成 DMG
#   ./build_dmg.sh --sign "Developer ID Application: XXX (TEAMID)" \
#                  --notarize <notarytool-keychain-profile>   # 正式签名 + 公证
#
# 产物: dist/TVBox-<版本>-<架构>.dmg（同时打印 sha256）
# 环境变量: APP_VERSION 覆盖版本号，BUILD_NUMBER 覆盖构建号（不传则用工程里的值）
# 依赖: 完整 Xcode（xcodebuild；仅装 Command Line Tools 不够），--app 模式只需系统自带 hdiutil。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="TVBox"
SCHEME="tvbox-macOS"
PROJECT="tvbox.xcodeproj"
CONFIGURATION="Release"
ENTITLEMENTS="tvbox/tvbox-macOS.entitlements"
BUILD_DIR="build"
DIST_DIR="dist"

ARCH="universal"
SIGN_IDENTITY="-"
NOTARY_PROFILE=""
PREBUILT_APP=""

usage() {
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)      ARCH="${2:?--arch 需要参数: universal|arm64|x86_64}"; shift 2 ;;
        --sign)      SIGN_IDENTITY="${2:?--sign 需要签名身份}"; shift 2 ;;
        --notarize)  NOTARY_PROFILE="${2:?--notarize 需要 notarytool keychain profile}"; shift 2 ;;
        --app)       PREBUILT_APP="${2:?--app 需要 .app 路径}"; shift 2 ;;
        -h|--help)   usage 0 ;;
        *)           echo "❌ 未知参数: $1"; usage 1 ;;
    esac
done

case "$ARCH" in
    universal) ARCHS="arm64 x86_64" ;;
    arm64|x86_64) ARCHS="$ARCH" ;;
    *) echo "❌ 不支持的架构: ${ARCH}（可选 universal / arm64 / x86_64）"; exit 1 ;;
esac

if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_IDENTITY" = "-" ]; then
    echo "❌ 公证需要 Developer ID 签名，请同时传 --sign"
    exit 1
fi

step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------- 构建

ensure_entitlements() {
    # 该文件被 .gitignore 忽略，新 clone 下不存在会导致签名阶段失败，这里补一份最小配置。
    [ -f "$ENTITLEMENTS" ] && return
    step "未找到 $ENTITLEMENTS，生成默认 entitlements（网络访问 + 本地服务）"
    cat > "$ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <!-- 去广告的本地播放列表服务监听 127.0.0.1 -->
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
EOF
}

build_app() {
    if ! xcodebuild -version >/dev/null 2>&1; then
        echo "❌ xcodebuild 不可用：需要安装完整 Xcode 并执行"
        echo "   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        echo "   （已有构建好的 App 时可用 --app 跳过构建）"
        exit 1
    fi

    # project.yml 是工程的源头；装了 xcodegen 就先重新生成，避免 pbxproj 与之脱节。
    if command -v xcodegen >/dev/null 2>&1; then
        step "XcodeGen 重新生成工程"
        xcodegen generate
    fi

    ensure_entitlements

    # 只清理构建产物，保留 DerivedData/SourcePackages（SwiftPM 依赖，CI 会缓存它）
    rm -rf "$BUILD_DIR/Products" "$BUILD_DIR/DerivedData/Build" "$BUILD_DIR/dmg_stage" "$BUILD_DIR/$APP_NAME.app"
    # 仓库没有提交共享 scheme：xcodebuild 能识别到 scheme 就按 scheme 构建，否则退回按 target 构建。
    local build_args products_dir
    if xcodebuild -list -project "$PROJECT" 2>/dev/null | sed -n '/Schemes:/,$p' | grep -qx "[[:space:]]*$SCHEME"; then
        step "构建 scheme $SCHEME ($CONFIGURATION, $ARCHS)"
        build_args=(-scheme "$SCHEME" -destination "generic/platform=macOS" -derivedDataPath "$BUILD_DIR/DerivedData")
        products_dir="$BUILD_DIR/DerivedData/Build/Products/$CONFIGURATION"
    else
        step "未找到 scheme $SCHEME，按 target 构建 ($CONFIGURATION, $ARCHS)"
        build_args=(-target "$SCHEME" -sdk macosx SYMROOT="$(pwd)/$BUILD_DIR/Products")
        products_dir="$BUILD_DIR/Products/$CONFIGURATION"
    fi

    # 可选覆盖版本号：APP_VERSION（如 1.0.5）、BUILD_NUMBER（如 CI 运行序号）
    local version_args=()
    [ -n "${APP_VERSION:-}" ] && version_args+=(MARKETING_VERSION="$APP_VERSION")
    [ -n "${BUILD_NUMBER:-}" ] && version_args+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

    # 构建阶段不签名：工程配置了自动签名 + Team，CI/无开发者账号的机器上会直接失败；
    # 签名统一在 sign_app 里做（ad-hoc 或 --sign 指定的 Developer ID）。
    xcodebuild \
        -project "$PROJECT" \
        "${build_args[@]}" \
        -configuration "$CONFIGURATION" \
        ARCHS="$ARCHS" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        ${version_args[@]+"${version_args[@]}"} \
        build | { command -v xcpretty >/dev/null 2>&1 && xcpretty || cat; }

    APP_PATH="$products_dir/$APP_NAME.app"
    if [ ! -d "$APP_PATH" ]; then
        echo "❌ 找不到构建产物: $APP_PATH"
        exit 1
    fi
}

# ---------------------------------------------------------------- 签名

sign_app() {
    local app="$1"
    # 拷贝/解压过的 App 带隔离属性，签名前清掉
    xattr -cr "$app"

    if [ "$SIGN_IDENTITY" = "-" ]; then
        step "ad-hoc 签名（分发后首次打开需右键 → 打开）"
        codesign --force --deep --sign - "$app"
    else
        step "Developer ID 签名: $SIGN_IDENTITY"
        local entitlement_args=()
        [ -f "$ENTITLEMENTS" ] && entitlement_args=(--entitlements "$ENTITLEMENTS")
        # 由内向外签：先嵌入的 framework/dylib，再 App 本体（公证要求 hardened runtime + 时间戳）
        find "$app/Contents" \( -name "*.framework" -o -name "*.dylib" \) -prune -print0 2>/dev/null |
            while IFS= read -r -d '' item; do
                codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$item"
            done
        # macOS 自带 bash 3.2 在 set -u 下展开空数组会报 unbound variable
        codesign --force --timestamp --options runtime ${entitlement_args[@]+"${entitlement_args[@]}"} --sign "$SIGN_IDENTITY" "$app"
    fi

    codesign --verify --deep --strict "$app"
    echo "签名校验通过"
}

# ---------------------------------------------------------------- DMG

make_dmg() {
    local app="$1" dmg="$2"
    local stage="$BUILD_DIR/dmg_stage"

    step "生成 DMG: $dmg"
    rm -rf "$stage"
    mkdir -p "$stage" "$(dirname "$dmg")"
    # ditto 能完整保留符号链接、扩展属性和签名
    ditto "$app" "$stage/$APP_NAME.app"
    ln -s /Applications "$stage/Applications"

    rm -f "$dmg"
    hdiutil create -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO -fs HFS+ "$dmg" >/dev/null
    rm -rf "$stage"

    if [ "$SIGN_IDENTITY" != "-" ]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
    fi
    hdiutil verify "$dmg" >/dev/null
    echo "DMG 校验通过"
}

notarize_dmg() {
    local dmg="$1"
    step "提交公证（profile: ${NOTARY_PROFILE}）"
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
}

# ---------------------------------------------------------------- 主流程

if [ -n "$PREBUILT_APP" ]; then
    [ -d "$PREBUILT_APP" ] || { echo "❌ 找不到 App: $PREBUILT_APP"; exit 1; }
    mkdir -p "$BUILD_DIR"
    APP_PATH="$BUILD_DIR/$APP_NAME.app"
    rm -rf "$APP_PATH"
    ditto "$PREBUILT_APP" "$APP_PATH"
else
    build_app
fi

sign_app "$APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
BINARY="$APP_PATH/Contents/MacOS/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "$APP_NAME")"
if [ -f "$BINARY" ]; then
    # 以实际二进制架构命名，--app 模式下也准确
    BIN_ARCHS=$(lipo -archs "$BINARY" 2>/dev/null || echo "$ARCHS")
    case "$BIN_ARCHS" in
        *arm64*x86_64*|*x86_64*arm64*) ARCH="universal" ;;
        *) ARCH="$BIN_ARCHS" ;;
    esac
fi

DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION-$ARCH.dmg"
make_dmg "$APP_PATH" "$DMG_PATH"

[ -n "$NOTARY_PROFILE" ] && notarize_dmg "$DMG_PATH"

echo
echo "✅ 打包完成: $DMG_PATH"
echo "   版本 $VERSION / 架构 $ARCH / 大小 $(du -h "$DMG_PATH" | cut -f1)"
echo "   sha256 $(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
