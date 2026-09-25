#!/bin/bash
# 坐庄复盘：一键打开 Xcode 运行 / 在模拟器里运行 / 装到 iPhone。
# 用法：在终端运行  bash ~/Downloads/BridgeReplay/一键运行.command
#       （运行一次后，以后在访达里双击本文件也可以）

cd "$(dirname "$0")" || exit 1
HERE="$(pwd)"
PROJECT="BridgeReplay.xcodeproj"
SCHEME="BridgeReplay"
BUNDLE_ID="com.yaogame.BridgeReplay"

say()  { printf "\n\033[1;32m==> %s\033[0m\n" "$1"; }
note() { printf "    %s\n" "$1"; }
fail() { printf "\n\033[1;31m✗ %s\033[0m\n" "$1"; shift; for line in "$@"; do note "$line"; done; echo; read -r -p "按回车键关闭…" _; exit 1; }

echo "坐庄复盘 · 一键运行"
echo "=================="

# 下载的 zip 会被 macOS 加上隔离标记，先去掉，之后双击也能运行。
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null
chmod +x "$HERE"/*.command 2>/dev/null

[ "$(uname)" = "Darwin" ] || fail "只能在 Mac 上运行。"
[ -d "$PROJECT" ] || fail "没有找到 $PROJECT。" "请把本文件放在 BridgeReplay 文件夹里（和 $PROJECT 在一起）。"
command -v xcodebuild >/dev/null 2>&1 || fail "没有找到 Xcode。" "请先从 App Store 安装 Xcode，并打开一次完成组件安装。"
xcodebuild -version >/dev/null 2>&1 || fail "当前选中的是命令行工具，不是 Xcode。" "在终端运行：sudo xcode-select -s /Applications/Xcode.app"

echo
echo "请选择："
echo "  1) 打开 Xcode 并直接运行（用 Xcode 顶部选中的模拟器或 iPhone）【默认】"
echo "  2) 在模拟器里编译运行（不需要签名，编译错误会显示在这里）"
echo "  3) 装到连接的 iPhone"
echo "  4) 只用 Xcode 打开工程"
read -r -p "输入序号后回车（直接回车选 1）：" choice
choice="${choice:-1}"

open_in_xcode_and_run() {
    say "打开 Xcode 并运行…"
    note "第一次会弹出「终端想要控制 Xcode」，请点「好」。"
    osascript <<EOF
tell application "Xcode"
    activate
    set doc to open POSIX file "$HERE/$PROJECT"
    repeat 120 times
        if loaded of doc then exit repeat
        delay 1
    end repeat
    run doc
end tell
EOF
    if [ $? -ne 0 ]; then
        open "$PROJECT"
        note "自动运行没成功，已经用 Xcode 打开工程：在顶部选一个模拟器或你的 iPhone，按 ⌘R 运行。"
    else
        note "已开始运行。编译进度和错误在 Xcode 左侧的报告里（⌘9）。"
        note "装到真机时要在 Signing & Capabilities 里选你的 Apple ID 作为 Team。"
    fi
}

run_in_simulator() {
    say "查找模拟器…"
    local line sim name
    line=$(xcrun simctl list devices available | grep -E "^[[:space:]]+iPhone" | grep "(Booted)" | head -1)
    [ -n "$line" ] || line=$(xcrun simctl list devices available | grep -E "^[[:space:]]+iPhone" | tail -1)
    [ -n "$line" ] || fail "没有可用的 iPhone 模拟器。" "打开 Xcode → Settings → Components，下载一个 iOS 模拟器。"
    sim=$(echo "$line" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
    name=$(echo "$line" | sed -E 's/^[[:space:]]*(.*) \([0-9A-F-]{36}\).*/\1/')
    note "模拟器：$name"

    say "编译（第一次大约 1–3 分钟）…"
    mkdir -p build
    local log="build/simulator-build.log"
    if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
            -destination "id=$sim" -derivedDataPath build/Simulator build > "$log" 2>&1; then
        echo
        grep -E "error:" "$log" | sort -u | head -20
        open "$PROJECT"
        fail "编译失败，完整日志：$HERE/$log" \
            "上面是 error 行，请复制发给 Claude；也已经用 Xcode 打开工程，按 ⌘B 可以看到出错位置。"
    fi
    local app="build/Simulator/Build/Products/Debug-iphonesimulator/BridgeReplay.app"
    [ -d "$app" ] || fail "编译完成但没找到 $app。"

    say "启动模拟器并安装…"
    xcrun simctl boot "$sim" 2>/dev/null
    open -a Simulator
    xcrun simctl install "$sim" "$app" || fail "安装到模拟器失败。"
    xcrun simctl launch "$sim" "$BUNDLE_ID" >/dev/null || fail "启动失败。"
    say "已在模拟器里打开「坐庄复盘」🎉"
    note "模拟器没有相机：测试照片识别可以把照片拖进模拟器窗口存到相册，再在 App 里「从相册选照片」。"
}

case "$choice" in
    1) open_in_xcode_and_run ;;
    2) run_in_simulator ;;
    3) exec bash "$HERE/安装到iPhone.command" ;;
    4) open "$PROJECT"; say "已用 Xcode 打开工程，选好模拟器或 iPhone 后按 ⌘R 运行。" ;;
    *) fail "没有这个选项：$choice" ;;
esac
echo
read -r -p "按回车键关闭…" _
