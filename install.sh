#!/bin/zsh
# 编译 + 安装到 ~/Applications + 启动(静默驻留菜单栏)
set -e
cd "$(dirname "$0")"
./build.sh
pkill -x ScreenOff 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/关屏不待机.app
cp -R "关屏不待机.app" ~/Applications/
open ~/Applications/关屏不待机.app --args --background
echo "已安装并启动:~/Applications/关屏不待机.app"
