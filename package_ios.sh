#!/bin/bash
set -e

# 设置工作目录为脚本所在目录
cd "$(dirname "$0")"

echo "清理构建目录..."
rm -rf build
rm -rf tvbox.xcarchive
rm -f TVBox.ipa

# 证书和配置 (从 secrets.sh 加载，此文件在 IOS-key 中已 gitignore)
if [ -f "IOS-key/secrets.sh" ]; then
    source "IOS-key/secrets.sh"
else
    echo "❌ 错误: 未找到 IOS-key/secrets.sh，请确保该文件存在。"
    exit 1
fi

P12_PATH="IOS-key/cert.p12"
PROVISION_PATH="IOS-key/cert.mobileprovision"
# 变量已从 secrets.sh 加载: $P12_PASSWORD, $PROVISION_UUID, $TEAM_ID, $BUNDLE_ID, $SIGNING_IDENTITY

echo "安装 Provisioning Profile..."
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROVISION_PATH" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROVISION_UUID.mobileprovision"

echo "导入 P12 证书..."
# 将证书导入当前用户的默认钥匙串 (login.keychain)
security import "$P12_PATH" -k ~/Library/Keychains/login.keychain-db -P "$P12_PASSWORD" -T /usr/bin/codesign || true
# 解锁钥匙串以防超时
security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db

echo "Regenerating project with XcodeGen..."
xcodegen generate

SCHEME="tvbox"
CONFIGURATION="Release"
ARCHIVE_PATH="build/tvbox.xcarchive"
EXPORT_PATH="build/exported"
EXPORT_OPTIONS="ExportOptions.plist"

echo "开始构建 iOS Archive..."
xcodebuild archive \
    -project tvbox.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=iOS" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER="$PROVISION_UUID" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"

if [ -f "$EXPORT_OPTIONS" ]; then
    echo "发现 $EXPORT_OPTIONS，尝试导出 IPA..."
    mkdir -p "$EXPORT_PATH"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        -exportPath "$EXPORT_PATH" \
        -allowProvisioningUpdates

    # 查找生成的 .ipa 文件并移动到根目录
    IPA_FILE=$(find "$EXPORT_PATH" -name "*.ipa" | head -n 1)
    if [ -n "$IPA_FILE" ]; then
        cp "$IPA_FILE" ./TVBox.ipa
        echo "✅ 打包完成！生成文件: TVBox.ipa"
    else
        echo "⚠️  未能在导出目录中找到 .ipa 文件。"
    fi
else
    echo "ℹ️  未找到 $EXPORT_OPTIONS，仅生成 Archive。"
    echo "✅ 构建完成！Archive 路径: $ARCHIVE_PATH"
    echo "您可以打开 Xcode 使用 Distribute App 手动导出 IPA。"
fi
