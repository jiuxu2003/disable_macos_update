#!/usr/bin/env bash
#
# disable_macos_update.sh
#
# 关闭 macOS 的「自动检查 / 自动下载 / 自动安装更新」，停用更新通知代理，
# 并清掉 Dock / 系统设置上的更新小红点；同时提供一键恢复。
#
# 用法:
#   ./disable_macos_update.sh status                       # 查看当前状态（只读）
#   ./disable_macos_update.sh disable                      # 关闭更新（保留手动检查）
#   ./disable_macos_update.sh disable --with-hosts         # 关闭更新 + 屏蔽更新服务器
#   ./disable_macos_update.sh restore                      # 恢复更新
#   ./disable_macos_update.sh disable --dry-run            # 只打印将要执行的操作
#
# 说明见 README.md。脚本需要管理员权限，会按需调用 sudo，请不要直接用 sudo 运行。

set -euo pipefail

readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly BACKUP_DIR="$SCRIPT_DIR/backups"

# 系统级软件更新偏好（/Library/Preferences/com.apple.SoftwareUpdate.plist）
readonly SU_DOMAIN="/Library/Preferences/com.apple.SoftwareUpdate"
readonly SU_PLIST="$SU_DOMAIN.plist"

# 首次执行 disable 时保存的原始快照；restore 优先用它，保证重复 disable 后仍能回到最初状态
readonly PRE_DISABLE="$BACKUP_DIR/pre-disable.plist"

# 每用户的通知计数（~/Library/Preferences/com.apple.SoftwareUpdate.plist）
readonly SU_USER_DOMAIN="$HOME/Library/Preferences/com.apple.SoftwareUpdate"

# 系统设置 / Dock 角标（System Settings 是沙盒应用，用绝对路径可绕开容器重定向）
readonly SP_DOMAIN="$HOME/Library/Preferences/com.apple.systempreferences"

readonly HOSTS_FILE="/etc/hosts"
readonly MARK_BEGIN="# >>> disable_macos_update >>>"
readonly MARK_END="# <<< disable_macos_update <<<"

readonly AGENT_LABEL="com.apple.SoftwareUpdateNotificationManager"
readonly AGENT_PLIST="/System/Library/LaunchAgents/$AGENT_LABEL.plist"

DRY_RUN=0
WITH_HOSTS=0

# ---------------------------------------------------------------- 输出样式

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
else
  C_RESET="" C_BOLD="" C_BLUE="" C_GREEN="" C_YELLOW="" C_RED=""
fi

step()  { printf '\n%s==> %s%s\n' "$C_BLUE$C_BOLD" "$*" "$C_RESET"; }
ok()    { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
info()  { printf '  · %s\n' "$*"; }
die()   { printf '%s错误:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
$SCRIPT_NAME — 关闭 / 恢复 macOS 自动更新与更新小红点

用法:
  $SCRIPT_NAME status                    查看当前状态（只读，不需要 sudo）
  $SCRIPT_NAME disable                   关闭自动检查 / 自动下载 / 自动安装 + 更新通知
  $SCRIPT_NAME disable --with-hosts      同上，并额外在 /etc/hosts 屏蔽更新服务器
  $SCRIPT_NAME restore                   恢复自动更新（从 backups/ 中的备份还原）
  $SCRIPT_NAME badge                     只清红点（不需要 sudo，不改更新设置）
  $SCRIPT_NAME disable --dry-run         只打印将要执行的命令，不做任何修改

选项:
  --with-hosts   同时屏蔽 swscan/swdist/swcdn/mesu/gdmf 等更新域名（restore 会自动解除）
  -n, --dry-run  演练模式，不真正修改系统
  -h, --help     显示本帮助

备份:
  每次 disable 都会把原配置保存到 $BACKUP_DIR/
  restore 会自动使用最近一次备份。
EOF
}

# ---------------------------------------------------------------- 基础工具

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "此脚本仅支持 macOS。"
  command -v softwareupdate >/dev/null 2>&1 || die "找不到 softwareupdate，这不是正常的 macOS 环境。"
}

preflight() {
  [[ $EUID -eq 0 ]] && die "请不要用 sudo / root 直接运行，脚本会在需要时自己调用 sudo。"
  command -v sudo >/dev/null 2>&1 || die "找不到 sudo。"
  (( DRY_RUN )) && return 0
  printf '需要管理员权限，请输入密码：\n'
  sudo -v || die "获取管理员权限失败。"
}

# 以当前用户身份执行；dry-run 时只打印
run() {
  if (( DRY_RUN )); then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

# 以 root 身份执行；dry-run 时只打印
as_root() {
  if (( DRY_RUN )); then
    printf '  [dry-run] sudo %s\n' "$*"
    return 0
  fi
  sudo "$@"
}

# 读取系统级偏好里的一个键，不存在时返回空
su_get() {
  defaults read "$SU_DOMAIN" "$1" 2>/dev/null || true
}

bool_zh() {
  case "${1:-}" in
    1|true|TRUE|yes|YES) printf '开启' ;;
    0|false|FALSE|no|NO) printf '关闭' ;;
    "")                  printf '未设置' ;;
    *)                   printf '%s' "$1" ;;
  esac
}

# 估算字符串在终端里的显示宽度，CJK 字符按 2 列计算，用于对齐状态表
disp_width() {
  local s="$1" chars bytes
  chars="$(printf '%s' "$s" | LC_ALL=en_US.UTF-8 wc -m | tr -d '[:space:]')"
  bytes="$(printf '%s' "$s" | LC_ALL=en_US.UTF-8 wc -c | tr -d '[:space:]')"
  printf '%d' $(( chars + (bytes - chars) / 2 ))
}

row() {
  local label="$1" value="$2" pad
  pad=$(( 24 - $(disp_width "$label") ))
  (( pad < 1 )) && pad=1
  printf '  %s%*s  %s\n' "$label" "$pad" "" "$value"
}

agent_disabled() {
  launchctl print-disabled "gui/$UID" 2>/dev/null \
    | grep -F "\"$AGENT_LABEL\" => disabled" >/dev/null 2>&1
}

agent_loaded() {
  launchctl print "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1
}

# 复制文件到备份目录，并把属主还给当前用户（否则 sudo 复制出来的文件属于 root）
backup_copy() {
  local src="$1" dst="$2"
  as_root cp -p "$src" "$dst"
  as_root chown "$(id -u):$(id -g)" "$dst"
  as_root chmod 644 "$dst"
}

hosts_blocked() {
  [[ -f "$HOSTS_FILE" ]] && grep -Fq "$MARK_BEGIN" "$HOSTS_FILE" 2>/dev/null
}

ensure_backup_dir() {
  if (( DRY_RUN )); then
    printf '  [dry-run] mkdir -p %s\n' "$BACKUP_DIR"
    return 0
  fi
  mkdir -p "$BACKUP_DIR"
}

# ---------------------------------------------------------------- 偏好写入

write_su_prefs() {
  as_root defaults write "$SU_DOMAIN" AutomaticCheckEnabled -bool false
  as_root defaults write "$SU_DOMAIN" AutomaticDownload -bool false
  as_root defaults write "$SU_DOMAIN" AutomaticallyInstallMacOSUpdates -bool false
  as_root defaults write "$SU_DOMAIN" CriticalUpdateInstall -bool false
  as_root defaults write "$SU_DOMAIN" ConfigDataInstall -bool false
}

su_prefs_ok() {
  local k v
  for k in AutomaticCheckEnabled AutomaticDownload AutomaticallyInstallMacOSUpdates \
           CriticalUpdateInstall ConfigDataInstall; do
    v="$(su_get "$k")"
    [[ "$v" == "0" ]] || return 1
  done
  return 0
}

# 写偏好并校验；softwareupdated 可能用旧的内存缓存回写，所以失败会重试
apply_su_prefs() {
  local i
  if (( DRY_RUN )); then
    write_su_prefs
    return 0
  fi
  for i in 1 2 3; do
    write_su_prefs
    sleep 1
    su_prefs_ok && return 0
  done
  return 1
}

# 重启两个 softwareupdated，让它们丢掉旧缓存、重新从磁盘读偏好
restart_su_daemons() {
  if (( DRY_RUN )); then
    printf '  [dry-run] sudo launchctl kickstart -k system/com.apple.softwareupdated\n'
    printf '  [dry-run] sudo launchctl kickstart -k system/com.apple.mobile.softwareupdated\n'
    return 0
  fi
  sudo launchctl kickstart -k system/com.apple.softwareupdated 2>/dev/null \
    || sudo pkill -9 -f 'Software Update.app/Contents/Resources/softwareupdated' 2>/dev/null \
    || true
  sudo launchctl kickstart -k system/com.apple.mobile.softwareupdated 2>/dev/null || true
}

# ---------------------------------------------------------------- 红点清理

clear_badges() {
  local key
  for key in AvailableUpdatesNotificationCountKey \
             AvailableUpdatesNotificationProductKey \
             UserNotificationDate; do
    if (( DRY_RUN )); then
      printf '  [dry-run] defaults delete %s %s\n' "$SU_USER_DOMAIN" "$key"
    else
      defaults delete "$SU_USER_DOMAIN" "$key" 2>/dev/null || true
    fi
  done

  if (( DRY_RUN )); then
    printf '  [dry-run] defaults delete %s AttentionPrefBundleIDs\n' "$SP_DOMAIN"
    printf '  [dry-run] killall Dock\n'
    return 0
  fi

  # 清掉「系统设置」图标上的角标（FollowUpSettings / 软件更新提醒）
  defaults delete "$SP_DOMAIN" AttentionPrefBundleIDs 2>/dev/null || true
  killall Dock 2>/dev/null || true
  # 若系统设置正开着，关掉让它重新读取角标（避免使用 osascript 触发自动化授权弹窗）
  killall "System Settings" 2>/dev/null || true
}

# ---------------------------------------------------------------- hosts 屏蔽

hosts_apply() {
  local ts="$1"

  if (( DRY_RUN )); then
    printf '  [dry-run] sudo cp -p %s %s/hosts.%s.bak && sudo chown %s:%s ... && sudo chmod 644 ...\n' \
      "$HOSTS_FILE" "$BACKUP_DIR" "$ts" "$(id -u)" "$(id -g)"
    printf '  [dry-run] 向 %s 追加以下条目:\n' "$HOSTS_FILE"
    printf '      127.0.0.1 swscan.apple.com\n'
    printf '      127.0.0.1 swdist.apple.com\n'
    printf '      127.0.0.1 swcdn.apple.com\n'
    printf '      127.0.0.1 swdownload.apple.com\n'
    printf '      127.0.0.1 gdmf.apple.com\n'
    printf '      127.0.0.1 mesu.apple.com\n'
    printf '      127.0.0.1 updates.cdn-apple.com\n'
    printf '      127.0.0.1 updates-http.cdn-apple.com\n'
    printf '  [dry-run] sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder\n'
    return 0
  fi

  backup_copy "$HOSTS_FILE" "$BACKUP_DIR/hosts.$ts.bak"

  # 若已有旧区块，先移除，避免重复追加
  if hosts_blocked; then
    hosts_remove_quiet
  fi

  sudo tee -a "$HOSTS_FILE" >/dev/null <<EOF

$MARK_BEGIN
127.0.0.1 swscan.apple.com
127.0.0.1 swdist.apple.com
127.0.0.1 swcdn.apple.com
127.0.0.1 swdownload.apple.com
127.0.0.1 gdmf.apple.com
127.0.0.1 mesu.apple.com
127.0.0.1 updates.cdn-apple.com
127.0.0.1 updates-http.cdn-apple.com
$MARK_END
EOF

  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

hosts_remove_quiet() {
  local tmp
  tmp="$(mktemp /tmp/disable_macos_update.hosts.XXXXXX)"
  sudo awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$HOSTS_FILE" >"$tmp"
  sudo cp "$tmp" "$HOSTS_FILE"
  rm -f "$tmp"
}

hosts_remove() {
  if (( DRY_RUN )); then
    printf '  [dry-run] 从 %s 删除 %s 到 %s 之间的条目\n' "$HOSTS_FILE" "$MARK_BEGIN" "$MARK_END"
    printf '  [dry-run] sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder\n'
    return 0
  fi
  hosts_remove_quiet
  sudo dscacheutil -flushcache 2>/dev/null || true
  sudo killall -HUP mDNSResponder 2>/dev/null || true
}

# ---------------------------------------------------------------- 状态

cmd_status() {
  require_macos

  local os_ver build sched auto_check auto_download auto_install critical config_data
  local agent_state badge notice_count backup_count snapshot pending

  os_ver="$(sw_vers -productVersion 2>/dev/null || echo '?')"
  build="$(sw_vers -buildVersion 2>/dev/null || echo '?')"

  sched="$(softwareupdate --schedule 2>&1 | tail -n 1 || true)"
  case "$sched" in
    *"turned on"*)  sched="开启" ;;
    *"turned off"*) sched="关闭" ;;
  esac

  auto_check="$(su_get AutomaticCheckEnabled)"
  auto_download="$(su_get AutomaticDownload)"
  auto_install="$(su_get AutomaticallyInstallMacOSUpdates)"
  critical="$(su_get CriticalUpdateInstall)"
  config_data="$(su_get ConfigDataInstall)"

  # 统计上次扫描到的更新条目数（该数组由 softwareupdated 维护）
  pending="未知"
  if [[ -f "$SU_PLIST" ]]; then
    pending="$(/usr/libexec/PlistBuddy -c 'Print :RecommendedUpdates' "$SU_PLIST" 2>/dev/null | grep -c 'Product Key' || true)"
  fi

  if agent_disabled; then
    agent_state="已停用（launchctl disabled）"
  elif agent_loaded; then
    agent_state="运行中"
  else
    agent_state="未加载"
  fi

  badge="$(defaults read "$SP_DOMAIN" AttentionPrefBundleIDs 2>/dev/null || true)"

  notice_count="$(defaults read "$SU_USER_DOMAIN" AvailableUpdatesNotificationCountKey 2>/dev/null || true)"

  backup_count=0
  if [[ -d "$BACKUP_DIR" ]]; then
    backup_count="$(find "$BACKUP_DIR" -maxdepth 1 -name 'com.apple.SoftwareUpdate.plist.*' 2>/dev/null | wc -l | tr -d ' ')"
  fi

  if [[ -f "$PRE_DISABLE" ]]; then
    snapshot="有（backups/pre-disable.plist）"
  else
    snapshot="无"
  fi

  printf '%s%s%s\n' "$C_BOLD" "macOS 更新状态" "$C_RESET"
  row "系统版本" "$os_ver ($build)"
  row "自动检查更新" "$sched"
  row "AutomaticCheckEnabled" "$(bool_zh "$auto_check")"
  row "AutomaticDownload" "$(bool_zh "$auto_download")"
  row "自动安装系统更新" "$(bool_zh "$auto_install")"
  row "CriticalUpdateInstall" "$(bool_zh "$critical")"
  row "ConfigDataInstall" "$(bool_zh "$config_data")"
  row "更新通知代理" "$agent_state"
  row "待处理通知计数" "${notice_count:-无}"
  row "系统设置角标" "${badge:-无}"
  row "hosts 屏蔽更新" "$(hosts_blocked && echo '是' || echo '否')"
  row "扫描到的更新项" "${pending:-未知}"
  row "原始快照" "$snapshot"
  row "历史快照数" "$backup_count"

  if [[ "$sched" == "开启" && -z "$auto_check" ]]; then
    printf '\n  %s提示:%s AutomaticCheckEnabled 键缺失，但计划任务仍在扫描；执行 disable 会显式写入该键。\n' \
      "$C_YELLOW" "$C_RESET"
  fi
  if [[ -n "$badge" && "$badge" != "0" ]]; then
    printf '  %s提示:%s 检测到系统设置角标，执行 disable 可清除。\n' "$C_YELLOW" "$C_RESET"
  fi
}

# ---------------------------------------------------------------- 只清红点

cmd_badge() {
  require_macos

  step "清除更新通知与小红点"

  if (( DRY_RUN )); then
    printf '  [dry-run] defaults delete %s AttentionPrefBundleIDs\n' "$SP_DOMAIN"
    printf '  [dry-run] defaults delete %s AvailableUpdatesNotificationCountKey\n' "$SU_USER_DOMAIN"
    printf '  [dry-run] killall Dock && killall "System Settings"\n'
    return 0
  fi

  defaults delete "$SP_DOMAIN" AttentionPrefBundleIDs 2>/dev/null || true
  defaults delete "$SU_USER_DOMAIN" AvailableUpdatesNotificationCountKey 2>/dev/null || true
  defaults delete "$SU_USER_DOMAIN" AvailableUpdatesNotificationProductKey 2>/dev/null || true
  defaults delete "$SU_USER_DOMAIN" UserNotificationDate 2>/dev/null || true

  killall "System Settings" 2>/dev/null || true
  killall Dock 2>/dev/null || true

  ok "角标已清除"
  info "注意：只要系统还看得到新版本，打开「系统设置 → 通用 → 软件更新」会重新扫描并可能再次点亮红点"
}

# ---------------------------------------------------------------- 关闭更新

cmd_disable() {
  require_macos
  preflight
  ensure_backup_dir

  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  step "1/7 备份当前配置"
  if [[ -f "$SU_PLIST" ]]; then
    # 原始快照只保留第一份，重复执行 disable 不会把它覆盖成「已禁用」状态
    if [[ -f "$PRE_DISABLE" ]]; then
      info "已有原始快照 backups/pre-disable.plist，保留不动"
    else
      backup_copy "$SU_PLIST" "$PRE_DISABLE"
      ok "已保存原始快照: backups/pre-disable.plist"
    fi
    backup_copy "$SU_PLIST" "$BACKUP_DIR/com.apple.SoftwareUpdate.plist.$ts"
    info "本次快照: backups/com.apple.SoftwareUpdate.plist.$ts"
  else
    warn "$SU_PLIST 不存在，跳过备份（restore 时会回落到系统默认值）"
  fi
  if (( ! DRY_RUN )); then
    softwareupdate --schedule >"$BACKUP_DIR/schedule.$ts.txt" 2>&1 || true
  else
    printf '  [dry-run] 记录当前 softwareupdate --schedule 状态\n'
  fi

  step "2/7 关闭自动检查 / 自动下载 / 自动安装"
  as_root softwareupdate --schedule off || warn "softwareupdate --schedule 不可用，仅写入偏好键"
  if apply_su_prefs; then
    ok "已写入 AutomaticCheckEnabled / AutomaticDownload / 自动安装等开关 = false"
  else
    warn "偏好未能全部写入，继续执行后续步骤"
  fi

  step "3/7 重启更新守护进程（清掉旧的内存缓存）"
  restart_su_daemons
  if (( ! DRY_RUN )); then
    # 守护进程重启后再写一次并校验，防止它用旧缓存把配置回写掉
    if apply_su_prefs; then
      ok "守护进程已重启，偏好校验通过"
    else
      warn "偏好仍被系统改回，可能需要改用 --with-hosts 或延迟更新描述文件"
    fi
  else
    ok "守护进程已重启"
  fi

  step "4/7 停用更新通知代理"
  run launchctl disable "gui/$UID/$AGENT_LABEL" || warn "launchctl disable 失败（可能已被停用）"
  if (( ! DRY_RUN )); then
    launchctl bootout "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
    # 这个进程会忽略 SIGTERM，必须 -9 才能停掉
    pkill -9 -f 'SoftwareUpdateNotificationManager' 2>/dev/null || true
  fi
  ok "已停用 $AGENT_LABEL"

  step "5/7 清除通知计数与小红点"
  clear_badges
  ok "已清除通知计数与系统设置角标"

  step "6/7 屏蔽更新服务器（可选）"
  if (( WITH_HOSTS )); then
    hosts_apply "$ts"
    ok "已在 /etc/hosts 屏蔽更新域名（原文件备份为 backups/hosts.$ts.bak）"
    warn "屏蔽后将完全看不到任何更新，包括 Safari / 安全补丁"
  else
    info "未启用（需要时在命令后加 --with-hosts）"
  fi

  step "7/7 完成"
  if (( DRY_RUN )); then
    warn "演练模式，未做任何修改"
    return 0
  fi
  cmd_status
  printf '\n%s完成。%s想临时更新时：系统设置 → 通用 → 软件更新，或 %ssudo softwareupdate -i -a%s。\n' \
    "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
  printf '恢复：%s%s restore%s\n' "$C_BOLD" "$SCRIPT_NAME" "$C_RESET"
}

# ---------------------------------------------------------------- 恢复更新

cmd_restore() {
  require_macos
  preflight
  ensure_backup_dir

  step "1/6 恢复软件更新偏好"
  local latest=""
  if [[ -f "$PRE_DISABLE" ]]; then
    latest="$PRE_DISABLE"
  else
    latest="$(ls -1t "$BACKUP_DIR"/com.apple.SoftwareUpdate.plist.* 2>/dev/null | head -n 1 || true)"
  fi

  if [[ -n "$latest" && -f "$latest" ]]; then
    as_root defaults import "$SU_DOMAIN" "$latest"
    ok "已从 backups/$(basename -- "$latest") 还原"
  else
    warn "没有找到备份，按系统默认值恢复"
    as_root defaults write "$SU_DOMAIN" AutomaticCheckEnabled -bool true
    as_root defaults write "$SU_DOMAIN" AutomaticDownload -bool true
    as_root defaults write "$SU_DOMAIN" AutomaticallyInstallMacOSUpdates -bool false
    as_root defaults write "$SU_DOMAIN" CriticalUpdateInstall -bool true
    as_root defaults write "$SU_DOMAIN" ConfigDataInstall -bool true
  fi

  step "2/6 同步「自动检查」计划任务"
  local auto_check="1"
  if (( ! DRY_RUN )); then
    auto_check="$(defaults read "$SU_DOMAIN" AutomaticCheckEnabled 2>/dev/null || echo 1)"
  fi
  if [[ "$auto_check" == "0" ]]; then
    as_root softwareupdate --schedule off || warn "softwareupdate --schedule 不可用，仅恢复偏好键"
    info "备份中自动检查为关闭，保持关闭"
  else
    as_root softwareupdate --schedule on || warn "softwareupdate --schedule 不可用，仅恢复偏好键"
    info "自动检查已重新开启"
  fi

  step "3/6 恢复更新通知代理"
  if (( DRY_RUN )); then
    printf '  [dry-run] launchctl enable gui/%s/%s\n' "$UID" "$AGENT_LABEL"
    printf '  [dry-run] launchctl bootstrap gui/%s %s\n' "$UID" "$AGENT_PLIST"
    printf '  [dry-run] launchctl kickstart -k gui/%s/%s\n' "$UID" "$AGENT_LABEL"
  else
    launchctl enable "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$UID" "$AGENT_PLIST" 2>/dev/null || true
    launchctl kickstart -k "gui/$UID/$AGENT_LABEL" 2>/dev/null || true
    if agent_disabled; then
      warn "通知代理仍未启用，可尝试注销后重新登录"
    else
      ok "通知代理已恢复"
    fi
  fi

  step "4/6 解除 hosts 屏蔽"
  if hosts_blocked; then
    hosts_remove
    ok "已移除 /etc/hosts 中的屏蔽条目"
  else
    info "未发现屏蔽条目，跳过"
  fi

  step "5/6 清理更新缓存并重启守护进程"
  if (( DRY_RUN )); then
    printf '  [dry-run] rm -rf %s/Library/Caches/com.apple.SoftwareUpdate\n' "$HOME"
    printf '  [dry-run] sudo pkill -x softwareupdated\n'
  else
    rm -rf "$HOME/Library/Caches/com.apple.SoftwareUpdate" 2>/dev/null || true
    sudo pkill -x softwareupdated 2>/dev/null || true
  fi
  ok "完成"

  step "6/6 完成"
  if (( DRY_RUN )); then
    warn "演练模式，未做任何修改"
    return 0
  fi
  cmd_status
  printf '\n%s已恢复自动更新。%s首次扫描可能需要几秒到几分钟，红点会在扫描结束后重新出现。\n' \
    "$C_GREEN" "$C_RESET"
}

# ---------------------------------------------------------------- 入口

main() {
  local action=""

  while (( $# )); do
    case "$1" in
      disable|restore|status|badge) action="$1" ;;
      --with-hosts)  WITH_HOSTS=1 ;;
      -n|--dry-run)  DRY_RUN=1 ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "未知参数: $1（使用 --help 查看用法）" ;;
    esac
    shift
  done

  if [[ -z "$action" ]]; then
    usage
    exit 1
  fi

  if (( WITH_HOSTS )) && [[ "$action" != "disable" ]]; then
    die "--with-hosts 只能与 disable 一起使用（restore 会自动解除屏蔽）"
  fi

  case "$action" in
    status)  cmd_status ;;
    disable) cmd_disable ;;
    restore) cmd_restore ;;
    badge)   cmd_badge ;;
  esac
}

main "$@"
