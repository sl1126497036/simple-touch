# Simple Touch

Magic Mouse 自定义触控手势。
本程序在 Magic Mouse 2 + macOS 27 中编译验证，未对 Intel 版本 macOS 做适配。
本程序由人工设计验证，deepseek-v4.1-flash 编码。

## 手势映射

默认绑定如下，均可在配置文件或设置界面修改。

| 手势 | 默认动作 |
|---|---|
| 三指点按 | 应用程序网格 |
| 四指点按 | 区域截图到剪贴板 |
| 三指上滑 | 调度中心 |
| 三指下滑 | 显示桌面 |

## 构建与安装

```bash
./install.sh
```

首次运行需要授权辅助功能：系统设置 → 隐私与安全性 → 辅助功能 → 添加 `Simple Touch.app`。

## 配置

配置文件：`~/.config/simple-touch/config.json`（首次运行自动生成）


### 动作类型

| `kind` | `value` | 示例                                                                      |
|---|---|-------------------------------------------------------------------------|
| `preset` | 预置动作名，见下表 | `{ "kind": "preset", "value": "apps" }`                                 |
| `openApp` | bundle id 或 .app 路径 | `{ "kind": "openApp", "value": "com.apple.Safari" }`                    |
| `url` | 任意链接 | `{ "kind": "url", "value": "https://example.com" }`                     |
| `keyShortcut` | 键名，配合 `modifiers` | `{ "kind": "keyShortcut", "value": "space", "modifiers": ["command"] }` |
| `shell` | 由 `/bin/sh -c` 执行 | `{ "kind": "shell", "value": "say 手势触发" }`                              |

`keyShortcut` 的 `modifiers` 可取 `command`、`option`、`control`、`shift`、`fn`，可组合。

### 预置动作

| 名称 | 说明     |
|---|--------|
| `apps` | 应用程序网格 |
| `screenshot` | 区域截图到剪贴板 |
| `missioncontrol` | 调度中心   |
| `appexpose` | 应用程序窗口 |
| `showdesktop` | 显示桌面   |
| `spotlight` | 聚焦搜索   |
| `none` | 无动作    |

### 添加自定义绑定

如：“四指上滑打开访达”：

```json
{ "fingers": 4, "gesture": "swipeUp", "action": { "kind": "openApp", "value": "com.apple.finder" } }
```

如：“三指左滑发送按键组合”：

```json
{ "fingers": 3, "gesture": "swipeLeft", "action": { "kind": "keyShortcut", "value": "left", "modifiers": ["control"] } }
```
配置文件编辑后需重启 Simple Touch 生效；设置界面中调整后点“保存”立即生效。



### 调参说明

| 参数 | 作用                            |
|---|-------------------------------|
| `tapWindowMs` | 判定点按的回看窗口（毫秒）。机械按压会丢帧，窗口太小时可能把多指点按判成单指 |
| `cooldownMs` | 触发冷却：两次触发的最小间隔，防止连发                |
| `swipeThreshold` | 连续移动距离阈值。逐帧位移累加，来回抖动会互相抵消。调大更难触发 |
| `swipeMaxDurationMs` | 滑动的最大时长，超时不算滑动                |
| `swipeInvert` | 上下方向对调时设为 `true`              |
| `edgeMargin` | 边缘防误触比例                       |


## 命令行

```bash
"./Simple Touch.app/Contents/MacOS/SimpleTouch" --dry-run    # 观察模式，不拦截事件
"./Simple Touch.app/Contents/MacOS/SimpleTouch" --verbose    # 打印每次点击的判定与帧序列
"./Simple Touch.app/Contents/MacOS/SimpleTouch" --do=apps    # 执行一次动作
"./Simple Touch.app/Contents/MacOS/SimpleTouch" --windows    # 列出窗口（诊断）
```

`--verbose` 会打印类似 `14:23:01.512 [d] [点击] 原始 5 触点：[1, 1, 1, 1, 1]` 的日志，用于确认误判时实际读到的帧序列。滑动时打印该段的帧数、时长与连续移动距离，用来对照阈值。配置里设 `"debug": true` 效果相同。

## 目录

```
main.swift                    主程序：触摸解析、事件拦截、手势判定、动作执行
SettingsView.swift            设置界面（SwiftUI）
Info.plist                    应用包信息，构建时拷入 .app
com.simpletouch.app.plist     开机自启项模板
install.sh                    编译、生成图标、签名、安装自启
tools/makeicon.swift          App 图标生成器
LICENSE                       MIT 许可证
```


## 许可证

MIT，全文见 `LICENSE`。
