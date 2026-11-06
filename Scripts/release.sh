#!/usr/bin/env bash
# 首次使用先存一次公证凭证（按提示粘贴 App 专用密码）：
#   xcrun notarytool store-credentials audio-switch \
#     --apple-id 你的AppleID邮箱 --team-id YOUR_TEAM_ID
#
# 之后每次发版：
#   Scripts/release.sh 1.4.0
#
# 只构建不公证（测试用）：SKIP_NOTARIZE=1 Scripts/release.sh 1.4.0
#
# 产物在 .derived-data/release-artifacts/：dmg、zip、SHA256SUMS.txt
set -euo pipefail

VERSION="${1:?用法: Scripts/release.sh <版本号，例如 1.4.0>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/.derived-data/release-artifacts"
BUILD_DIR="$ROOT_DIR/.derived-data/release"
APP="$BUILD_DIR/Build/Products/Release/音频切换.app"
# 签名身份不写进仓库：默认从本机 Keychain 取（要求唯一），或用 CODESIGN_IDENTITY 指定
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2}' || true)"
  COUNT="$(printf '%s\n' "$IDENTITIES" | grep -c . || true)"
  [[ "$COUNT" == "1" ]] || { echo "本机有 $COUNT 个 Developer ID Application 证书，请用 CODESIGN_IDENTITY 指定唯一一个" >&2; exit 1; }
  IDENTITY="$IDENTITIES"
else
  IDENTITY="$CODESIGN_IDENTITY"
fi
DMG="$OUT_DIR/audio-switch-macos-arm64-v$VERSION.dmg"
ZIP="$OUT_DIR/audio-switch-macos-arm64-v$VERSION.zip"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

NOTARY_PROFILE="${NOTARY_PROFILE:-audio-switch}"

echo "==> 构建 $VERSION"
xcodebuild -project "$ROOT_DIR/音频切换.xcodeproj" -scheme "音频切换" \
  -configuration Release -derivedDataPath "$BUILD_DIR" \
  MARKETING_VERSION="$VERSION" CODE_SIGNING_ALLOWED=NO build

echo "==> 签名"
codesign --force --options runtime --timestamp \
  --entitlements "$ROOT_DIR/Configuration/音频切换.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ -z "${SKIP_NOTARIZE:-}" ]]; then
  mkdir -p "$OUT_DIR"
  echo "==> 提交公证（Apple 排队可能要几分钟到一小时）"
  ditto -c -k --keepParent "$APP" "$OUT_DIR/notarize.zip"
  xcrun notarytool submit "$OUT_DIR/notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> 装订票据"
  xcrun stapler staple "$APP"
  spctl -a -vvv -t exec "$APP"
else
  echo "==> 跳过公证（SKIP_NOTARIZE）"
fi

echo "==> 打包"
mkdir -p "$OUT_DIR"
hdiutil create -volname "音频切换" -srcfolder "$APP" -ov -format UDZO "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 生成校验文件"
(cd "$OUT_DIR" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)

echo
echo "完成："
ls -lh "$DMG" "$ZIP" "$OUT_DIR/SHA256SUMS.txt"
echo
echo "下一步："
echo "  gh release create v$VERSION --title \"Audio Switch $VERSION\" --generate-notes \\"
echo "    \"$DMG\" \"$ZIP\" \"$OUT_DIR/SHA256SUMS.txt\""
