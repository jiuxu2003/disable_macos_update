# disable_macos_update

一个用于**关闭 macOS 自动更新与更新小红点**、并可一键**恢复**的 shell 脚本。

- 只依赖系统自带的 `bash` / `defaults` / `launchctl` / `softwareupdate`
- 修改前自动备份原始配置，`restore` 可完整还原
- 支持 `--dry-run` 演练，先看清楚会改什么再执行

## 快速开始

```bash
chmod +x disable_macos_update.sh

./disable_macos_update.sh status     # 先看当前状态（只读）
./disable_macos_update.sh badge      # 只清红点（不需要 sudo）
./disable_macos_update.sh disable    # 关闭自动更新 + 清红点
./disable_macos_update.sh restore    # 恢复自动更新
```

需要时再加选项：

```bash
./disable_macos_update.sh disable --with-hosts   # 同时用 /etc/hosts 屏蔽更新服务器
./disable_macos_update.sh disable --dry-run      # 只打印命令，不做任何修改
```

脚本会在需要时自己调用 `sudo` 并提示输入密码，**请不要用 `sudo ./disable_macos_update.sh` 运行**（用户级设置会写到 root 名下）。

## 它做了什么

`disable` 共 7 步：

| 步骤 | 具体操作 | 作用 |
| --- | --- | --- |
| 1 | 备份 `/Library/Preferences/com.apple.SoftwareUpdate.plist` | 保存 `backups/pre-disable.plist`（仅首次）与带时间戳的历史快照 |
| 2 | `softwareupdate --schedule off`<br>`defaults write ... AutomaticCheckEnabled/AutomaticDownload/AutomaticallyInstallMacOSUpdates/CriticalUpdateInstall/ConfigDataInstall -bool false` | 不再自动检查、下载、安装任何更新；写入后会校验并重试 |
| 3 | `launchctl kickstart -k system/com.apple.softwareupdated`（两个守护进程） | 让 `softwareupdated` 丢掉旧的内存缓存、重新从磁盘读偏好，避免它把刚才写的配置回写掉 |
| 4 | `launchctl disable gui/$UID/com.apple.SoftwareUpdateNotificationManager` + `pkill -9` | 停用更新通知代理，不再弹「有可用更新」、不再点亮角标 |
| 5 | 删除通知计数，清空 `AttentionPrefBundleIDs`，`killall Dock` | 清掉 Dock / 系统设置图标上的小红点 |
| 6 | `--with-hosts` 时向 `/etc/hosts` 追加更新域名 | 让更新检查直接失败，彻底看不到新版本 |
| 7 | 打印 `status` 与后续提示 | — |

`restore` 反向执行：还原配置快照 → 按快照恢复自动检查开关 → 重新启用通知代理 → 移除 hosts 屏蔽 → 清缓存并重启守护进程。

## 关于「小红点」

更新小红点通常来自两层：

1. **通知计数**：`~/Library/Preferences/com.apple.SoftwareUpdate.plist` 里的 `AvailableUpdatesNotificationCountKey`，对应「有可用更新」提醒；
2. **系统设置角标**：`com.apple.systempreferences` 的 `AttentionPrefBundleIDs`，其中 `com.apple.FollowUpSettings.FollowUpSettingsExtension` 就是「升级到新版本 macOS」的跟进提醒。

脚本会同时清掉这两层。注意下面几个容易踩的点：

- **通知代理忽略 SIGTERM**：`SoftwareUpdateNotificationManager` 收到 `kill`（默认 SIGTERM）不会退出，必须 `kill -9`。脚本已用 SIGKILL；如果你手动清理，记得加 `-9`。
- **打开「软件更新」面板会重新点亮角标**：这个面板每次打开都会强制扫描一次，扫到新版本就把 FollowUp 角标写回去（哪怕自动检查已关闭）。所以清完角标后，尽量不要去点「系统设置 → 通用 → 软件更新」；真点了，再跑一次 `badge` 即可。
- 只要系统还能扫到新版本，跟进提醒**可能再次生成**——想在源头上让它看不到更新，用 `--with-hosts` 或下面的「延迟更新描述文件」。
- 某些 macOS 版本上 `AutomaticCheckEnabled` 会被 `softwareupdated` 当成 legacy 键清掉；脚本会校验并重试，若仍被改回会明确提示。

## 风险与建议

- `--with-hosts` 会**连 Safari、安全补丁一起屏蔽**，`softwareupdate --list` 也会卡住/超时。除非你确定这台机器不打算再更新，否则建议只用默认模式（保留「手动检查」能力）。
- 关闭自动更新 ≠ 不需要安全补丁。建议每隔一两个月手动看一眼：
  ```bash
  softwareupdate --list
  sudo softwareupdate -i -a --restart=never
  ```
  如果只想装安全补丁、不想升大版本，可以只装 Safari 和系统小版本对应的条目。
- 跨大版本升级（例如从 15 升到 26/27）建议自己找时间手动做，别让它半夜自动装。

## 备份文件

```
backups/
├── pre-disable.plist                     # 首次 disable 时的原始快照，restore 优先使用
├── com.apple.SoftwareUpdate.plist.<时间> # 每次 disable 的历史快照
├── schedule.<时间>.txt                   # 当时的自动检查状态
└── hosts.<时间>.bak                      # 修改 /etc/hosts 前的备份
```

`restore` 会优先用 `pre-disable.plist`，这样即使你执行过多次 `disable`，也能回到最初状态。想重新取快照，删掉它再跑 `disable` 即可：

```bash
rm backups/pre-disable.plist
```

`backups/` 已在 `.gitignore` 中，不会被提交。

## 手动操作（不想跑脚本时）

```bash
# 备份
sudo cp -p /Library/Preferences/com.apple.SoftwareUpdate.plist ~/Desktop/

# 关闭
sudo softwareupdate --schedule off
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false
sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
launchctl disable gui/$(id -u)/com.apple.SoftwareUpdateNotificationManager
defaults delete com.apple.SoftwareUpdate AvailableUpdatesNotificationCountKey
defaults delete com.apple.systempreferences AttentionPrefBundleIDs
sudo pkill -x softwareupdated
killall Dock

# 恢复
sudo defaults import /Library/Preferences/com.apple.SoftwareUpdate ~/Desktop/com.apple.SoftwareUpdate.plist
sudo softwareupdate --schedule on
launchctl enable gui/$(id -u)/com.apple.SoftwareUpdateNotificationManager
```

## 兼容性

- 在 **macOS 15.7.3 (24G419)** 上按实际系统路径与 LaunchAgent 校验过（`status` 与 `--dry-run`）。
- `launchctl disable` 只对当前登录用户生效；多用户机器上每位用户需要各自执行，或把脚本放进登录项。
- `com.apple.SoftwareUpdateNotificationManager` 存在于 macOS 13+；在更老的系统上这一步会提示失败但不会中断，`status` 里会显示「未加载」。

## 另一种思路：只延迟、不屏蔽

企业常用的做法是安装一个 `com.apple.applicationaccess` 配置描述文件，用 `forceDelayedSoftwareUpdates` + `enforcedSoftwareUpdateDelay`（如 90 天）让新更新**在延迟期内不可见**，到期后仍会出现——这样红点自然消失，又不会永久错过安全补丁。需要时可以用 `profiles install -path xxx.mobileconfig` 安装，`profiles remove` 卸载。本脚本没有内置这一方式，因为它需要一个单独的 `.mobileconfig` 文件。
