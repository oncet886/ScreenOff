# 关屏不待机 (ScreenOff)

<p align="center"><img src="assets/icon_1024.png" width="128"></p>

macOS 菜单栏小工具，两件事：

1. **关屏不待机**：一键把屏幕关掉，电脑照常运行（下载、编译、远程任务不中断）。只有**键盘任意键**能唤醒，鼠标动、点、滚一律忽略，不怕桌上的鼠标被碰到。
2. **第二条菜单栏**：刘海屏 / 图标太多时，菜单栏放不下的图标会被系统直接藏掉。点一下网格图标，弹出一条和菜单栏长得一样的面板：图标原样显示、悬停高亮、左键右键和真的一样、拖动就能在真实菜单栏里换位置。免费替代 Bartender 的这一个功能。

无第三方依赖，一个 Swift 文件，`swiftc` 直接编译。

## 安装

需要 Xcode 或 Command Line Tools（提供 `swiftc`）。

```bash
git clone https://github.com/oncet886/ScreenOff.git
cd ScreenOff
./install.sh
```

装好后菜单栏右侧会出现两个图标（在「控制中心」左边）：

| 图标 | 左键 | 右键 |
|---|---|---|
| 🖥 显示器 | 立即关屏 | 菜单 |
| ▦ 网格 | 弹出全部状态栏面板 | 菜单 |

也可以直接下载 Release 里的 `.app`，拖进「应用程序」。首次打开如果提示「无法验证开发者」，右键 → 打开。

## 使用

- **关屏**：点显示器图标，或全局快捷键 `⌘⇧L`，或在 Dock / 聚焦搜索里再打开一次本 app。按键盘任意键（包括 Shift）亮回来。
- **第二条菜单栏**：第一次点网格图标会要求「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能 → 打开「关屏不待机」）。要显示图标原样还需要「屏幕录制」权限，面板里有按钮引导，开完重启一次 app。
  - 面板按真实菜单栏的顺序从左到右排。底部带橙点的是被刘海挡住的。
  - 可见的项：左键、右键、拖动换位，和在菜单栏里操作一样。
  - 被刘海挡住的项：只支持左键（菜单会弹在刘海正下方）；右键和拖动做不到，系统对刘海底下既不渲染也不送达点击。它们的原样图标来自缓存：只要哪次露出来被截到过一次，以后就一直显示原样，没截到过的先显示 app 图标。
- **始终不待机**：右键菜单里勾上，屏幕亮着也不睡。
- **开机自动启动**：右键菜单里勾上，会写一个 LaunchAgent，不需要密码，开机后静默驻留。

## 原理

- 关屏不走系统的显示器休眠（那样鼠标一碰就亮），而是：全屏黑色窗口盖住所有屏幕 + 背光亮度降到 0（`DisplayServices` 私有 API，取不到就只靠黑窗） + `IOPMAssertion` 声明「不待机、不让显示器休眠」。黑窗只响应键盘事件。唤醒后恢复亮度并撤销声明。
- 第二条菜单栏：用 Accessibility API 枚举每个 app 的 `AXExtrasMenuBar` 子项，再按进程和位置匹配到窗口服务器里对应的状态栏窗口（layer 25），用 `CGWindowListCreateImage` 截该窗口得到原样图标（截到过的存入 `~/Library/Application Support/ScreenOff/icons`）。可见项的点击和拖动是在真实坐标上合成鼠标事件（拖动带 ⌘）；被刘海挡住的项用 `AXPress`。
- 本 app 自己的两个图标用 `NSStatusItem Preferred Position` 固定在第三方图标最右侧，菜单栏再满也不会被挤掉。

## 已知限制

- 被刘海挡住的项不能右键、不能拖动，也没法当场截图（见上）。
- 拖动的目标位置如果落在刘海底下，会被拒绝并提示。
- 某些自绘按钮的 app（如 Google Chrome）在被刘海挡住时不响应 `AXPress`，点了没反应；露出来后走真实点击就正常。
- 背光归零用的是私有 API，未来系统版本可能失效，届时只剩黑窗遮挡（屏幕仍会有微弱背光）。
- 仅在 macOS 15 / Apple Silicon 上测试过。

## 签名

`build.sh` 默认临时签名。「辅助功能」授权与签名绑定，临时签名每次重编译都要重新授权；有 Apple Development 证书的话：

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./install.sh
```

## 调试

```bash
关屏不待机.app/Contents/MacOS/ScreenOff --scan            # 列出枚举到的所有状态栏项
关屏不待机.app/Contents/MacOS/ScreenOff --press "App名"   # 按某一项并打印它弹出的窗口位置（加 --click 用合成点击，--right 右键）
关屏不待机.app/Contents/MacOS/ScreenOff --capture all      # 截每一项的图标存到 /tmp
关屏不待机.app/Contents/MacOS/ScreenOff --drag "App名" 1200 # 把某项 ⌘拖到 x=1200
面板的每次扫描 / 点击 / 拖动都记在 ~/Library/Logs/ScreenOff.log
```

## License

MIT
