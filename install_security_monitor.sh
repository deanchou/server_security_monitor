#!/usr/bin/env bash
# ============================================================================
#  安全巡检系统交互式安装脚本 (Linux)
#
#  ⚠️ 若运行时报错: $'\r': command not found 或 set: pipefail: invalid option
#     说明脚本被转成了 Windows 换行(CRLF), 请先执行一次修复:
#       sed -i 's/\r$//' install_security_monitor.sh   # 或: dos2unix install_security_monitor.sh
#     修复后重新运行即可。
#     避免方法: 用 scp 传输(勿复制粘贴/勿用记事本编辑/勿用 WinSCP 文本模式上传)
#
#  组件 (可多选):
#    [1] Fail2ban      - 暴力破解自动封禁 + 告警
#    [2] auditd        - 登录/账户/命令审计 + 可疑事件实时告警
#    [3] Wazuh Agent   - 上报到已有的 Wazuh manager
#    [4] Wazuh 全套    - 本机部署 manager+indexer+dashboard (需 >=4G 内存)
#    [5] 每日巡检日报   - 每天 08:00 推送安全摘要
#    [6] 资源监控      - CPU/内存/磁盘/负载 超阈值实时告警
#    [7] 时区修改      - 设置系统时区 (上海/北京/巴基斯坦/印尼首都雅加达)
#
#  告警渠道 (可多选): 钉钉 / 企业微信 / Telegram / 邮件
#
#  用法:
#    交互式:  sudo bash install_security_monitor.sh
#    自动式:  sudo bash install_security_monitor.sh --auto
#             (自动模式使用下方默认值 + 环境变量覆盖, 不询问)
#    卸载:    sudo bash install_security_monitor.sh --uninstall
#             (交互式选择要清理的组件, 可仅删配置或连包一起卸载)
#
#  适用系统: CentOS/RHEL/Rocky/Alma 7-9, Ubuntu 18.04-24.04, Debian 10-13
#  需以 root 运行
# ============================================================================

set -euo pipefail

# ============================ 默认值配置区 ==================================
# 说明: 交互模式会逐一询问, 环境变量/此处的值作为"默认值"预填
# 自动模式(--auto)直接使用 环境变量 > 此处默认值

# 告警渠道: dingtalk, wechat, telegram, email (逗号分隔, 空=不配置)
ALERT_CHANNELS="${ALERT_CHANNELS:-}"

# 钉钉 (钉钉群 -> 群设置 -> 机器人 -> 添加自定义机器人)
DINGTALK_WEBHOOK="${DINGTALK_WEBHOOK:-}"   # 例: https://oapi.dingtalk.com/robot/send?access_token=xxx
DINGTALK_SECRET="${DINGTALK_SECRET:-}"     # 加签密钥, 可留空

# 企业微信
WECHAT_WEBHOOK="${WECHAT_WEBHOOK:-}"       # 例: https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxx

# Telegram (找 @BotFather 创建 Bot, 向 @userinfobot 获取 chat id)
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

# 邮件 SMTP
EMAIL_TO="${EMAIL_TO:-}"
SMTP_SERVER="${SMTP_SERVER:-}"             # 例: smtp.example.com:587
SMTP_USER="${SMTP_USER:-}"
SMTP_PASS="${SMTP_PASS:-}"
SMTP_FROM="${SMTP_FROM:-}"

# Wazuh
WAZUH_VERSION="${WAZUH_VERSION:-}"             # 空=自动在线检测最新版; 也可指定如 4.9
WAZUH_VERSION_DEFAULT="4.14"                     # 在线检测失败时的兜底版本
WAZUH_DASHBOARD_PORT="${WAZUH_DASHBOARD_PORT:-443}" # Web 控制台端口(若被占用自动改 8443)
WAZUH_MANAGER_ADDR="${WAZUH_MANAGER_ADDR:-}" # agent 模式: manager 服务器 IP/域名
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname)}"
WAZUH_ALERT_LEVEL="${WAZUH_ALERT_LEVEL:-10}" # Wazuh 告警阈值(>=该级别推送)

# Fail2ban
F2B_MAXRETRY="${F2B_MAXRETRY:-5}"          # 窗口内失败次数
F2B_FINDTIME="${F2B_FINDTIME:-10m}"        # 统计窗口
F2B_BANTIME="${F2B_BANTIME:-1h}"           # 封禁时长
F2B_IGNOREIP="${F2B_IGNOREIP:-127.0.0.1}"  # 白名单(空格分隔)
F2B_SSH_PORT="${F2B_SSH_PORT:-}"           # SSH 端口(空=自动探测, 支持多端口空格分隔)

# auditd
AUDIT_EXECVE="${AUDIT_EXECVE:-yes}"        # 是否审计全部命令(日志量大)

# 资源监控 (CPU/内存/磁盘/负载 超阈值告警)
RES_INTERVAL="${RES_INTERVAL:-300}"        # 检查间隔(秒, 默认300=5分钟)
RES_COOLDOWN="${RES_COOLDOWN:-1800}"       # 同一指标重复告警冷却(秒, 默认1800=30分钟)
RES_CPU_WARN="${RES_CPU_WARN:-80}";  RES_CPU_CRIT="${RES_CPU_CRIT:-90}"
RES_MEM_WARN="${RES_MEM_WARN:-80}";  RES_MEM_CRIT="${RES_MEM_CRIT:-90}"
RES_DISK_WARN="${RES_DISK_WARN:-80}"; RES_DISK_CRIT="${RES_DISK_CRIT:-90}"
RES_LOAD_WARN="${RES_LOAD_WARN:-}"        # 空=自动取 CPU 核数
RES_LOAD_CRIT="${RES_LOAD_CRIT:-}"         # 空=自动取 CPU 核数*2
RES_DISK_IGNORE="${RES_DISK_IGNORE:-}"    # 忽略挂载点(逗号分隔, 如 /snap,/mnt/backup)
# ============================ 默认值配置区结束 ==============================

# 安装开关 (交互模式选择后设置, 自动模式默认全关, 由环境变量开启)
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-no}"
INSTALL_AUDITD="${INSTALL_AUDITD:-no}"
INSTALL_WAZUH="${INSTALL_WAZUH:-none}"    # none / agent / full
INSTALL_DAILY="${INSTALL_DAILY:-no}"
INSTALL_RESOURCE_MONITOR="${INSTALL_RESOURCE_MONITOR:-no}"
INSTALL_TIMEZONE="${INSTALL_TIMEZONE:-no}"
# 时区 (仅 INSTALL_TIMEZONE=yes 时生效): 上海/北京/巴基斯坦/印度尼西亚(首都)
#   自动模式直接填: TIMEZONE=Asia/Shanghai | Asia/Karachi | Asia/Jakarta 或 中文名
TIMEZONE="${TIMEZONE:-}"

# ============================== 工具函数 ====================================
C_GREEN="\033[1;32m"; C_YELLOW="\033[1;33m"; C_RED="\033[1;31m"; C_CYAN="\033[1;36m"; C_OFF="\033[0m"
log()  { echo -e "${C_GREEN}[+]${C_OFF} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_OFF} $*"; }
err()  { echo -e "${C_RED}[-]${C_OFF} $*"; }
die()  { err "$*"; SKIP_ERR_TRAP=1; exit 1; }
trap 'if [ "${SKIP_ERR_TRAP:-0}" != 1 ]; then err "脚本在第 ${LINENO} 行出错, 请检查上面的输出"; fi' ERR

banner() {
  echo ""
  echo -e "${C_CYAN}==============================================================${C_OFF}"
  echo -e "${C_CYAN}  安全巡检系统一键部署 (Fail2ban + auditd + Wazuh + 多渠道告警)${C_OFF}"
  echo -e "${C_CYAN}==============================================================${C_OFF}"
}

# 提问: prompt <变量名> <提示语> <默认值> [--secret]
prompt() {
  local var="$1" msg="$2" def="$3" val
  if [ "${4:-}" = "--secret" ]; then
    printf "%s [%s]: " "$msg" "${def:+已设置(回车保留)}"
    if ! read -r -s val; then echo ""; die "输入已中断 (EOF), 安装取消"; fi
    echo ""
  else
    printf "%s [%s]: " "$msg" "$def"
    if ! read -r val; then echo ""; die "输入已中断 (EOF), 安装取消"; fi
  fi
  val="${val:-$def}"
  printf -v "$var" '%s' "$val"
}

# 多选: choose <标题> <结果变量> <允许0> <回车默认值> <默认值显示文本> "编号|描述" ...
#   <回车默认值>    : 用户直接回车时写入变量的值 (可为空)
#   <默认值显示文本>: 提示行 "直接回车=XXX" 中的 XXX, 让用户明确回车后果
choose() {
  local title="$1" var="$2" allow0="$3" def="$4" defdisp="$5"; shift 5
  local opt ans
  echo ""
  echo -e "${C_CYAN}$title${C_OFF}"
  for opt in "$@"; do
    echo "    ${opt%%|*} ) ${opt#*|}"
  done
  [ "$allow0" = "yes" ] && echo "    0 ) 不配置/跳过"
  if [ -n "$defdisp" ]; then
    printf "  请输入编号(逗号分隔多选, 直接回车=%s): " "$defdisp"
  else
    printf "  请输入编号(逗号分隔多选): "
  fi
  if ! read -r ans; then echo ""; die "输入已中断 (EOF), 安装取消"; fi
  printf -v "$var" '%s' "${ans:-$def}"
}

confirm() { # confirm <提示语>
  local ans
  printf "%s [Y/n]: " "$1"
  if ! read -r ans; then echo ""; return 1; fi
  case "$ans" in ""|y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请以 root 运行: sudo bash $0"
}

detect_os() {
  if [ -f /etc/os-release ]; then . /etc/os-release; else ID="linux"; fi
  case "$ID" in
    ubuntu|debian)        PKG="apt";  INST="DEBIAN_FRONTEND=noninteractive apt-get install -y"; UPDATE="apt-get update -y" ;;
    centos|rhel|rocky|alma|amzn|ol)
                          PKG="yum";  INST="yum install -y"; UPDATE="" ;;
    fedora)               PKG="yum";  INST="dnf install -y"; UPDATE="" ;;
    *) die "不支持的系统: $ID (仅支持 Debian/Ubuntu/RHEL/CentOS/Rocky/Alma/Fedora)" ;;
  esac
  log "检测到系统: $ID ($(uname -m))"
}
# ============================ 交互式配置 ====================================
interactive_config() {
  banner
  echo ""
  echo -e "${C_YELLOW}本次安装会部署到当前服务器, 请按要求逐项配置。${C_OFF}"

  # ---------- 1. 选择组件 ----------
  choose "请选择要安装的组件 (可多选):" COMP_SEL "no" "1,2,5,6" "1,2,5,6 (Fail2ban + auditd + 每日日报 + 资源监控)" \
    "1|Fail2ban     - 暴力破解自动封禁 (推荐)" \
    "2|auditd       - 登录/账户/命令审计+实时告警 (推荐)" \
    "3|Wazuh Agent  - 上报到已有的 Wazuh manager" \
    "4|Wazuh 全套   - 本机整套部署 (需 >=4G 内存)" \
    "5|每日巡检日报  - 每天08:00推送安全摘要" \
    "6|资源监控     - CPU/内存/磁盘/负载 超阈值实时告警" \
    "7|时区修改     - 设置系统时区 (上海/北京/巴基斯坦/印尼首都)" \
    "all|推荐全套(Fail2ban+auditd+每日日报+资源监控+时区, 不含 Wazuh)"
  local n
  INSTALL_FAIL2BAN=no; INSTALL_AUDITD=no; INSTALL_WAZUH=none; INSTALL_DAILY=no; INSTALL_RESOURCE_MONITOR=no; INSTALL_TIMEZONE=no
  case "$COMP_SEL" in
    all) INSTALL_FAIL2BAN=yes; INSTALL_AUDITD=yes; INSTALL_DAILY=yes; INSTALL_RESOURCE_MONITOR=yes; INSTALL_TIMEZONE=yes ;;
    *) IFS=',' read -ra comp_arr <<< "$COMP_SEL"
       for n in "${comp_arr[@]}"; do
         n="${n## }"; n="${n%% }"
         case "$n" in
           1) INSTALL_FAIL2BAN=yes ;;
           2) INSTALL_AUDITD=yes ;;
           3) INSTALL_WAZUH="agent" ;;
           4) INSTALL_WAZUH="full" ;;
           5) INSTALL_DAILY=yes ;;
           6) INSTALL_RESOURCE_MONITOR=yes ;;
           7) INSTALL_TIMEZONE=yes ;;
           *) warn "忽略未知组件选项: $n" ;;
         esac
       done ;;
  esac
  if [ "$INSTALL_FAIL2BAN" = no ] && [ "$INSTALL_AUDITD" = no ] && [ "$INSTALL_WAZUH" = none ] && [ "$INSTALL_DAILY" = no ] && [ "$INSTALL_RESOURCE_MONITOR" = no ] && [ "$INSTALL_TIMEZONE" = no ]; then
    die "未选择任何组件, 退出安装"
  fi

  # ---------- 2. 时区设置 (紧随组件选择) ----------
  if [ "$INSTALL_TIMEZONE" = yes ]; then
    echo ""
    echo -e "${C_CYAN}--- 时区设置 ---${C_OFF}"
    echo -e "  请选择要设置的时区:"
    echo -e "    1 ) 上海 (Asia/Shanghai, UTC+8)"
    echo -e "    2 ) 北京 (Asia/Shanghai, UTC+8)"
    echo -e "    3 ) 巴基斯坦 (Asia/Karachi, UTC+5)"
    echo -e "    4 ) 印度尼西亚首都·雅加达 (Asia/Jakarta, UTC+7)"
    if ! read -r tzsel; then echo ""; die "输入已中断 (EOF), 安装取消"; fi
    case "${tzsel:-1}" in
      1|shanghai|Shanghai|Asia/Shanghai) TIMEZONE="Asia/Shanghai" ;;
      2|beijing|Beijing|北京|Asia/Beijing) TIMEZONE="Asia/Shanghai" ;;
      3|pakistan|Pakistan|巴基斯坦|Asia/Karachi) TIMEZONE="Asia/Karachi" ;;
      4|indonesia|Indonesia|印度尼西亚|雅加达|jakarta|Jakarta|Asia/Jakarta) TIMEZONE="Asia/Jakarta" ;;
      *) warn "未知时区选项 \"$tzsel\" (${tzsel:-空}), 使用默认上海"; TIMEZONE="Asia/Shanghai" ;;
    esac
    log "将设置系统时区为: ${TIMEZONE}"
  fi

  # ---------- 3. Wazuh 参数 ----------
  if [ "$INSTALL_WAZUH" = "agent" ]; then
    prompt WAZUH_MANAGER_ADDR "Wazuh manager 服务器地址 (IP或域名)" "${WAZUH_MANAGER_ADDR:-}"
    [ -n "$WAZUH_MANAGER_ADDR" ] || die "agent 模式必须提供 manager 地址"
  elif [ "$INSTALL_WAZUH" = "full" ]; then
    local mem latest
    mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
    [ -n "$mem" ] || mem=8192
    if [ "$mem" -lt 4096 ]; then
      warn "当前内存 ${mem}MB, Wazuh 全套官方要求 >=4GB, 强行安装可能 OOM!"
      confirm "仍然继续安装?" || die "已取消 Wazuh 全套安装"
    fi
    # 在线检测最新版本并询问
    latest=$(get_latest_wazuh_version) || true
    if [ -n "$latest" ]; then
      log "在线检测到 Wazuh 最新版本: ${latest} (内置默认: ${WAZUH_VERSION_DEFAULT})"
      prompt WAZUH_VERSION "使用版本(直接回车用最新 ${latest})" "$latest"
    else
      warn "在线版本检测失败(无网络/API限流), 将使用内置默认 ${WAZUH_VERSION_DEFAULT}"
      prompt WAZUH_VERSION "使用版本(直接回车用默认)" "$WAZUH_VERSION_DEFAULT"
    fi
  fi

  # ---------- 4. 选择告警渠道 ----------
  choose "请选择告警推送渠道 (可多选, 不配置则仅写本地日志不推送):" CH_SEL "yes" "" "不配置(仅本地日志)" \
    "1|钉钉机器人" \
    "2|企业微信机器人" \
    "3|Telegram Bot" \
    "4|邮件 (SMTP)"
  local channels=""
  case "$CH_SEL" in
    0|"") channels="" ;;
    all) channels="dingtalk,wechat,telegram,email" ;;
    *) IFS=',' read -ra ch_arr <<< "$CH_SEL"
       for n in "${ch_arr[@]}"; do
         n="${n## }"; n="${n%% }"
         case "$n" in
           1) channels="${channels:+$channels,}dingtalk" ;;
           2) channels="${channels:+$channels,}wechat" ;;
           3) channels="${channels:+$channels,}telegram" ;;
           4) channels="${channels:+$channels,}email" ;;
           *) warn "忽略未知渠道选项: $n" ;;
         esac
       done ;;
  esac
  ALERT_CHANNELS="$channels"

  # ---------- 5. 各渠道参数 ----------
  if echo "$ALERT_CHANNELS" | grep -q dingtalk; then
    echo ""
    echo -e "${C_CYAN}--- 钉钉机器人配置 ---${C_OFF}"
    echo "  获取方法: 钉钉群 -> 群设置 -> 智能群助手 -> 添加机器人 -> 自定义"
    prompt DINGTALK_WEBHOOK "Webhook 地址" "${DINGTALK_WEBHOOK:-}"
    [ -n "$DINGTALK_WEBHOOK" ] || warn "Webhook 留空则钉钉渠道无效"
    prompt DINGTALK_SECRET "加签密钥(留空则不加签)" "${DINGTALK_SECRET:-}" --secret
  fi
  if echo "$ALERT_CHANNELS" | grep -q wechat; then
    echo ""
    echo -e "${C_CYAN}--- 企业微信机器人配置 ---${C_OFF}"
    echo "  获取方法: 企业微信群 -> 添加群机器人 -> 复制 Webhook 地址"
    prompt WECHAT_WEBHOOK "Webhook 地址" "${WECHAT_WEBHOOK:-}"
    [ -n "$WECHAT_WEBHOOK" ] || warn "Webhook 留空则企业微信渠道无效"
  fi
  if echo "$ALERT_CHANNELS" | grep -q telegram; then
    echo ""
    echo -e "${C_CYAN}--- Telegram Bot 配置 ---${C_OFF}"
    echo "  获取方法: 找 @BotFather 创建 Bot 拿 token; 找 @userinfobot 拿 chat id"
    prompt TG_BOT_TOKEN "Bot Token" "${TG_BOT_TOKEN:-}"
    prompt TG_CHAT_ID "Chat ID" "${TG_CHAT_ID:-}"
  fi
  if echo "$ALERT_CHANNELS" | grep -q email; then
    echo ""
    echo -e "${C_CYAN}--- 邮件告警配置 ---${C_OFF}"
    prompt EMAIL_TO "收件人邮箱" "${EMAIL_TO:-}"
    prompt SMTP_SERVER "SMTP 服务器(例: smtp.qq.com:587)" "${SMTP_SERVER:-}"
    prompt SMTP_USER "SMTP 用户名" "${SMTP_USER:-}"
    prompt SMTP_PASS "SMTP 密码/授权码" "${SMTP_PASS:-}" --secret
    prompt SMTP_FROM "发件人地址" "${SMTP_FROM:-$SMTP_USER}"
  fi

  # ---------- 6. Fail2ban / auditd 参数 ----------
  if [ "$INSTALL_FAIL2BAN" = yes ]; then
    echo ""
    echo -e "${C_CYAN}--- Fail2ban 参数 (直接回车用默认) ---${C_OFF}"
    prompt F2B_MAXRETRY "失败多少次触发封禁" "$F2B_MAXRETRY"
    prompt F2B_FINDTIME "统计窗口(例: 10m/1h)" "$F2B_FINDTIME"
    prompt F2B_BANTIME "封禁时长(例: 1h/1d)" "$F2B_BANTIME"
    prompt F2B_IGNOREIP "白名单IP(空格分隔)" "$F2B_IGNOREIP"
    prompt F2B_SSH_PORT "SSH 端口(回车=自动探测, 多端口空格分隔)" "${F2B_SSH_PORT:-$(detect_ssh_port)}"
  fi
  if [ "$INSTALL_AUDITD" = yes ]; then
    prompt AUDIT_EXECVE "是否审计全部命令执行 (yes/no, 日志量大)" "$AUDIT_EXECVE"
  fi

  if [ "$INSTALL_RESOURCE_MONITOR" = yes ]; then
    echo ""
    echo -e "${C_CYAN}--- 资源监控参数 (直接回车用默认, 负载阈值自动取 CPU 核数) ---${C_OFF}"
    prompt RES_CPU_WARN  "CPU  告警阈值(%)"  "$RES_CPU_WARN"
    prompt RES_CPU_CRIT  "CPU  严重阈值(%)"  "$RES_CPU_CRIT"
    prompt RES_MEM_WARN  "内存 告警阈值(%)"  "$RES_MEM_WARN"
    prompt RES_MEM_CRIT  "内存 严重阈值(%)"  "$RES_MEM_CRIT"
    prompt RES_DISK_WARN "磁盘 告警阈值(%)"  "$RES_DISK_WARN"
    prompt RES_DISK_CRIT "磁盘 严重阈值(%)"  "$RES_DISK_CRIT"
    prompt RES_INTERVAL  "检查间隔(秒, 默认300=5分钟)" "$RES_INTERVAL"
    prompt RES_COOLDOWN  "重复告警冷却(秒, 默认1800=30分钟)" "$RES_COOLDOWN"
    prompt RES_DISK_IGNORE "忽略挂载点(逗号分隔, 留空)" "${RES_DISK_IGNORE:-}"
  fi

  # ---------- 7. 确认 ----------
  echo ""
  echo -e "${C_YELLOW}=============== 安装清单确认 ===============${C_OFF}"
  local comps=""
  [ "$INSTALL_FAIL2BAN" = yes ] && comps="${comps:+$comps, }Fail2ban"
  [ "$INSTALL_AUDITD" = yes ] && comps="${comps:+$comps, }auditd"
  [ "$INSTALL_WAZUH" != none ] && comps="${comps:+$comps, }Wazuh($INSTALL_WAZUH)"
  [ "$INSTALL_DAILY" = yes ] && comps="${comps:+$comps, }每日巡检日报"
  [ "$INSTALL_RESOURCE_MONITOR" = yes ] && comps="${comps:+$comps, }资源监控"
  [ "$INSTALL_TIMEZONE" = yes ] && comps="${comps:+$comps, }时区设置(${TIMEZONE:-默认})"
  echo "  组件      : ${comps:-无}"
  echo "  告警渠道  : ${ALERT_CHANNELS:-未配置(仅本地日志)}"
  echo "$ALERT_CHANNELS" | grep -q dingtalk && [ -n "$DINGTALK_WEBHOOK" ] && echo "  钉钉      : ${DINGTALK_WEBHOOK}"
  echo "$ALERT_CHANNELS" | grep -q wechat && [ -n "$WECHAT_WEBHOOK" ] && echo "  企业微信  : ${WECHAT_WEBHOOK}"
  echo "$ALERT_CHANNELS" | grep -q telegram && [ -n "$TG_BOT_TOKEN" ] && echo "  Telegram  : bot=${TG_BOT_TOKEN:0:10}... chat=${TG_CHAT_ID}"
  echo "$ALERT_CHANNELS" | grep -q email && [ -n "$EMAIL_TO" ] && echo "  邮件      : ${EMAIL_TO} (via ${SMTP_SERVER})"
  [ "$INSTALL_WAZUH" = agent ] && echo "  Wazuh     : agent -> ${WAZUH_MANAGER_ADDR}"
  [ "$INSTALL_WAZUH" = full ] && echo "  Wazuh     : full (v${WAZUH_VERSION:-自动检测})"
  echo -e "${C_YELLOW}==============================================${C_OFF}"
  confirm "确认无误, 开始安装?" || die "已取消安装"
}
# ============================ 基础安装 ======================================
install_base() {
  log "安装基础依赖..."
  if [ "$PKG" = "apt" ]; then
    eval "$UPDATE" || warn "apt update 有源失败, 继续安装..."
    local pkgs="curl openssl python3 cron"
    [ "$INSTALL_FAIL2BAN" = yes ] && pkgs="$pkgs fail2ban"
    [ "$INSTALL_AUDITD" = yes ] && pkgs="$pkgs auditd"
    echo "$ALERT_CHANNELS" | grep -q email && pkgs="$pkgs mailutils"
    eval "$INST $pkgs" || { warn "部分包安装失败, 尝试逐个补齐..."; for p in $pkgs; do eval "$INST $p" || warn "包 $p 安装失败"; done; }
  else
    yum install -y epel-release >/dev/null 2>&1 || true
    local pkgs="curl openssl python3 cronie"
    [ "$INSTALL_FAIL2BAN" = yes ] && pkgs="$pkgs fail2ban"
    [ "$INSTALL_AUDITD" = yes ] && pkgs="$pkgs audit"
    echo "$ALERT_CHANNELS" | grep -q email && pkgs="$pkgs mailx"
    eval "$INST $pkgs" || { warn "部分包安装失败, 尝试逐个补齐..."; for p in $pkgs; do eval "$INST $p" || warn "包 $p 安装失败"; done; }
  fi
  command -v python3 >/dev/null 2>&1 || die "缺少 python3, 无法完成安装"
  command -v curl    >/dev/null 2>&1 || die "缺少 curl"
  command -v openssl >/dev/null 2>&1 || die "缺少 openssl"
  log "依赖安装完成"
}
# ============================ 告警分发脚本 ==================================
setup_alert_scripts() {
  log "生成告警配置 /etc/security-monitor.conf (值经 shell 安全转义)"
  ALERT_CHANNELS="$ALERT_CHANNELS" \
  DINGTALK_WEBHOOK="$DINGTALK_WEBHOOK" \
  DINGTALK_SECRET="$DINGTALK_SECRET" \
  WECHAT_WEBHOOK="$WECHAT_WEBHOOK" \
  TG_BOT_TOKEN="$TG_BOT_TOKEN" \
  TG_CHAT_ID="$TG_CHAT_ID" \
  EMAIL_TO="$EMAIL_TO" \
  SMTP_SERVER="$SMTP_SERVER" \
  SMTP_USER="$SMTP_USER" \
  SMTP_PASS="$SMTP_PASS" \
  SMTP_FROM="$SMTP_FROM" \
  RES_INTERVAL="$RES_INTERVAL" \
  RES_COOLDOWN="$RES_COOLDOWN" \
  RES_CPU_WARN="$RES_CPU_WARN" \
  RES_CPU_CRIT="$RES_CPU_CRIT" \
  RES_MEM_WARN="$RES_MEM_WARN" \
  RES_MEM_CRIT="$RES_MEM_CRIT" \
  RES_DISK_WARN="$RES_DISK_WARN" \
  RES_DISK_CRIT="$RES_DISK_CRIT" \
  RES_LOAD_WARN="$RES_LOAD_WARN" \
  RES_LOAD_CRIT="$RES_LOAD_CRIT" \
  RES_DISK_IGNORE="$RES_DISK_IGNORE" \
  python3 - <<'PYEOF'
import os, shlex
keys = ["ALERT_CHANNELS","DINGTALK_WEBHOOK","DINGTALK_SECRET","WECHAT_WEBHOOK",
        "TG_BOT_TOKEN","TG_CHAT_ID","EMAIL_TO","SMTP_SERVER","SMTP_USER",
        "SMTP_PASS","SMTP_FROM",
        "RES_INTERVAL","RES_COOLDOWN","RES_CPU_WARN","RES_CPU_CRIT",
        "RES_MEM_WARN","RES_MEM_CRIT","RES_DISK_WARN","RES_DISK_CRIT",
        "RES_LOAD_WARN","RES_LOAD_CRIT","RES_DISK_IGNORE"]
lines = ["# 安全告警与资源监控配置 (由安装脚本生成, 可手动修改)",
         "# 值经 shlex.quote 转义, 含 $ ` \" ' 等特殊字符也安全"]
for k in keys:
    lines.append("%s=%s" % (k, shlex.quote(os.environ.get(k, ""))))
with open("/etc/security-monitor.conf", "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
  chmod 600 /etc/security-monitor.conf
  # 预创建告警日志并设 600 权限, 避免 world-readable
  [ -f /var/log/security-alert.log ] || install -m 600 -o root -g root /dev/null /var/log/security-alert.log 2>/dev/null || true

  log "生成告警分发脚本 /usr/local/bin/security-alert.sh"
  cat > /usr/local/bin/security-alert.sh <<'ALERTEOF'
#!/usr/bin/env bash
# 安全告警分发脚本
# 用法: security-alert.sh <标题> <正文(或 - 表示从 stdin 读取)> [级别: info|warn|high]
set -u
# 日志若被删重建, 默认 umask 会让其 644 泄密(含告警正文片段), 强制 600
umask 077
CONF=/etc/security-monitor.conf
[ -f "$CONF" ] && . "$CONF"

TITLE="${1:-安全告警}"
BODY="${2:--}"
LEVEL="${3:-high}"
[ "$BODY" = "-" ] && BODY="$(cat)"

# 多服务器共用同一告警渠道时, 在标题前加 [主机名] 以便区分来源
HOST="$(hostname 2>/dev/null || echo unknown)"
[ -n "$HOST" ] && [ "$HOST" != "unknown" ] && TITLE="[${HOST}] ${TITLE}"

echo "[$(date '+%F %T')] [$LEVEL] $TITLE :: $(echo "$BODY" | head -c 300)" >> /var/log/security-alert.log

ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
err()  { echo -e "\033[1;31m[-]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }

send_dingtalk() {
  [ -z "${DINGTALK_WEBHOOK:-}" ] && return 1
  local url="$DINGTALK_WEBHOOK"
  if [ -n "${DINGTALK_SECRET:-}" ]; then
    local ts sign enc
    ts=$(date +%s%3N)
    sign=$(printf '%s\n%s' "$ts" "$DINGTALK_SECRET" | openssl dgst -sha256 -hmac "$DINGTALK_SECRET" -binary | base64)
    enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$sign")
    url="${DINGTALK_WEBHOOK}&timestamp=${ts}&sign=${enc}"
  fi
  local json resp parsed ec msg
  json=$(python3 -c '
import json,sys
print(json.dumps({"msgtype":"markdown","markdown":{"title":sys.argv[1],"text":sys.argv[2][:19900]}}))' "$TITLE" "$BODY")
  resp=$(curl -sS -m 10 -H 'Content-Type: application/json' -d "$json" "$url" 2>/dev/null) \
    || { err "[钉钉] 网络错误(curl)"; return 1; }
  # 钉钉失败也返回 HTTP 200 + {"errcode":非0,...}, 必须解析
  parsed=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except: print("?|非JSON响应"); raise SystemExit
print("%s|%s" % (d.get("errcode","?"), (d.get("errmsg","") or "").replace("|","/")))')
  IFS='|' read -r ec msg <<< "$parsed"
  [ "$ec" = "0" ] && { ok "[钉钉] 已发送"; return 0; }
  err "[钉钉] 发送失败 errcode=${ec}: ${msg}"
  return 1
}

send_wechat() {
  [ -z "${WECHAT_WEBHOOK:-}" ] && return 1
  local json resp parsed ec msg
  json=$(python3 -c '
import json,sys
print(json.dumps({"msgtype":"markdown","markdown":{"content":"**"+sys.argv[1]+"**\n\n"+sys.argv[2][:4000]}}))' "$TITLE" "$BODY")
  resp=$(curl -sS -m 10 -H 'Content-Type: application/json' -d "$json" "$WECHAT_WEBHOOK" 2>/dev/null) \
    || { err "[企业微信] 网络错误(curl)"; return 1; }
  # 企业微信失败也返回 HTTP 200 + {"errcode":非0,...}, 必须解析
  parsed=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except: print("?|非JSON响应"); raise SystemExit
print("%s|%s" % (d.get("errcode","?"), (d.get("errmsg","") or "").replace("|","/")))')
  IFS='|' read -r ec msg <<< "$parsed"
  [ "$ec" = "0" ] && { ok "[企业微信] 已发送"; return 0; }
  err "[企业微信] 发送失败 errcode=${ec}: ${msg}"
  return 1
}

send_telegram() {
  [ -z "${TG_BOT_TOKEN:-}" ] && return 1
  [ -z "${TG_CHAT_ID:-}" ] && return 1
  local resp parsed oks ec desc retry attempt=0
  # Telegram 即便失败也返回 HTTP 200 + {"ok":false,"error_code":...,"parameters":{"retry_after":N}}
  while :; do
    resp=$(curl -sS -m 10 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=[${LEVEL}] ${TITLE}

${BODY}" 2>/dev/null) || { err "[Telegram] 网络错误(curl)"; return 1; }
    parsed=$(printf '%s' "$resp" | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except: print("0||非JSON响应|0"); raise SystemExit
print("%s|%s|%s|%s" % ("1" if d.get("ok") else "0", d.get("error_code","") or "", (d.get("description","") or "").replace("|","/"), (d.get("parameters") or {}).get("retry_after",0) or 0))')
    IFS='|' read -r oks ec desc retry <<< "$parsed"
    [ "$oks" = "1" ] && { ok "[Telegram] 已发送"; return 0; }
    if [ "${retry:-0}" -gt 0 ] && [ "$attempt" -lt 3 ]; then
      attempt=$((attempt+1))
      warn "[Telegram] 限流(429), ${retry}s 后重试(第${attempt}/3次)"
      sleep "$retry"
      continue
    fi
    err "[Telegram] 发送失败 error_code=${ec:-?}: ${desc}"
    return 1
  done
}

send_email() {
  [ -z "${EMAIL_TO:-}" ] && return 1
  command -v mail >/dev/null 2>&1 || { err "[邮件] 缺少 mail 命令"; return 1; }
  printf '%s\n' "$BODY" | mail -s "[安全告警] ${TITLE}" "$EMAIL_TO" >/dev/null 2>&1 \
    || { err "[邮件] 发送失败"; return 1; }
  ok "[邮件] 已发送"
}

for c in $(echo "${ALERT_CHANNELS:-}" | tr ',' ' '); do
  case "$c" in
    dingtalk) send_dingtalk || true ;;
    wechat)   send_wechat   || true ;;
    telegram) send_telegram || true ;;
    email)    send_email    || true ;;
    *) err "[告警] 未知渠道: $c" ;;
  esac
done
ALERTEOF
  chmod 755 /usr/local/bin/security-alert.sh

  if echo "$ALERT_CHANNELS" | grep -q email && [ -n "$SMTP_SERVER" ]; then
    # 用标记块裹, 重装时先删旧块再追加, 避免重复
    [ -f /etc/mail.rc ] && sed -i '/# BEGIN security-monitor/,/# END security-monitor/d' /etc/mail.rc 2>/dev/null || true
    cat >> /etc/mail.rc <<MAILYEOF
# BEGIN security-monitor
set smtp=$SMTP_SERVER
set smtp-auth=login
set smtp-auth-user=$SMTP_USER
set smtp-auth-password=$SMTP_PASS
set from=$SMTP_FROM
set ssl-verify=ignore
# END security-monitor
MAILYEOF
    log "已写入 /etc/mail.rc SMTP 配置 (标记块: # BEGIN/END security-monitor)"
  fi
}
# ============================== Fail2ban ====================================
# 自动探测 sshd 实际监听端口(sshd_config 里也可能只写 Port 不带 ListenAddress).
# 注意: 若直接写 port = ssh, fail2ban 会按 /etc/services 解析成 22, 改了端口的 sshd
# 封禁将不生效(防火墙只挡 22, 攻击者打真实端口不受影响).
detect_ssh_port() {
  local ports="" p
  # 1) 实际监听端口 (最可靠, 包含 systemd socket / sshd -p / drop-in 配置)
  ports=$(ss -tlnp 2>/dev/null | awk -F'[: ]+' '/sshd/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="users") print $i}' | sort -u)
  [ -z "$ports" ] && ports=$(ss -tlnp 2>/dev/null | grep -i sshd | awk '{print $4}' | awk -F: '{print $NF}' | grep -E '^[0-9]+$' | sort -u)
  # 2) 回退: sshd_config Port 指令 (含 .d drop-in)
  if [ -z "$ports" ]; then
    ports=$(grep -hiE '^\s*Port\s+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | grep -E '^[0-9]+$' | sort -u)
  fi
  # 3) 兜底 22
  [ -z "$ports" ] && ports=22
  echo "$ports" | tr '\n' ' ' | sed 's/ *$//'
}

setup_fail2ban() {
  log "配置 Fail2ban (封禁 ${F2B_BANTIME}, 窗口 ${F2B_FINDTIME}, 阈值 ${F2B_MAXRETRY} 次)"

  cat > /etc/fail2ban/action.d/security-alert.conf <<'ACTEOF'
# 自定义告警动作: 封禁/解封时推送多渠道通知
[Definition]
actionban   = /usr/local/bin/security-alert.sh "🚫 Fail2ban 封禁" "IP <ip> 在服务 <port>/<protocol> 上失败 <failures> 次, 封禁时长 <bantime> 秒" "high"
actionunban = /usr/local/bin/security-alert.sh "✅ Fail2ban 解封" "IP <ip> 已解封 (服务 <port>/<protocol>)" "info"

[Init]
ACTEOF

  # 推算 sshd 后端: 优先 systemd journal (现代发行版默认), 否则回退到文件后端
  # 若不显式指定 backend, 某些系统会让 sshd 走 'auto' 并要求 /var/log/auth.log,
  # 而纯 systemd 日志的系统没有该文件 -> 'Have not found any log file for sshd jail'
  #
  # systemd 后端要真正可用, 必须同时满足:
  #   1) PID 1 == systemd  (排除容器里 /run/systemd/system 误判)
  #   2) journalctl 能读到 ssh/sshd 日志
  #   3) python3-systemd 已安装  (fail2ban 的 systemd 后端强依赖此模块, 缺失会
  #      回退到文件后端, 而纯 journal 系统没有 /var/log/auth.log -> 启动报错)
  local use_systemd=no log_file=""
  if [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' \n')" = "systemd" ] \
     && command -v journalctl >/dev/null 2>&1 \
     && journalctl -u ssh -u sshd --no-pager -n1 >/dev/null 2>&1; then
    use_systemd=yes
    if ! python3 -c 'import systemd' 2>/dev/null; then
      warn "systemd journal 可用但缺少 python3-systemd, 尝试安装..."
      if [ "$PKG" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-systemd >/dev/null 2>&1 \
          && log "python3-systemd 已安装" \
          || { warn "python3-systemd 安装失败, 回退文件后端"; use_systemd=no; }
      else
        eval "\$INST python3-systemd" >/dev/null 2>&1 \
          && log "python3-systemd 已安装" \
          || { warn "python3-systemd 安装失败, 回退文件后端"; use_systemd=no; }
      fi
    fi
  fi

  if [ "$use_systemd" = yes ]; then
    F2B_BACKEND="systemd"
    F2B_LOGPATH_LINE=""   # systemd 后端不读 logpath, 留空不写入该行
  else
    F2B_BACKEND="auto"
    # 选实际存在的 SSH 日志文件
    for _f in /var/log/auth.log /var/log/secure; do
      [ -f "$_f" ] && { log_file="$_f"; break; }
    done
    if [ -z "$log_file" ]; then
      # 无 SSH 日志文件 (容器/纯 journal/未装 rsyslog 环境)
      warn "未找到 SSH 日志文件 (/var/log/auth.log, /var/log/secure)"
      # 尝试装 rsyslog 让 auth.log 实际有日志写入
      if [ "$PKG" = "apt" ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y rsyslog >/dev/null 2>&1 \
          && log "rsyslog 已安装 (将写入 /var/log/auth.log)" \
          || warn "rsyslog 安装失败 (容器环境常见, sshd 可能日志走 stdout)"
      else
        eval "\$INST rsyslog" >/dev/null 2>&1 && log "rsyslog 已安装" || warn "rsyslog 安装失败"
      fi
      # 占位文件: 保证 fail2ban 能启动 (即使 rsyslog 未装/未运行也不会报错)
      install -m 640 -o root -g adm /dev/null /var/log/auth.log 2>/dev/null || touch /var/log/auth.log
      log_file="/var/log/auth.log"
      warn "已创建占位 ${log_file}; 若 sshd 日志不写入此文件, sshd 监狱将无日志可分析"
      warn "  确认: rsyslog 运行(systemctl status rsyslog) 或改用 systemd 后端(装 python3-systemd)"
    fi
    F2B_LOGPATH_LINE="logpath = ${log_file}"
  fi

  # 确定要封禁的 SSH 端口: 显式指定 > 自动探测 > 22
  if [ -z "${F2B_SSH_PORT:-}" ]; then
    F2B_SSH_PORT=$(detect_ssh_port)
    log "自动探测 SSH 端口: ${F2B_SSH_PORT}"
  else
    log "使用指定 SSH 端口: ${F2B_SSH_PORT}"
  fi
  # fail2ban 的 port 字段支持多端口(逗号或空格分隔); 保持原样写入

  cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = ${F2B_BANTIME}
findtime = ${F2B_FINDTIME}
maxretry = ${F2B_MAXRETRY}
ignoreip = ${F2B_IGNOREIP}
# 默认动作 = iptables 封禁 + 告警通知
action_sec = %(action_)s
             security-alert
action = %(action_sec)s

[sshd]
enabled = true
port    = ${F2B_SSH_PORT}
backend = ${F2B_BACKEND}
${F2B_LOGPATH_LINE}
EOF

  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban 2>/dev/null || service fail2ban restart || \
    warn "fail2ban 启动失败, 请检查日志 /var/log/fail2ban.log"
  sleep 2
  if fail2ban-client status sshd >/dev/null 2>&1; then
    log "Fail2ban 已运行, sshd 监狱已启用 (backend=${F2B_BACKEND}, port=${F2B_SSH_PORT})"
  else
    warn "fail2ban sshd 监狱未就绪, 排查:"
    warn "  · 日志: tail -50 /var/log/fail2ban.log"
    warn "  · 配置校验: fail2ban-client -t"
    warn "  · 若非 systemd 日志系统, 确认 SSH 日志文件存在 (如 /var/log/auth.log)"
  fi
}
# =============================== auditd =====================================
set_auparam() {
  local key="$1" val="$2" f=/etc/audit/auditd.conf
  [ -f "$f" ] || { warn "$f 不存在, 跳过设置 $key"; return 0; }
  if grep -q "^${key} *=" "$f"; then
    sed -i "s|^${key} *=.*|${key} = ${val}|" "$f"
  else
    echo "${key} = ${val}" >> "$f"
  fi
}

setup_auditd() {
  log "配置 auditd (登录/账户/命令审计)"
  mkdir -p /etc/audit/rules.d

  cat > /etc/audit/rules.d/security.rules <<'RULEEOF'
## ---- 关键文件/目录变更监控 (写入或属性修改即记录) ----
-w /etc/passwd              -p wa -k identity
-w /etc/shadow              -p wa -k identity
-w /etc/group               -p wa -k identity
-w /etc/gshadow             -p wa -k identity
-w /etc/sudoers             -p wa -k sudoers
-w /etc/sudoers.d/          -p wa -k sudoers
-w /etc/ssh/sshd_config     -p wa -k sshd
-w /etc/crontab             -p wa -k cron
-w /etc/cron.d/             -p wa -k cron
-w /etc/cron.daily/         -p wa -k cron
-w /root/.bashrc            -p wa -k dotfiles
-w /root/.bash_history      -p wa -k dotfiles
-w /root/.ssh/              -p wa -k dotfiles
-w /etc/hosts               -p wa -k netconf
-w /etc/systemd/system/     -p wa -k systemd
-w /var/run/utmp            -p wa -k session
-w /var/log/wtmp            -p wa -k session
-w /var/log/btmp            -p wa -k session

## ---- 命令执行审计 (记录所有普通用户执行过的命令) ----
## 查询: ausearch -k cmd_audit | aureport -i
RULEEOF

  if [ "$AUDIT_EXECVE" = "yes" ]; then
    cat >> /etc/audit/rules.d/security.rules <<'RULEEOF'
-a always,exit -F arch=b64 -S execve -F auid>=1000 -F auid!=4294967295 -k cmd_audit
-a always,exit -F arch=b32 -S execve -F auid>=1000 -F auid!=4294967295 -k cmd_audit
RULEEOF
  fi

  set_auparam max_log_file 200
  set_auparam max_log_file_action ROTATE
  set_auparam num_logs 5
  set_auparam space_left 75
  set_auparam space_left_action SYSLOG
  set_auparam admin_space_left 50
  set_auparam admin_space_left_action SYSLOG

  augenrules --load >/dev/null 2>&1 || auditctl -R /etc/audit/rules.d/security.rules >/dev/null 2>&1 || \
    warn "审计规则加载失败, 请手动执行: augenrules --load"
  systemctl enable auditd >/dev/null 2>&1 || true
  systemctl restart auditd 2>/dev/null || service auditd restart >/dev/null 2>&1 || \
    warn "auditd 启动失败(容器/权限受限环境常见), 登录审计将不可用"
  log "审计规则已加载: $(auditctl -l 2>/dev/null | wc -l) 条"
}
# ========================= 审计日志实时告警 =================================
setup_audit_watcher() {
  log "生成审计告警监控器 /usr/local/bin/audit-alert-watcher.sh"

  cat > /usr/local/bin/audit-alert-watcher.sh <<'WATCHEOF'
#!/usr/bin/env bash
# 审计日志实时告警监控器 (由 install_security_monitor.sh 生成)
# 监控: 登录成功/失败、暴力破解、账户变更、危险命令执行
set -u
CONF=/etc/security-monitor.conf
[ -f "$CONF" ] && . "$CONF"

LOG=/var/log/audit/audit.log
[ -f "$LOG" ] || { echo "[-] $LOG 不存在, auditd 可能未运行" >&2; exit 1; }

declare -A AUTHFAIL_CNT
alert() { /usr/local/bin/security-alert.sh "$1" "$2" "${3:-high}"; }
# 引号处理: 删双引号(让 exe="path" -> exe=path 紧贴), 单引号转空格(分隔 msg 内外层)。
# 必须这样: 新版 auditd 在 res=success' 后紧追 UID="root" 增强字段且无空格,
# 若直接 tr -d 删单引号, 会把 res=success 和 UID= 粘成 successUID=root -> 解析失败。
getf()  { echo "$1" | tr -d '"' | tr "'" ' ' | sed -n "s/.*$2=\([^ ]*\).*/\1/p" | head -1; }

# 仅匹配高置信度的反弹 shell / 管道执行远程脚本, 减少误报
DANGEROUS_PATTERNS='/dev/tcp/|/dev/udp/|bash -i|sh -i|bash -c .*(ba)?sh|sh -c .*(ba)?sh|nc -[a-zA-Z0-9]*e |ncat -[a-zA-Z0-9]*e |socat -[a-zA-Z ]|curl[^|]*[|] *(ba)?sh|wget[^|]*[|] *(ba)?sh|echo.*>>.*/etc/passwd|echo.*>>.*/etc/sudoers'

echo "[*] 审计告警监控器已启动: $(date '+%F %T')"
tail -n0 -F "$LOG" | while IFS= read -r line; do
  case "$line" in
    type=USER_LOGIN*)
      # USER_LOGIN 事件用 id= 而非 acct=, 需回退取用户名
      acct=$(getf "$line" acct); [ -n "$acct" ] || acct=$(getf "$line" UID); [ -n "$acct" ] || acct=$(getf "$line" auid)
      addr=$(getf "$line" addr); exe=$(getf "$line" exe); res=$(getf "$line" res)
      if [ "$res" = "success" ]; then
        alert "🖥 新登录" "用户 **${acct}** 通过 ${exe} 从 ${addr} 登录 ($(date '+%F %T'))" "warn"
      fi
      ;;
    type=USER_AUTH*)
      res=$(getf "$line" res)
      if [ "$res" = "failed" ]; then
        addr=$(getf "$line" addr); [ -n "$addr" ] || addr="unknown"
        n=$(( ${AUTHFAIL_CNT[$addr]:-0} + 1 )); AUTHFAIL_CNT[$addr]=$n
        case "$n" in 5|10|20|40|80) alert "🚨 疑似暴力破解" "来自 ${addr} 的登录失败已达 ${n} 次" "high";; esac
      fi
      ;;
    # 注意: audit 类型字符串是 ADD_USER/DEL_USER/ADD_GROUP/DEL_GROUP/CHUSER_ID/
    # CHGRP_ID/USER_CHAUTHTOK/USER_ROLE_CHANGE (内核常量名 AUDIT_USER_ADD 等,
    # 但日志/ausearch 用的是反过来的字符串)。早期写 USER_ADD* 会匹配不到
    # useradd/userdel 事件 -> 实时告警静默失效。
    type=ADD_USER*|type=DEL_USER*|type=ADD_GROUP*|type=DEL_GROUP*|type=CHUSER_ID*|type=CHGRP_ID*|type=USER_CHAUTHTOK*|type=USER_ROLE_CHANGE*)
      acct=$(getf "$line" acct); id=$(getf "$line" id)
      [ -n "$acct" ] || acct="-"
      alert "👤 账户变更" "类型: $(echo "$line" | cut -d' ' -f1 | cut -d= -f2)  账户: ${acct} (uid=${id:-?})" "high"
      ;;
    type=EXECVE*)
      if echo "$line" | grep -qiE "$DANGEROUS_PATTERNS"; then
        alert "⚠️ 可疑命令" "检测到危险命令: $(echo "$line" | cut -c1-800)" "high"
      fi
      ;;
  esac
done
WATCHEOF
  chmod 755 /usr/local/bin/audit-alert-watcher.sh

  cat > /etc/systemd/system/audit-alert-watcher.service <<'SVCEOF'
[Unit]
Description=Audit Log Security Alert Watcher
After=auditd.service
Requires=auditd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/audit-alert-watcher.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable audit-alert-watcher >/dev/null 2>&1 || true
  systemctl restart audit-alert-watcher 2>/dev/null && log "审计实时监控器已启动" \
    || warn "监控器启动失败, 查看: journalctl -u audit-alert-watcher"
}
# =========================== Wazuh 版本检测 ================================
get_latest_wazuh_version() {
  # 从 GitHub Releases API 查询最新正式版, 输出 X.Y.Z (如 4.14.7); 失败无输出
  local ver
  ver=$(curl -fsSL --max-time 15 "https://api.github.com/repos/wazuh/wazuh/releases/latest" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null)
  ver="${ver#v}"
  echo "$ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && echo "$ver"
}

resolve_wazuh_version() {
  # 确定实际使用的版本: 显式指定 > 在线检测最新 > 内置默认
  if [ -n "${WAZUH_VERSION:-}" ]; then
    WAZUH_VERSION_RESOLVED="$WAZUH_VERSION"
    log "使用指定 Wazuh 版本: ${WAZUH_VERSION_RESOLVED}"
  else
    WAZUH_VERSION_RESOLVED=$(get_latest_wazuh_version) || true
    if [ -n "$WAZUH_VERSION_RESOLVED" ]; then
      log "在线检测到 Wazuh 最新版本: ${WAZUH_VERSION_RESOLVED}"
    else
      WAZUH_VERSION_RESOLVED="$WAZUH_VERSION_DEFAULT"
      warn "在线版本检测失败(无网络/API限流), 使用内置默认 ${WAZUH_VERSION_RESOLVED}"
    fi
  fi
  # wazuh-install.sh 的下载目录是 X.Y 主次版本号
  WAZUH_URL_VERSION=$(echo "$WAZUH_VERSION_RESOLVED" | cut -d. -f1-2)
}

# ============================== Wazuh =======================================
install_wazuh_agent() {
  [ -n "$WAZUH_MANAGER_ADDR" ] || die "WAZUH_MODE=agent 但未设置 WAZUH_MANAGER_ADDR"
  log "安装 Wazuh Agent (manager: ${WAZUH_MANAGER_ADDR})"
  if [ "$PKG" = "apt" ]; then
    if command -v gpg >/dev/null 2>&1; then
      curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring \
        --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import >/dev/null 2>&1 && \
        chmod 644 /usr/share/keyrings/wazuh.gpg || warn "Wazuh GPG key 导入失败, apt 安装可能报 key 缺失"
    else
      warn "未安装 gpg, 跳过 Wazuh GPG key 导入 (apt 安装可能失败)"
    fi
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
      > /etc/apt/sources.list.d/wazuh.list
    eval "$UPDATE" || warn "apt update 有源失败, 继续..."
    WAZUH_MANAGER="$WAZUH_MANAGER_ADDR" WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" \
      DEBIAN_FRONTEND=noninteractive apt-get install -y wazuh-agent
  else
    cat > /etc/yum.repos.d/wazuh.repo <<'REPOEOF'
[wazuh]
gpgcheck=1
gpgkey=https://packages.wazuh.com/key/GPG-KEY-WAZUH
enabled=1
name=EL-$releasever - Wazuh
baseurl=https://packages.wazuh.com/4.x/yum/
protect=1
REPOEOF
    WAZUH_MANAGER="$WAZUH_MANAGER_ADDR" WAZUH_AGENT_NAME="$WAZUH_AGENT_NAME" yum install -y wazuh-agent
  fi
  # 仅替换文件中第一个 <address> 标签 (通常是 manager 地址), 避免覆盖 active-response 等其他地址
  python3 - "$WAZUH_MANAGER_ADDR" <<'PYEOF' || true
import re, sys
addr = sys.argv[1]
p = "/var/ossec/etc/ossec.conf"
try:
    s = open(p, encoding="utf-8").read()
except Exception:
    sys.exit(0)
s2, n = re.subn(r"(<address>)[^<]*(</address>)", lambda m: m.group(1)+addr+m.group(2), s, count=1)
if n:
    open(p, "w", encoding="utf-8").write(s2)
PYEOF
  systemctl enable wazuh-agent >/dev/null 2>&1 || true
  systemctl restart wazuh-agent 2>/dev/null || warn "wazuh-agent 启动失败"
  sleep 2
  systemctl is-active wazuh-agent >/dev/null 2>&1 && log "Wazuh Agent 已运行" \
    || warn "wazuh-agent 未运行, 查看: journalctl -u wazuh-agent"
}

# 安装完成后自动从日志/配置提取账号密码 (dashboad admin + API wazuh-wui)
extract_wazuh_credentials() {
  local logf=/root/wazuh-install.log
  WAZUH_DASH_USER="admin"; WAZUH_DASH_PASS=""; WAZUH_API_USER="wazuh-wui"; WAZUH_API_PASS=""
  [ -f "$logf" ] || { warn "未找到 $logf, 无法自动提取账号密码"; return 1; }
  # dashboard admin: 定位 "User: admin" 后紧随的 Password 行, 避免取错其他用户密码
  WAZUH_DASH_PASS=$(grep -A1 -iE '^[[:space:]]*User:[[:space:]]*admin[[:space:]]*$' "$logf" 2>/dev/null \
    | grep -iE '^[[:space:]]*Password:' | head -1 | sed 's/^[[:space:]]*[Pp]assword:[[:space:]]*//' | tr -d '\r') || true
  # API 凭据: 优先从日志取 (--change-passwords 场景打印), 否则从 dashboard 配置 wazuh.yml 取明文
  WAZUH_API_PASS=$(grep -iE 'password for Wazuh API user wazuh-wui' "$logf" | head -1 | sed 's/.*\bis //' | tr -d '\r') || true
  if [ -z "$WAZUH_API_PASS" ] && [ -f /usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml ]; then
    WAZUH_API_PASS=$(grep -A2 'username: wazuh-wui' /usr/share/wazuh-dashboard/data/wazuh/config/wazuh.yml \
      | grep -E '^\s*password:' | head -1 | sed 's/^\s*password: *//' | tr -d '"\r') || true
  fi
  if [ -n "$WAZUH_DASH_PASS" ]; then
    log "已自动提取 Wazuh 账号密码 (dashboard admin + API)"
  else
    warn "未能从日志提取 dashboard 密码, 请手动查看 $logf 中 --- Summary --- 部分"
  fi
}

setup_wazuh_full() {
  local mem
  resolve_wazuh_version
  mem=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}')
  [ -n "$mem" ] || mem=8192
  if [ "$mem" -lt 4096 ]; then
    warn "当前内存 ${mem}MB, Wazuh 全套官方要求 >=4GB, 将继续尝试(使用 -i 忽略检测)"
  fi
  log "下载 Wazuh 官方一键安装脚本 (all-in-one: manager+indexer+dashboard+agent)"
  local v url dl_ok=0 dash_port="$WAZUH_DASHBOARD_PORT"

  # Debian 兼容: wazuh-install.sh 硬性依赖 Ubuntu 特有的 software-properties-common 包
  if [ "$PKG" = "apt" ] && [ "$ID" = "debian" ] && \
     ! dpkg -l software-properties-common 2>/dev/null | grep -q '^ii'; then
    warn "Debian 源中没有 software-properties-common (Ubuntu 特有包), 创建 dummy 包满足 Wazuh 依赖检查..."
    mkdir -p /tmp/wazuh-dummy/DEBIAN
    cat > /tmp/wazuh-dummy/DEBIAN/control <<'DEBCTL'
Package: software-properties-common
Version: 0.99.0-1
Section: admin
Priority: optional
Architecture: all
Maintainer: local <root@localhost>
Description: dummy package to satisfy wazuh installer dependency
DEBCTL
    dpkg-deb --build /tmp/wazuh-dummy /tmp/software-properties-common_0.99.0-1_all.deb >/dev/null 2>&1
    dpkg -i /tmp/software-properties-common_0.99.0-1_all.deb >/dev/null 2>&1 && \
      log "dummy 包已创建 (software-properties-common)" || warn "dummy 包创建失败, 请手动处理"
  fi

  for v in "$WAZUH_URL_VERSION" "$WAZUH_VERSION_DEFAULT"; do
    url="https://packages.wazuh.com/${v}/wazuh-install.sh"
    log "尝试下载: ${url}"
    if curl -fsSL -o /root/wazuh-install.sh "$url"; then
      dl_ok=1; log "下载成功 (v${v}, $(wc -c < /root/wazuh-install.sh) 字节)"
      break
    fi
    warn "下载失败, 尝试下一版本..."
  done
  [ "$dl_ok" = 1 ] || die "wazuh-install.sh 下载失败, 请检查网络; 或指定其他版本: WAZUH_VERSION=4.9 bash $0"

  # 检测 Web 端口是否被占用, 被占用则自动改用 8443 (8443 也被占则提示)
  if ss -tlnp 2>/dev/null | grep -q ":${dash_port} " || netstat -tlnp 2>/dev/null | grep -q ":${dash_port} "; then
    warn "端口 ${dash_port} 已被其他进程占用, Wazuh Web 控制台将改用 8443"
    warn "如需其他端口: WAZUH_DASHBOARD_PORT=xxxx bash $0"
    dash_port=8443
    if ss -tlnp 2>/dev/null | grep -q ':8443 ' || netstat -tlnp 2>/dev/null | grep -q ':8443 '; then
      warn "8443 也被占用, 请用 WAZUH_DASHBOARD_PORT=<空闲端口> 重跑"
    fi
  fi
  DASHBOARD_PORT_USED="$dash_port"
  log "Wazuh Web 控制台端口: ${dash_port}"
  log "开始安装 Wazuh 全套, 预计 10-20 分钟, 日志: /root/wazuh-install.log"
  bash /root/wazuh-install.sh -a -i -p "$dash_port" > /root/wazuh-install.log 2>&1 \
    || die "Wazuh 安装失败, 请查看 /root/wazuh-install.log (结尾有错误原因; 重跑可加 --overwrite)"

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=1514/tcp --add-port=1515/tcp --add-port=55000/tcp --add-port=${dash_port}/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif command -v ufw >/dev/null 2>&1; then
    ufw allow 1514/tcp >/dev/null 2>&1 || true
    ufw allow 1515/tcp >/dev/null 2>&1 || true
    ufw allow 55000/tcp >/dev/null 2>&1 || true
    ufw allow ${dash_port}/tcp >/dev/null 2>&1 || true
  fi

  log "配置 Wazuh 告警转发到聊天渠道"
  cat > /var/ossec/integrations/custom-security <<'PYEOF'
#!/usr/bin/env python3
# Wazuh -> 多渠道告警转发 (由 install_security_monitor.sh 生成)
import json, sys, hmac, hashlib, base64, time, urllib.parse, urllib.request, re

conf = {}
try:
    import shlex
    for line in open("/etc/security-monitor.conf", encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        try:
            parts = shlex.split(v.strip())
            conf[k.strip()] = parts[0] if parts else ""
        except Exception:
            conf[k.strip()] = v.strip().strip('"').strip("'")
except Exception:
    pass

try:
    # Wazuh 把告警 JSON 写入文件并通过 argv[1] 传入; 兼容 stdin
    if len(sys.argv) > 1 and sys.argv[1] and sys.argv[1] != "-":
        data = json.load(open(sys.argv[1], encoding="utf-8"))
    else:
        data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

alert = data.get("alert") or {}
rule = alert.get("rule") or {}
level = rule.get("level", 0)
desc = rule.get("description") or alert.get("description") or "Unknown"
ts = alert.get("timestamp", "")
agent = (data.get("agent") or {}).get("name", "-")
full = alert.get("full_log") or json.dumps(alert.get("data", {}), ensure_ascii=False)[:1500]

text = "**Wazuh 告警 (Level %s)**\n\n- 时间: %s\n- 主机: %s\n- 规则: %s\n- 详情: %s" % (
    level, ts, agent, desc, full)

def post(url, data=None):
    req = urllib.request.Request(url, data=data,
        headers={"Content-Type": "application/json"} if data else {})
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

channels = [c for c in re.split(r"[, ]+", conf.get("ALERT_CHANNELS", "")) if c]

if "dingtalk" in channels and conf.get("DINGTALK_WEBHOOK"):
    url = conf["DINGTALK_WEBHOOK"]
    if conf.get("DINGTALK_SECRET"):
        sec = conf["DINGTALK_SECRET"]
        ts_s = str(int(time.time() * 1000))
        sign = base64.b64encode(hmac.new(sec.encode(),
            ("%s\n%s" % (ts_s, sec)).encode(), hashlib.sha256).digest()).decode()
        url = url + "&timestamp=" + ts_s + "&sign=" + urllib.parse.quote(sign, safe="")
    post(url, json.dumps({"msgtype": "markdown",
        "markdown": {"title": "Wazuh告警 L%s" % level, "text": text[:19900]}}).encode())

if "wechat" in channels and conf.get("WECHAT_WEBHOOK"):
    post(conf["WECHAT_WEBHOOK"],
        json.dumps({"msgtype": "markdown", "markdown": {"content": text[:4000]}}).encode())

if "telegram" in channels and conf.get("TG_BOT_TOKEN") and conf.get("TG_CHAT_ID"):
    body = urllib.parse.urlencode({"chat_id": conf["TG_CHAT_ID"], "text": text,
        "disable_web_page_preview": "true"}).encode()
    post("https://api.telegram.org/bot%s/sendMessage" % conf["TG_BOT_TOKEN"], body)
PYEOF
  chown wazuh:wazuh /var/ossec/integrations/custom-security
  chmod 750 /var/ossec/integrations/custom-security

  WAZUH_ALERT_LEVEL="$WAZUH_ALERT_LEVEL" python3 - <<'PYEOF'
import os
p = "/var/ossec/etc/ossec.conf"
s = open(p, encoding="utf-8").read()
if "custom-security" not in s:
    block = """  <integration>
    <name>custom-security</name>
    <hook_url>http://127.0.0.1:1515</hook_url>
    <level>%s</level>
    <alert_format>json</alert_format>
  </integration>
""" % os.environ["WAZUH_ALERT_LEVEL"]
    s = s.replace("</ossec_config>", block + "</ossec_config>")
    open(p, "w", encoding="utf-8").write(s)
PYEOF
  systemctl restart wazuh-manager 2>/dev/null || service wazuh-manager restart || \
    warn "wazuh-manager 重启失败"

  chgrp wazuh /etc/security-monitor.conf 2>/dev/null || true
  chmod 640 /etc/security-monitor.conf
  extract_wazuh_credentials
  log "Wazuh 部署完成! dashboard 账号密码见下方或 /root/wazuh-install.log"
}

setup_wazuh() {
  case "$INSTALL_WAZUH" in
    none)  log "跳过 Wazuh 安装" ;;
    agent) install_wazuh_agent ;;
    full)  setup_wazuh_full ;;
    *)     die "INSTALL_WAZUH 只能是 none/agent/full, 当前: $INSTALL_WAZUH" ;;
  esac
}
# ============================ 资源监控 ====================================
setup_resource_monitor() {
  log "配置资源监控 (CPU/内存/磁盘/负载 超阈值告警, 间隔 ${RES_INTERVAL}s)"

  cat > /usr/local/bin/resource-monitor.sh <<'RMEOF'
#!/usr/bin/env bash
# 资源监控 (CPU/内存/磁盘/负载 超阈值告警) - 由 install_security_monitor.sh 生成
# 用法: resource-monitor.sh [--loop|--once|--check|--test]
#   --loop  持续循环(systemd 默认)  --once  跑一轮(超阈值即告警)后退出
#   --check 干跑(只打印不发告警)    --test  强制发一条测试告警
set -u
CONF=/etc/security-monitor.conf
[ -f "$CONF" ] && . "$CONF"
ALERT=/usr/local/bin/security-alert.sh
INTERVAL="${RES_INTERVAL:-300}"
COOLDOWN="${RES_COOLDOWN:-1800}"
CPU_WARN="${RES_CPU_WARN:-80}";  CPU_CRIT="${RES_CPU_CRIT:-90}"
MEM_WARN="${RES_MEM_WARN:-80}";  MEM_CRIT="${RES_MEM_CRIT:-90}"
DISK_WARN="${RES_DISK_WARN:-80}"; DISK_CRIT="${RES_DISK_CRIT:-90}"
CORES="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)"
LOAD_WARN="${RES_LOAD_WARN:-$CORES}"
LOAD_CRIT="${RES_LOAD_CRIT:-$((CORES*2))}"
DISK_IGNORE="${RES_DISK_IGNORE:-}"
MODE="${1:---loop}"
NOW=0
declare -A LAST   # key -> 上次告警 epoch(冷却去重)

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# pct>=crit?critical ; pct>=warn?warning ; 否则空
sev_for() { local p="$1" w="$2" c="$3"; [ "$p" -ge "$c" ] && { echo critical; return; }; [ "$p" -ge "$w" ] && { echo warning; return; }; echo; }

# 浮点比较 a>=b ? (用 awk, 避免 bc 依赖)
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0>=b+0)}'; }

# 干跑时打印每个指标当前值(不论是否超阈值); 非干跑模式静默
print_status() {  # 指标 当前值 阈值文本 状态
  [ "$MODE" = "--check" ] || return
  local ind="$1" val="$2" thr="$3" st="${4:-正常}"
  printf '  [%s] %s = %s (阈值 %s)\n' "$st" "$ind" "$val" "$thr"
}

maybe_alert() {  # key sev 标题 正文
  local key="$1" sev="$2" title="$3" body="$4" last level
  if [ "$MODE" = "--check" ]; then
    printf '  → 将告警[%s] %s\n    %s\n' "$sev" "$title" "$(printf '%s\n' "$body" | head -3)"
    return
  fi
  last="${LAST[$key]:-0}"
  if [ "$((NOW - last))" -lt "$COOLDOWN" ]; then
    log "抑制告警(冷却 ${COOLDOWN}s 中, ${key}): $title"
    return
  fi
  LAST[$key]=$NOW
  level=warn; [ "$sev" = critical ] && level=high
  "$ALERT" "$title" "$body" "$level" 2>/dev/null \
    && log "已发送告警 [$sev]: $title" \
    || log "告警发送失败: $title (检查 $ALERT / 渠道配置)"
}

# ---- 各指标采样 ----
cpu_pct() {  # 返回整数百分比(采样1秒)
  local a b t1 i1 t2 i2 dt di
  # 用 printf "%d" 强制整数输出; 否则 uptime 长后 jiffies 累计超过 1e9,
  # awk 默认 OFMT=%.6g 会打成科学计数法 (如 4.61278e+09),
  # bash $(()) 无法解析 -> 'syntax error: invalid arithmetic operator'
  a=$(awk '/^cpu /{idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; printf "%d %d\n", t, idle; exit}' /proc/stat 2>/dev/null)
  sleep 1
  b=$(awk '/^cpu /{idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; printf "%d %d\n", t, idle; exit}' /proc/stat 2>/dev/null)
  read -r t1 i1 <<< "$a"; read -r t2 i2 <<< "$b"
  [ -n "$t1" ] && [ -n "$t2" ] || { echo 0; return; }
  dt=$((t2-t1)); di=$((i2-i1))
  [ "$dt" -le 0 ] && { echo 0; return; }
  echo $(( (dt-di)*100 / dt ))
}

mem_pct() {
  free -m 2>/dev/null | awk '/^Mem:/{ if(NF>=7 && $7+0>0) print int(($2-$7)*100/$2); else print int($3*100/$2); exit }'
}

check_disk() {
  local pct mnt sev skip igp st cnt=0
  local igarr=()
  [ -n "$DISK_IGNORE" ] && IFS=',' read -ra igarr <<< "$DISK_IGNORE"
  while IFS=$'\t' read -r pct mnt; do
    [ -n "$pct" ] && [ -n "$mnt" ] || continue
    skip=0
    for igp in "${igarr[@]}"; do case "$mnt" in "$igp"*) skip=1; break;; esac; done
    [ "$skip" = 1 ] && continue
    cnt=$((cnt+1))
    sev=$(sev_for "$pct" "$DISK_WARN" "$DISK_CRIT")
    st=正常; [ -n "$sev" ] && st=$sev
    print_status "磁盘 $mnt" "${pct}%" "告警${DISK_WARN}/严重${DISK_CRIT}" "$st"
    [ -n "$sev" ] || continue
    maybe_alert "disk:$mnt:$sev" "$sev" "💾 磁盘告警 ($sev)" \
"挂载点 $mnt 使用率 ${pct}% (阈值 告警 ${DISK_WARN}% / 严重 ${DISK_CRIT}%)

服务器: $(hostname)
$(df -h "$mnt" 2>/dev/null | tail -1)"
  done < <(df -x tmpfs -x devtmpfs -x squashfs -x iso9660 -x overlay -x fuse -x fuse.gvfsd-fuse --output=pcent,target 2>/dev/null \
           | awk 'NR>1{p=$1; sub(/%/,"",p); $1=""; sub(/^ +/,""); print p"\t"$0}')
  [ "$MODE" = "--check" ] && [ "$cnt" -eq 0 ] && print_status "磁盘" "无" "告警${DISK_WARN}/严重${DISK_CRIT}" "无挂载点"
}

check_cpu() {
  local p sev st
  p=$(cpu_pct)
  [ -n "$p" ] || { log "CPU 采样失败, 跳过"; return; }
  sev=$(sev_for "$p" "$CPU_WARN" "$CPU_CRIT")
  st=正常; [ -n "$sev" ] && st=$sev
  print_status "CPU" "${p}%" "告警${CPU_WARN}/严重${CPU_CRIT}" "$st"
  [ -n "$sev" ] || return
  maybe_alert "cpu:$sev" "$sev" "🖥️ CPU 告警 ($sev)" \
"CPU 使用率 ${p}% (阈值 告警 ${CPU_WARN}% / 严重 ${CPU_CRIT}%)

服务器: $(hostname)
负载: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)  核心: ${CORES}"
}

check_mem() {
  local p sev st
  p=$(mem_pct)
  [ -n "$p" ] || { log "内存采样失败, 跳过"; return; }
  sev=$(sev_for "$p" "$MEM_WARN" "$MEM_CRIT")
  st=正常; [ -n "$sev" ] && st=$sev
  print_status "内存" "${p}%" "告警${MEM_WARN}/严重${MEM_CRIT}" "$st"
  [ -n "$sev" ] || return
  maybe_alert "mem:$sev" "$sev" "🧠 内存告警 ($sev)" \
"内存使用率 ${p}% (阈值 告警 ${MEM_WARN}% / 严重 ${MEM_CRIT}%)

服务器: $(hostname)
$(free -h 2>/dev/null | head -2)"
}

check_load() {
  local load sev st
  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
  [ -n "$load" ] || { log "负载采样失败, 跳过"; return; }
  sev=""
  if ge "$load" "$LOAD_CRIT"; then sev=critical
  elif ge "$load" "$LOAD_WARN"; then sev=warning; fi
  st=正常; [ -n "$sev" ] && st=$sev
  print_status "负载" "$load" "告警${LOAD_WARN}/严重${LOAD_CRIT}" "$st"
  [ -n "$sev" ] || return
  maybe_alert "load:$sev" "$sev" "📊 负载告警 ($sev)" \
"系统 1 分钟负载 ${load} (阈值 告警 ${LOAD_WARN} / 严重 ${LOAD_CRIT}, CPU 核数 ${CORES})

服务器: $(hostname)
$(uptime)"
}

run_once() {
  NOW=$(date +%s)
  [ "$MODE" = "--check" ] && log "当前资源状态 (核心 ${CORES}, 阈值 CPU ${CPU_WARN}/${CPU_CRIT} 内存 ${MEM_WARN}/${MEM_CRIT} 磁盘 ${DISK_WARN}/${DISK_CRIT} 负载 ${LOAD_WARN}/${LOAD_CRIT})"
  check_disk
  check_cpu
  check_mem
  check_load
}

case "$MODE" in
  --check) run_once; log "干跑完成 (未发告警, 仅打印状态)" ;;
  --test)
    cpu=$(cpu_pct); mem=$(mem_pct)
    "$ALERT" "🧪 资源监控测试告警" \
"这是 resource-monitor 的测试告警, 收到表示资源告警链路已打通。

服务器: $(hostname)  CPU 核心: ${CORES}
CPU 使用率: ${cpu:-N/A}%
内存使用率: ${mem:-N/A}%
负载(1/5/15min): $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)

磁盘占用:
$(df -h 2>/dev/null | head -6)

内存:
$(free -h 2>/dev/null | head -2)" "info" \
      && log "测试告警已发送" || log "测试告警发送失败 (检查 $ALERT / 渠道配置)"
    ;;
  --once) run_once; log "单次检查完成" ;;
  --loop|"")
    log "资源监控启动 (间隔 ${INTERVAL}s, 冷却 ${COOLDOWN}s, 核心 ${CORES})"
    log "阈值 CPU ${CPU_WARN}/${CPU_CRIT}  内存 ${MEM_WARN}/${MEM_CRIT}  磁盘 ${DISK_WARN}/${DISK_CRIT}  负载 ${LOAD_WARN}/${LOAD_CRIT}"
    while true; do run_once; sleep "$INTERVAL"; done ;;
  *) echo "用法: $0 [--loop|--once|--check|--test]" >&2; exit 1 ;;
esac
RMEOF
  chmod 755 /usr/local/bin/resource-monitor.sh

  cat > /etc/systemd/system/resource-monitor.service <<'SVCEOF'
[Unit]
Description=Security Monitor - Resource threshold alerting (CPU/Mem/Disk/Load)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/resource-monitor.sh --loop
Restart=always
RestartSec=15
SyslogIdentifier=resource-monitor

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable --now resource-monitor >/dev/null 2>&1 \
    || warn "resource-monitor 启用失败, 可手动: systemctl enable --now resource-monitor"
  log "资源监控已启动 (systemd: resource-monitor, 干跑验证: resource-monitor.sh --check)"
}
# ============================ 每日巡检日报 ==================================
setup_daily_report() {
  log "配置每日安全巡检日报 (每天 08:00 推送)"

  cat > /usr/local/bin/security-daily-summary.sh <<'SUMEOF'
#!/usr/bin/env bash
# 每日安全巡检摘要 (由 install_security_monitor.sh 生成)
set -u
# cron 默认 PATH 仅 /usr/bin:/bin, 而 aureport/ausearch 在 /usr/sbin
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF=/etc/security-monitor.conf
[ -f "$CONF" ] && . "$CONF"
TMP=$(mktemp)
{
  echo "## 📋 每日安全巡检报告 $(date '+%F %T')"
  echo ""
  echo "### 1. 今日登录记录 (aureport, 最近25条)"
  aureport -l -i -ts today 2>/dev/null | tail -25 || echo "无记录"
  echo ""
  echo "### 2. 今日登录失败次数: $(aureport -l -i --failed -ts today 2>/dev/null | grep -cE '^[0-9]+\.' )"
  echo ""
  echo "### 3. 今日账户变更"
  ausearch -ts today -m ADD_USER,DEL_USER,ADD_GROUP,DEL_GROUP,CHUSER_ID,CHGRP_ID,USER_CHAUTHTOK 2>/dev/null | tail -20 || echo "无记录"
  echo ""
  echo "### 4. 当前被 fail2ban 封禁的 IP"
  fail2ban-client status sshd 2>/dev/null | sed -n '/Banned IP list/,+1p' || echo "无封禁"
  echo ""
  echo "### 5. 系统负载"
  uptime
} > "$TMP"
/usr/local/bin/security-alert.sh "每日安全巡检报告 $(date '+%F')" - < "$TMP"
rm -f "$TMP"
SUMEOF
  chmod 755 /usr/local/bin/security-daily-summary.sh

  cat > /etc/cron.d/security-monitor <<'CRONEOF'
SHELL=/bin/bash
# cron 默认 PATH 不含 /usr/sbin, 必须显式设置, 否则 aureport/ausearch 找不到
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# 每日 08:00 推送安全巡检日报
0 8 * * * root /usr/local/bin/security-daily-summary.sh >/dev/null 2>&1
CRONEOF
  chmod 644 /etc/cron.d/security-monitor

  cat > /etc/logrotate.d/security-alert <<'LGEOF'
/var/log/security-alert.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
}
LGEOF
  log "日报与日志轮转已配置"
}
# ================================ 时区设置 ===================================
# 支持将系统时区改为以下选项:
#   上海 / 北京            -> Asia/Shanghai (UTC+8)
#   巴基斯坦               -> Asia/Karachi  (UTC+5)
#   印度尼西亚首都(雅加达) -> Asia/Jakarta  (UTC+7)
# 首次修改会备份原 /etc/localtime 到 /etc/security-monitor-tz.orig, 卸载时可还原。
normalize_timezone() {  # TIMEZONE -> 规范化 tz 名
  case "$1" in
    ""|Asia/Shanghai|shanghai|上海|UTC+8|beijing|Beijing|北京)
      echo "Asia/Shanghai" ;;
    Asia/Karachi|pakistan|Pakistan|巴基斯坦|PKT|UTC+5)
      echo "Asia/Karachi" ;;
    Asia/Jakarta|indonesia|Indonesia|印度尼西亚|雅加达|jakarta|Jakarta|WIB|UTC+7)
      echo "Asia/Jakarta" ;;
    *)
      echo "$1" ;;  # 其他原样 (如 Asia/Tokyo), 存在 zoneinfo 文件即生效
  esac
}

setup_timezone() {
  local tz
  tz=$(normalize_timezone "$TIMEZONE")
  [ -n "$tz" ] || { warn "时区为空, 跳过"; return; }
  if [ ! -f "/usr/share/zoneinfo/$tz" ]; then
    warn "时区文件不存在: /usr/share/zoneinfo/$tz , 跳过 (可用如 Asia/Tokyo)"
    return
  fi
  # sysvinit 系统没有 /etc/timezone (仅 /etc/localtime), 判断是否用该文件
  local with_timezone_file=no
  [ -e /etc/timezone ] && with_timezone_file=yes

  # 首次修改时备份原时区, 供卸载还原
  if [ ! -f /etc/security-monitor-tz.orig ]; then
    [ -f /etc/localtime ] && cp -a /etc/localtime /etc/security-monitor-tz.orig 2>/dev/null || true
    log "已备份原时区到 /etc/security-monitor-tz.orig"
  fi

  log "正在设置系统时区: ${tz} ..."
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone "$tz" 2>/dev/null \
      || ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime 2>/dev/null
  else
    ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime 2>/dev/null
  fi
  if [ "$with_timezone_file" = yes ]; then
    echo "$tz" > /etc/timezone
  fi

  local now
  now=$(date '+%Z %z %F %T')
  log "时区已设置为 ${tz}, 当前系统时间: ${now}"

  # 让每日 08:00 日报按新时区执行 (cron 使用系统时区默认即可, 但显式声明更稳;
  # 仅当日报 cron 存在且尚未写 TZ 时追加一行)
  if [ -f /etc/cron.d/security-monitor ] && ! grep -qE '^TZ=' /etc/cron.d/security-monitor; then
    sed -i "/^PATH=/a\\TZ=${tz}" /etc/cron.d/security-monitor
    log "已为日报 cron 写入时区 (TZ=${tz})"
  fi
}

# =============================== 收尾 =======================================
test_alerts() {
  if [ -z "$ALERT_CHANNELS" ]; then
    warn "未配置告警渠道, 跳过测试告警 (可在 /etc/security-monitor.conf 后补配置)"
    return 0
  fi
  log "发送测试告警, 请检查你的告警渠道是否收到消息..."
  local host ip comps
  host=$(hostname)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  comps=""
  [ "$INSTALL_FAIL2BAN" = yes ] && comps="${comps:+$comps }Fail2ban"
  [ "$INSTALL_AUDITD" = yes ] && comps="${comps:+$comps }auditd"
  [ "$INSTALL_WAZUH" != none ] && comps="${comps:+$comps }Wazuh($INSTALL_WAZUH)"
  [ "$INSTALL_DAILY" = yes ] && comps="${comps:+$comps }每日巡检日报"
  [ "$INSTALL_RESOURCE_MONITOR" = yes ] && comps="${comps:+$comps }资源监控"
  [ "$INSTALL_TIMEZONE" = yes ] && comps="${comps:+$comps }时区设置(${TIMEZONE:-})"
  local body="服务器: ${host} (${ip})

已部署组件: ${comps:-无}
告警渠道: ${ALERT_CHANNELS}

此消息表示告警链路已打通。"
  /usr/local/bin/security-alert.sh "✅ 安全巡检部署完成" "$body" "info" \
    || warn "测试告警发送失败, 请检查 /etc/security-monitor.conf 配置"
}

summary() {
  echo ""
  echo "======================================================================"
  echo -e "${C_GREEN}  安全巡检系统部署完成!${C_OFF}"
  echo "======================================================================"
  echo "  常用命令:"
  echo "    查看封禁状态        fail2ban-client status sshd"
  echo "    手动解除封禁        fail2ban-client unban <IP>"
  echo "    查看审计规则        auditctl -l"
  echo "    查询命令审计记录    ausearch -k cmd_audit | aureport -i"
  echo "    查看告警历史        tail -f /var/log/security-alert.log"
  echo "    修改告警配置        vi /etc/security-monitor.conf"
  echo "    资源监控状态        systemctl status resource-monitor"
  echo "    资源监控干跑        resource-monitor.sh --check"
  echo "    资源告警测试        resource-monitor.sh --test"
  echo ""
  echo "  文件清单:"
  echo "    告警分发脚本        /usr/local/bin/security-alert.sh"
  echo "    审计实时监控器      /usr/local/bin/audit-alert-watcher.sh"
  echo "    资源监控脚本        /usr/local/bin/resource-monitor.sh"
  echo "    每日巡检脚本        /usr/local/bin/security-daily-summary.sh"
  if [ "$INSTALL_WAZUH" = "full" ]; then
    echo "    Wazuh 控制台        https://$(hostname -I 2>/dev/null | awk '{print $1}'):${DASHBOARD_PORT_USED:-443}"
    echo "    管理员账号          ${WAZUH_DASH_USER:-admin}"
    echo "    管理员密码          ${WAZUH_DASH_PASS:-见 /root/wazuh-install.log Summary 部分}"
    [ -n "${WAZUH_API_PASS:-}" ] && echo "    API 账号/密码       ${WAZUH_API_USER:-wazuh-wui} / ${WAZUH_API_PASS}"
    echo "    Wazuh 安装日志      /root/wazuh-install.log"
  fi
  echo ""
  echo "  注意事项:"
  echo "    - 若 SSH 端口不是 22, 请编辑 /etc/fail2ban/jail.local 改 port 后重启 fail2ban"
  echo "    - 如需监控 nginx/apache/ftp 等, 在 jail.local 添加对应监狱即可"
  echo "    - 卸载: 停用 audit-alert-watcher/fail2ban/wazuh-agent/resource-monitor 服务并删除对应包"
  echo "======================================================================"
}
# ================================ 卸载模式 ==================================
detect_installed() {
  HAVE_FAIL2BAN=no; HAVE_AUDITD=no; HAVE_WAZUH=none; HAVE_DAILY=no; HAVE_ALERT=no; HAVE_RESOURCE_MONITOR=no; HAVE_TIMEZONE=no
  if [ -f /etc/fail2ban/jail.local ] || [ -f /etc/fail2ban/action.d/security-alert.conf ]; then HAVE_FAIL2BAN=yes; fi
  if [ -f /etc/audit/rules.d/security.rules ]; then HAVE_AUDITD=yes; fi
  if [ -f /etc/cron.d/security-monitor ]; then HAVE_DAILY=yes; fi
  if [ -f /usr/local/bin/security-alert.sh ]; then HAVE_ALERT=yes; fi
  if [ -f /etc/systemd/system/resource-monitor.service ] || [ -f /usr/local/bin/resource-monitor.sh ]; then HAVE_RESOURCE_MONITOR=yes; fi
  # 脚本备份过原时区说明用过时区功能
  if [ -f /etc/security-monitor-tz.orig ]; then HAVE_TIMEZONE=yes; fi
  if { command -v dpkg >/dev/null 2>&1 && dpkg -l wazuh-manager 2>/dev/null | grep -q '^ii'; } || { command -v rpm >/dev/null 2>&1 && rpm -q wazuh-manager >/dev/null 2>&1; }; then
    HAVE_WAZUH=full
  elif { command -v dpkg >/dev/null 2>&1 && dpkg -l wazuh-agent 2>/dev/null | grep -q '^ii'; } || { command -v rpm >/dev/null 2>&1 && rpm -q wazuh-agent >/dev/null 2>&1; }; then
    HAVE_WAZUH=agent
  fi
}

cleanup_fail2ban() {
  log "清理 Fail2ban 配置..."
  systemctl disable --now fail2ban 2>/dev/null || service fail2ban stop >/dev/null 2>&1 || true
  rm -f /etc/fail2ban/jail.local /etc/fail2ban/action.d/security-alert.conf
  if [ "$REMOVE_PKGS" = "y" ]; then
    log "卸载 fail2ban 软件包..."
    if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get remove -y fail2ban || warn "fail2ban 卸载失败(可能未安装)"; else yum remove -y fail2ban || warn "fail2ban 卸载失败(可能未安装)"; fi
  fi
  log "Fail2ban 已清理"
}

cleanup_auditd() {
  log "清理 auditd 审计与告警监控..."
  systemctl disable --now audit-alert-watcher 2>/dev/null || true
  rm -f /etc/systemd/system/audit-alert-watcher.service
  systemctl daemon-reload 2>/dev/null || true
  rm -f /etc/audit/rules.d/security.rules
  if ! augenrules --load >/dev/null 2>&1; then
    # augenrules 不可用时, 仅清除本脚本添加的 key, 不影响用户其他规则
    for k in identity sudoers sshd cron dotfiles netconf systemd session cmd_audit; do
      auditctl -D -k "$k" 2>/dev/null || true
    done
  fi
  systemctl restart auditd 2>/dev/null || service auditd restart >/dev/null 2>&1 || true
  if [ "$REMOVE_PKGS" = "y" ]; then
    log "卸载 auditd 软件包..."
    if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get remove -y auditd || warn "auditd 卸载失败(可能未安装)"; else yum remove -y audit || warn "auditd 卸载失败(可能未安装)"; fi
  fi
  log "auditd 监控已清理"
}

cleanup_daily() {
  log "清理每日巡检日报..."
  rm -f /etc/cron.d/security-monitor
  rm -f /usr/local/bin/security-daily-summary.sh
  log "日报已清理"
}

cleanup_resource_monitor() {
  log "清理资源监控..."
  systemctl disable --now resource-monitor 2>/dev/null || true
  rm -f /etc/systemd/system/resource-monitor.service
  systemctl daemon-reload 2>/dev/null || true
  rm -f /usr/local/bin/resource-monitor.sh
  log "资源监控已清理"
}

cleanup_timezone() {
  log "还原系统时区并清理..."
  # 还原到脚本修改前的时区
  if [ -f /etc/security-monitor-tz.orig ]; then
    cp -a /etc/security-monitor-tz.orig /etc/localtime 2>/dev/null \
      && log "已还原原系统时区 (/etc/localtime 来自安装前备份)" \
      || warn "还原原时区失败, 请手动执行: timedatectl set-timezone <原时区>"
  else
    warn "未找到 /etc/security-monitor-tz.orig, 跳过还原 (当前时区不变)"
  fi
  # 移除我们给日报 cron 加的 TZ 行
  if [ -f /etc/cron.d/security-monitor ]; then
    sed -i '/^TZ=/d' /etc/cron.d/security-monitor 2>/dev/null || true
  fi
  rm -f /etc/security-monitor-tz.orig
  log "时区清理完成 (当前: $(date '+%Z %z'))"
}

cleanup_wazuh() {
  if [ "$HAVE_WAZUH" = full ]; then
    log "卸载 Wazuh 全套 (将移除 wazuh-manager/indexer/dashboard/agent 全部组件)..."
    if [ -f /root/wazuh-install.sh ]; then
      bash /root/wazuh-install.sh --uninstall </dev/null || warn "官方卸载未完全成功, 可手动: apt/yum remove wazuh-manager wazuh-indexer wazuh-dashboard wazuh-agent"
    else
      warn "未找到 /root/wazuh-install.sh, 改为手动卸载组件..."
      if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get remove -y wazuh-manager wazuh-indexer wazuh-dashboard wazuh-agent || warn "部分组件卸载失败"; else yum remove -y wazuh-manager wazuh-indexer wazuh-dashboard wazuh-agent || warn "部分组件卸载失败"; fi
    fi
    rm -f /var/ossec/integrations/custom-security
  elif [ "$HAVE_WAZUH" = agent ]; then
    log "卸载 Wazuh Agent..."
    systemctl disable --now wazuh-agent 2>/dev/null || true
    if [ "$REMOVE_PKGS" = "y" ]; then
      if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get remove -y wazuh-agent || warn "wazuh-agent 卸载失败"; else yum remove -y wazuh-agent || warn "wazuh-agent 卸载失败"; fi
    fi
    warn "如需要, 请在 Wazuh manager 上手动移除该 agent"
  else
    warn "未检测到 Wazuh, 跳过"
  fi
  rm -f /etc/apt/sources.list.d/wazuh.list /etc/yum.repos.d/wazuh.repo /usr/share/keyrings/wazuh.gpg
  log "Wazuh 已清理"
}

cleanup_alert() {
  log "清理告警脚本与配置..."
  rm -f /usr/local/bin/security-alert.sh
  rm -f /etc/security-monitor.conf
  rm -f /etc/logrotate.d/security-alert
  rm -f /var/log/security-alert.log
  log "告警配置已清理"
  warn "如曾配置邮件告警, /etc/mail.rc 中追加的 SMTP 配置需手动移除"
}

uninstall() {
  banner
  echo ""
  echo -e "${C_YELLOW}⚠️  卸载模式: 将删除安全巡检相关配置, 请确认后操作${C_OFF}"
  detect_installed

  echo -e "${C_CYAN}检测到以下组件:${C_OFF}"
  echo "    Fail2ban 监控     : $([ "$HAVE_FAIL2BAN" = yes ] && echo 已安装 || echo 未检测到)"
  echo "    auditd 审计监控   : $([ "$HAVE_AUDITD" = yes ] && echo 已安装 || echo 未检测到)"
  echo "    Wazuh             : $([ "$HAVE_WAZUH" != none ] && echo "已安装 ($HAVE_WAZUH)" || echo 未检测到)"
  echo "    每日巡检日报      : $([ "$HAVE_DAILY" = yes ] && echo 已安装 || echo 未检测到)"
  echo "    资源监控          : $([ "$HAVE_RESOURCE_MONITOR" = yes ] && echo 已安装 || echo 未检测到)"
  echo "    (时区)            : $([ "$HAVE_TIMEZONE" = yes ] && echo "曾修改过(可还原到安装前)" || echo 未检测到)"
  echo "    告警脚本与配置    : $([ "$HAVE_ALERT" = yes ] && echo 已安装 || echo 未检测到)"
  echo ""

  choose "选择要卸载的组件 (可多选):" DEL_SEL "no" "all" "全部(1-6)" \
    "1|Fail2ban 配置" \
    "2|auditd 审计与告警监控" \
    "3|Wazuh ($HAVE_WAZUH)" \
    "4|每日巡检日报" \
    "5|告警脚本与配置" \
    "6|资源监控" \
    "7|时区(还原到安装前)"

  prompt REMOVE_PKGS "是否同时卸载软件包 (y=卸载包, n=仅删配置, 默认 n)" "n"
  case "$(printf '%s' "$REMOVE_PKGS" | tr 'A-Z' 'a-z')" in y|yes) REMOVE_PKGS=y ;; *) REMOVE_PKGS=n ;; esac

  local n
  DO_FAIL2BAN=no; DO_AUDITD=no; DO_WAZUH=no; DO_DAILY=no; DO_ALERT=no; DO_RESOURCE_MONITOR=no; DO_TIMEZONE=no
  case "$DEL_SEL" in
    all) DO_FAIL2BAN=yes; DO_AUDITD=yes; DO_WAZUH=yes; DO_DAILY=yes; DO_ALERT=yes; DO_RESOURCE_MONITOR=yes; DO_TIMEZONE=yes ;;
    *) IFS=',' read -ra d_arr <<< "$DEL_SEL"
       for n in "${d_arr[@]}"; do
         n="${n## }"; n="${n%% }"
         case "$n" in
           1) DO_FAIL2BAN=yes ;; 2) DO_AUDITD=yes ;; 3) DO_WAZUH=yes ;; 4) DO_DAILY=yes ;; 5) DO_ALERT=yes ;; 6) DO_RESOURCE_MONITOR=yes ;; 7) DO_TIMEZONE=yes ;;
           *) warn "忽略未知卸载选项: $n" ;;
         esac
       done ;;
  esac

  echo ""
  echo -e "${C_YELLOW}=============== 卸载清单确认 ===============${C_OFF}"
  local items=""
  [ "$DO_FAIL2BAN" = yes ] && items="${items:+$items, }Fail2ban"
  [ "$DO_AUDITD" = yes ] && items="${items:+$items, }auditd监控"
  [ "$DO_WAZUH" = yes ] && items="${items:+$items, }Wazuh"
  [ "$DO_DAILY" = yes ] && items="${items:+$items, }每日日报"
  [ "$DO_RESOURCE_MONITOR" = yes ] && items="${items:+$items, }资源监控"
  [ "$DO_TIMEZONE" = yes ] && items="${items:+$items, }时区(还原)"
  [ "$DO_ALERT" = yes ] && items="${items:+$items, }告警配置"
  echo "  将清理: ${items:-无}"
  echo "  是否卸载软件包: $REMOVE_PKGS"
  echo -e "${C_YELLOW}==============================================${C_OFF}"
  confirm "确认执行卸载? 此操作不可恢复" || die "已取消卸载"

  [ "$DO_FAIL2BAN" = yes ] && cleanup_fail2ban
  [ "$DO_AUDITD" = yes ] && cleanup_auditd
  [ "$DO_WAZUH" = yes ] && cleanup_wazuh
  [ "$DO_DAILY" = yes ] && cleanup_daily
  [ "$DO_RESOURCE_MONITOR" = yes ] && cleanup_resource_monitor
  [ "$DO_TIMEZONE" = yes ] && cleanup_timezone
  [ "$DO_ALERT" = yes ] && cleanup_alert
  log "卸载完成!"
}

# ================================ 主流程 ====================================
main() {
  require_root
  detect_os

  case "${1:-}" in
    --uninstall|--remove|-u)
      uninstall
      exit 0 ;;
  esac

  AUTO=0
  [ "${1:-}" = "--auto" ] && AUTO=1

  if [ "$AUTO" -eq 0 ]; then
    interactive_config
  else
    # 自动模式: 组件开关需显式指定 (环境变量), 否则跳过
    log "自动模式: 组件开关 INSTALL_FAIL2BAN=$INSTALL_FAIL2BAN INSTALL_AUDITD=$INSTALL_AUDITD INSTALL_WAZUH=$INSTALL_WAZUH INSTALL_DAILY=$INSTALL_DAILY INSTALL_RESOURCE_MONITOR=$INSTALL_RESOURCE_MONITOR"
    log "自动模式: 告警渠道 ALERT_CHANNELS=${ALERT_CHANNELS:-未配置}"
    if [ "$INSTALL_FAIL2BAN" = no ] && [ "$INSTALL_AUDITD" = no ] && [ "$INSTALL_WAZUH" = none ] && [ "$INSTALL_DAILY" = no ] && [ "$INSTALL_RESOURCE_MONITOR" = no ] && [ "$INSTALL_TIMEZONE" = no ]; then
      die "--auto 模式未指定任何组件, 示例: INSTALL_FAIL2BAN=yes INSTALL_AUDITD=yes INSTALL_DAILY=yes bash $0 --auto"
    fi
  fi

  install_base
  setup_alert_scripts
  [ "$INSTALL_FAIL2BAN" = yes ] && setup_fail2ban
  [ "$INSTALL_AUDITD" = yes ] && { setup_auditd; setup_audit_watcher; }
  [ "$INSTALL_WAZUH" != none ] && setup_wazuh
  [ "$INSTALL_DAILY" = yes ] && setup_daily_report
  [ "$INSTALL_RESOURCE_MONITOR" = yes ] && setup_resource_monitor
  [ "$INSTALL_TIMEZONE" = yes ] && setup_timezone
  test_alerts
  summary
}

main "$@"
