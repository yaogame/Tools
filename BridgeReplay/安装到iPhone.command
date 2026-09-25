#!/bin/bash
# 坐庄复盘：一键编译并安装到 iPhone。
# 用法：iPhone 用数据线连上 Mac，在访达里双击本文件（被拦截时右键 → 打开）。
# 也可以在终端运行：bash 安装到iPhone.command
#
# 可选环境变量：
#   TEAM_ID=XXXXXXXXXX   指定开发者 Team ID（10 位）
#   BUNDLE_ID=com.xxx.yyy  指定 App 的 Bundle ID

cd "$(dirname "$0")" || exit 1

PROJECT="BridgeReplay.xcodeproj"
SCHEME="BridgeReplay"
BUNDLE_ID="${BUNDLE_ID:-com.yaogame.BridgeReplay}"
BUILD_DIR="build"
TEAM_FILE=".team_id"

say()  { printf "\n\033[1;32m==> %s\033[0m\n" "$1"; }
note() { printf "    %s\n" "$1"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$1"; }
pause_and_exit() { echo; read -r -p "按回车键关闭窗口…" _; exit "$1"; }
fail() { printf "\n\033[1;31m✗ %s\033[0m\n" "$1"; shift; for line in "$@"; do note "$line"; done; pause_and_exit 1; }

echo "坐庄复盘 · 安装到 iPhone"
echo "========================"

# ---------- 1. 检查环境 ----------
[ "$(uname)" = "Darwin" ] || fail "这个脚本只能在 Mac 上运行。" "iOS App 必须用 Mac 上的 Xcode 编译；Windows 可以用生成的 .ipa 配合 Sideloadly 安装。"
command -v xcodebuild >/dev/null 2>&1 || fail "没有找到 Xcode。" "请先从 App Store 安装 Xcode，并打开一次完成组件安装。"
if ! xcodebuild -version >/dev/null 2>&1; then
    fail "当前选中的是命令行工具，不是 Xcode。" "在终端运行：sudo xcode-select -s /Applications/Xcode.app"
fi
xcrun --find devicectl >/dev/null 2>&1 || fail "Xcode 版本太旧，找不到 devicectl。" "请升级到 Xcode 16 或更新版本。"
[ -d "$PROJECT" ] || fail "没有找到 $PROJECT。" "请把本文件放在 BridgeReplay 文件夹里（和 $PROJECT 在一起）再运行。"
note "$(xcodebuild -version | head -1)"

# ---------- 2. 开发者 Team ----------
detect_teams() {
    local tmp
    tmp=$(mktemp -d)
    {
        security find-certificate -a -c "Apple Development" -p 2>/dev/null
        security find-certificate -a -c "iPhone Developer" -p 2>/dev/null
    } > "$tmp/all.pem"
    awk -v dir="$tmp" '/-----BEGIN CERTIFICATE-----/{n++} n{print > (dir "/cert" n ".pem")}' "$tmp/all.pem"
    for f in "$tmp"/cert*.pem; do
        [ -f "$f" ] || continue
        openssl x509 -in "$f" -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p'
    done | sort -u
    rm -rf "$tmp"
}

TEAM_ID="${TEAM_ID:-}"
if [ -z "$TEAM_ID" ] && [ -f "$TEAM_FILE" ]; then
    TEAM_ID=$(tr -d ' \r\n' < "$TEAM_FILE")
fi
if [ -z "$TEAM_ID" ]; then
    # 如果在 Xcode 的 Signing & Capabilities 里选过 Team，就直接用它。
    TEAM_ID=$(xcodebuild -project "$PROJECT" -target "$SCHEME" -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^ *DEVELOPMENT_TEAM = /{print $2; exit}')
fi
if [ -z "$TEAM_ID" ]; then
    TEAMS=$(detect_teams)
    COUNT=$(printf "%s\n" "$TEAMS" | grep -c .)
    if [ "$COUNT" -eq 1 ]; then
        TEAM_ID="$TEAMS"
    elif [ "$COUNT" -gt 1 ]; then
        say "找到多个开发者 Team，请选择："
        i=1
        for t in $TEAMS; do note "$i) $t"; i=$((i + 1)); done
        read -r -p "输入序号：" pick
        [[ "$pick" =~ ^[0-9]+$ ]] && TEAM_ID=$(printf "%s\n" "$TEAMS" | sed -n "${pick}p")
    fi
fi
if [ -z "$TEAM_ID" ]; then
    say "需要你的开发者 Team ID（只需设置一次）"
    note "最简单的办法：用 Xcode 打开 $PROJECT → 左侧选 BridgeReplay → Signing & Capabilities"
    note "→ Team 选你的 Apple ID（免费的 Personal Team 也可以），然后重新运行本脚本即可自动读取。"
    note "如果 Team 列表是空的：Xcode → Settings → Accounts → 左下角 + 登录 Apple ID。"
    echo
    read -r -p "或者直接输入 10 位 Team ID（直接回车退出）：" TEAM_ID
    [ -n "$TEAM_ID" ] || pause_and_exit 1
fi
TEAM_ID=$(printf "%s" "$TEAM_ID" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "Team ID 格式不对：$TEAM_ID（应为 10 位字母数字）。"
echo "$TEAM_ID" > "$TEAM_FILE"
say "开发者 Team：$TEAM_ID"
note "Bundle ID：$BUNDLE_ID"

# ---------- 3. 找到 iPhone ----------
say "查找连接的 iPhone…"
JSON=$(mktemp)
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || fail "读取设备列表失败。" "请确认 iPhone 已用数据线连上 Mac。"

NAMES=()
UDIDS=()
i=0
while plutil -extract "result.devices.$i" json -o /dev/null "$JSON" >/dev/null 2>&1; do
    platform=$(plutil -extract "result.devices.$i.hardwareProperties.platform" raw -o - "$JSON" 2>/dev/null)
    udid=$(plutil -extract "result.devices.$i.hardwareProperties.udid" raw -o - "$JSON" 2>/dev/null)
    name=$(plutil -extract "result.devices.$i.deviceProperties.name" raw -o - "$JSON" 2>/dev/null)
    state=$(plutil -extract "result.devices.$i.connectionProperties.tunnelState" raw -o - "$JSON" 2>/dev/null)
    if [ "$platform" = "iOS" ] && [ -n "$udid" ] && [ "$state" != "unavailable" ]; then
        NAMES+=("${name:-iPhone}")
        UDIDS+=("$udid")
    fi
    i=$((i + 1))
done
rm -f "$JSON"

if [ "${#UDIDS[@]}" -eq 0 ]; then
    fail "没有找到可用的 iPhone。" \
        "1. 用数据线连上 Mac，解锁 iPhone，弹出「要信任此电脑吗」时点「信任」。" \
        "2. iPhone：设置 → 隐私与安全性 → 开发者模式 → 打开（需要重启手机）。" \
        "   没看到「开发者模式」这一项时，先用 Xcode 连一次：Window → Devices and Simulators。" \
        "3. 然后重新运行本脚本。"
elif [ "${#UDIDS[@]}" -eq 1 ]; then
    PICK=0
else
    echo "找到多台设备："
    for idx in "${!UDIDS[@]}"; do note "$((idx + 1))) ${NAMES[$idx]}"; done
    read -r -p "装到哪一台？输入序号：" n
    [[ "$n" =~ ^[0-9]+$ ]] || fail "序号不对。"
    PICK=$((n - 1))
    [ "$PICK" -ge 0 ] && [ "$PICK" -lt "${#UDIDS[@]}" ] || fail "序号不对。"
fi
DEVICE_NAME="${NAMES[$PICK]}"
UDID="${UDIDS[$PICK]}"
note "设备：$DEVICE_NAME（$UDID）"

# ---------- 4. 编译 ----------
say "编译并签名（第一次大约需要 1–3 分钟）…"
mkdir -p "$BUILD_DIR"
LOG="$BUILD_DIR/build.log"
if ! xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination "id=$UDID" \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_STYLE=Automatic \
        PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
        build > "$LOG" 2>&1; then
    echo
    grep -E "error:|No Account|No profiles|is not available|Signing" "$LOG" | sort -u | head -15
    fail "编译失败，完整日志：$(pwd)/$LOG" \
        "签名相关报错：先在 Xcode → Settings → Accounts 登录 Apple ID，再重新运行。" \
        "提示 Bundle ID 不可用：运行 BUNDLE_ID=com.你的名字.BridgeReplay bash 安装到iPhone.command" \
        "代码报错：把上面的 error 行发给 Claude 修改。"
fi
APP="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/BridgeReplay.app"
[ -d "$APP" ] || fail "编译完成但没找到 $APP。" "完整日志：$(pwd)/$LOG"
note "编译成功"

# 顺便打一个 .ipa，方便以后用 Sideloadly / AltStore 等工具安装。
rm -rf "$BUILD_DIR/Payload" "$BUILD_DIR/BridgeReplay.ipa"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP" "$BUILD_DIR/Payload/"
(cd "$BUILD_DIR" && zip -qry BridgeReplay.ipa Payload) && rm -rf "$BUILD_DIR/Payload"
[ -f "$BUILD_DIR/BridgeReplay.ipa" ] && note "安装包：$(pwd)/$BUILD_DIR/BridgeReplay.ipa"

# ---------- 5. 安装并打开 ----------
say "安装到 $DEVICE_NAME…"
if ! xcrun devicectl device install app --device "$UDID" "$APP" > "$BUILD_DIR/install.log" 2>&1; then
    tail -5 "$BUILD_DIR/install.log"
    fail "安装失败。" \
        "确认 iPhone 已解锁、已信任这台电脑，并打开了开发者模式（设置 → 隐私与安全性 → 开发者模式）。"
fi
note "安装完成"

if xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" >/dev/null 2>&1; then
    say "已在 iPhone 上打开「坐庄复盘」🎉"
else
    say "已安装。第一次打开前还要在手机上信任开发者："
    note "iPhone：设置 → 通用 → VPN与设备管理 → 选你的 Apple ID → 信任"
    note "然后在桌面点「坐庄复盘」图标即可。"
fi
echo
warn "提示：用免费 Apple ID 安装的 App 7 天后会失效，到时再双击本文件重新安装即可（牌局数据会保留）。"
pause_and_exit 0
