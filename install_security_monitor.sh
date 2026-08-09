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
#  适用系统: CentOS/RHEL/Rocky/Alma 7-9, Ubuntu 18.04-24.04, Debian 10-12
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
WAZUH_VERSION_DEFAULT="4.10"                     # 在线检测失败时的兜底版本
WAZUH_DASHBOARD_PORT="${WAZUH_DASHBOARD_PORT:-443}" # Web 控制台端口(若被占用自动改 8443)
WAZUH_MANAGER_ADDR="${WAZUH_MANAGER_ADDR:-}" # agent 模式: manager 服务器 IP/域名
WAZUH_AGENT_NAME="${WAZUH_AGENT_NAME:-$(hostname)}"
WAZUH_ALERT_LEVEL="${WAZUH_ALERT_LEVEL:-10}" # Wazuh 告警阈值(>=该级别推送)

# Fail2ban
F2B_MAXRETRY="${F2B_MAXRETRY:-5}"          # 窗口内失败次数
F2B_FINDTIME="${F2B_FINDTIME:-10m}"        # 统计窗口
F2B_BANTIME="${F2B_BANTIME:-1h}"           # 封禁时长
F2B_IGNOREIP="${F2B_IGNOREIP:-127.0.0.1}"  # 白名单(空格分隔)

# auditd
AUDIT_EXECVE="${AUDIT_EXECVE:-yes}"        # 是否审计全部命令(日志量大)
# ============================ 默认值配置区结束 ==============================

# 安装开关 (交互模式选择后设置, 自动模式默认全关, 由环境变量开启)
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-no}"
INSTALL_AUDITD="${INSTALL_AUDITD:-no}"
INSTALL_WAZUH="${INSTALL_WAZUH:-none}"    # none / agent / full
INSTALL_DAILY="${INSTALL_DAILY:-no}"

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

# 多选: choose <标题> <结果变量> <允许0> "编号|描述" ...
choose() {
  local title="$1" var="$2" allow0="$3"; shift 3
  local opt ans
  echo ""
  echo -e "${C_CYAN}$title${C_OFF}"
  for opt in "$@"; do
    echo "    ${opt%%|*} ) ${opt#*|}"
  done
  [ "$allow0" = "yes" ] && echo "    0 ) 不配置/跳过"
  printf "  请输入编号(逗号分隔多选, 直接回车=默认): "
  if ! read -r ans; then echo ""; die "输入已中断 (EOF), 安装取消"; fi
  printf -v "$var" '%s' "$ans"
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
  choose "请选择要安装的组件 (可多选):" COMP_SEL "no" \
    "1|Fail2ban     - 暴力破解自动封禁 (推荐)" \
    "2|auditd       - 登录/账户/命令审计+实时告警 (推荐)" \
    "3|Wazuh Agent  - 上报到已有的 Wazuh manager" \
    "4|Wazuh 全套   - 本机整套部署 (需 >=4G 内存)" \
    "5|每日巡检日报  - 每天08:00推送安全摘要"
  COMP_SEL="${COMP_SEL:-1,2,5}"
  local n
  INSTALL_FAIL2BAN=no; INSTALL_AUDITD=no; INSTALL_WAZUH=none; INSTALL_DAILY=no
  case "$COMP_SEL" in
    all) INSTALL_FAIL2BAN=yes; INSTALL_AUDITD=yes; INSTALL_DAILY=yes ;;
    *) IFS=',' read -ra comp_arr <<< "$COMP_SEL"
       for n in "${comp_arr[@]}"; do
         case "$n" in
           1) INSTALL_FAIL2BAN=yes ;;
           2) INSTALL_AUDITD=yes ;;
           3) INSTALL_WAZUH="agent" ;;
           4) INSTALL_WAZUH="full" ;;
           5) INSTALL_DAILY=yes ;;
         esac
       done ;;
  esac
  if [ "$INSTALL_FAIL2BAN" = no ] && [ "$INSTALL_AUDITD" = no ] && [ "$INSTALL_WAZUH" = none ] && [ "$INSTALL_DAILY" = no ]; then
    die "未选择任何组件, 退出安装"
  fi

  # ---------- 2. Wazuh 参数 ----------
  if [ "$INSTALL_WAZUH" = "agent" ]; then
    prompt WAZUH_MANAGER_ADDR "Wazuh manager 服务器地址 (IP或域名)" "${WAZUH_MANAGER_ADDR:-}"
    [ -n "$WAZUH_MANAGER_ADDR" ] || die "agent 模式必须提供 manager 地址"
  elif [ "$INSTALL_WAZUH" = "full" ]; then
    local mem latest
    mem=$(free -m | awk '/^Mem:/{print $2}')
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

  # ---------- 3. 选择告警渠道 ----------
  choose "请选择告警推送渠道 (可多选):" CH_SEL "yes" \
    "1|钉钉机器人" \
    "2|企业微信机器人" \
    "3|Telegram Bot" \
    "4|邮件 (SMTP)"
  CH_SEL="${CH_SEL:-}"
  local channels=""
  case "$CH_SEL" in
    0|"") channels="" ;;
    all) channels="dingtalk,wechat,telegram,email" ;;
    *) IFS=',' read -ra ch_arr <<< "$CH_SEL"
       for n in "${ch_arr[@]}"; do
         case "$n" in
           1) channels="${channels:+$channels,}dingtalk" ;;
           2) channels="${channels:+$channels,}wechat" ;;
           3) channels="${channels:+$channels,}telegram" ;;
           4) channels="${channels:+$channels,}email" ;;
         esac
       done ;;
  esac
  ALERT_CHANNELS="$channels"

  # ---------- 4. 各渠道参数 ----------
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

  # ---------- 5. Fail2ban / auditd 参数 ----------
  if [ "$INSTALL_FAIL2BAN" = yes ]; then
    echo ""
    echo -e "${C_CYAN}--- Fail2ban 参数 (直接回车用默认) ---${C_OFF}"
    prompt F2B_MAXRETRY "失败多少次触发封禁" "$F2B_MAXRETRY"
    prompt F2B_FINDTIME "统计窗口(例: 10m/1h)" "$F2B_FINDTIME"
    prompt F2B_BANTIME "封禁时长(例: 1h/1d)" "$F2B_BANTIME"
    prompt F2B_IGNOREIP "白名单IP(空格分隔)" "$F2B_IGNOREIP"
  fi
  if [ "$INSTALL_AUDITD" = yes ]; then
    prompt AUDIT_EXECVE "是否审计全部命令执行 (yes/no, 日志量大)" "$AUDIT_EXECVE"
  fi

  # ---------- 6. 确认 ----------
  echo ""
  echo -e "${C_YELLOW}=============== 安装清单确认 ===============${C_OFF}"
  local comps=""
  [ "$INSTALL_FAIL2BAN" = yes ] && comps="${comps:+$comps, }Fail2ban"
  [ "$INSTALL_AUDITD" = yes ] && comps="${comps:+$comps, }auditd"
  [ "$INSTALL_WAZUH" != none ] && comps="${comps:+$comps, }Wazuh($INSTALL_WAZUH)"
  [ "$INSTALL_DAILY" = yes ] && comps="${comps:+$comps, }每日巡检日报"
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
    eval "$UPDATE"
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
    eval "$INST $pkgs"
  fi
  command -v python3 >/dev/null 2>&1 || die "缺少 python3, 无法完成安装"
  log "依赖安装完成"
}
# ============================ 告警分发脚本 ==================================
setup_alert_scripts() {
  log "生成告警配置 /etc/security-monitor.conf"
  cat > /etc/security-monitor.conf <<EOF
# 安全告警渠道配置 (由安装脚本生成, 可手动修改)
ALERT_CHANNELS="${ALERT_CHANNELS}"
DINGTALK_WEBHOOK="${DINGTALK_WEBHOOK}"
DINGTALK_SECRET="${DINGTALK_SECRET}"
WECHAT_WEBHOOK="${WECHAT_WEBHOOK}"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"
EMAIL_TO="${EMAIL_TO}"
SMTP_SERVER="${SMTP_SERVER}"
SMTP_USER="${SMTP_USER}"
SMTP_PASS="${SMTP_PASS}"
SMTP_FROM="${SMTP_FROM}"
EOF
  chmod 600 /etc/security-monitor.conf

  log "生成告警分发脚本 /usr/local/bin/security-alert.sh"
  cat > /usr/local/bin/security-alert.sh <<'ALERTEOF'
#!/usr/bin/env bash
# 安全告警分发脚本
# 用法: security-alert.sh <标题> <正文(或 - 表示从 stdin 读取)> [级别: info|warn|high]
set -u
CONF=/etc/security-monitor.conf
[ -f "$CONF" ] && . "$CONF"

TITLE="${1:-安全告警}"
BODY="${2:--}"
LEVEL="${3:-high}"
[ "$BODY" = "-" ] && BODY="$(cat)"

echo "[$(date '+%F %T')] [$LEVEL] $TITLE :: $(echo "$BODY" | head -c 300)" >> /var/log/security-alert.log

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
  local json
  json=$(python3 -c '
import json,sys
print(json.dumps({"msgtype":"markdown","markdown":{"title":sys.argv[1],"text":sys.argv[2][:19900]}}))' "$TITLE" "$BODY")
  curl -sS -m 10 -H 'Content-Type: application/json' -d "$json" "$url" >/dev/null 2>&1 \
    || { err "[钉钉] 发送失败"; return 1; }
  ok "[钉钉] 已发送"
}

send_wechat() {
  [ -z "${WECHAT_WEBHOOK:-}" ] && return 1
  local json
  json=$(python3 -c '
import json,sys
print(json.dumps({"msgtype":"markdown","markdown":{"content":"**"+sys.argv[1]+"**\n\n"+sys.argv[2][:4000]}}))' "$TITLE" "$BODY")
  curl -sS -m 10 -H 'Content-Type: application/json' -d "$json" "$WECHAT_WEBHOOK" >/dev/null 2>&1 \
    || { err "[企业微信] 发送失败"; return 1; }
  ok "[企业微信] 已发送"
}

send_telegram() {
  [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ] && return 1
  curl -sS -m 10 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=[${LEVEL}] ${TITLE}%0A%0A${BODY}" >/dev/null 2>&1 \
    || { err "[Telegram] 发送失败"; return 1; }
  ok "[Telegram] 已发送"
}

send_email() {
  [ -z "${EMAIL_TO:-}" ] && return 1
  command -v mail >/dev/null 2>&1 || { err "[邮件] 缺少 mail 命令"; return 1; }
  printf '%s\n' "$BODY" | mail -s "[安全告警] ${TITLE}" "$EMAIL_TO" >/dev/null 2>&1 \
    || { err "[邮件] 发送失败"; return 1; }
  ok "[邮件] 已发送"
}

ok()   { echo -e "\033[1;32m[+]\033[0m $*"; }
err()  { echo -e "\033[1;31m[-]\033[0m $*" >&2; }

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
    printf 'set smtp=%s\nset smtp-auth=login\nset smtp-auth-user=%s\nset smtp-auth-password=%s\nset from=%s\nset ssl-verify=ignore\n' \
      "$SMTP_SERVER" "$SMTP_USER" "$SMTP_PASS" "$SMTP_FROM" >> /etc/mail.rc 2>/dev/null || true
    log "已写入 /etc/mail.rc SMTP 配置"
  fi
}
# ============================== Fail2ban ====================================
setup_fail2ban() {
  log "配置 Fail2ban (封禁 ${F2B_BANTIME}, 窗口 ${F2B_FINDTIME}, 阈值 ${F2B_MAXRETRY} 次)"

  cat > /etc/fail2ban/action.d/security-alert.conf <<'ACTEOF'
# 自定义告警动作: 封禁/解封时推送多渠道通知
[Definition]
actionban   = /usr/local/bin/security-alert.sh "🚫 Fail2ban 封禁" "IP <ip> 在服务 <port>/<protocol> 上失败 <failures> 次, 封禁时长 <bantime> 秒" "high"
actionunban = /usr/local/bin/security-alert.sh "✅ Fail2ban 解封" "IP <ip> 已解封 (服务 <port>/<protocol>)" "info"

[Init]
ACTEOF

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
port    = ssh
EOF

  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban 2>/dev/null || service fail2ban restart || \
    warn "fail2ban 启动失败, 请检查日志 /var/log/fail2ban.log"
  sleep 2
  fail2ban-client status sshd >/dev/null 2>&1 && log "Fail2ban 已运行, sshd 监狱已启用" \
    || warn "fail2ban sshd 监狱未就绪, 可稍后手动执行: fail2ban-client status sshd"
}
# =============================== auditd =====================================
set_auparam() {
  local key="$1" val="$2" f=/etc/audit/auditd.conf
  if grep -q "^${key} *=" "$f"; then
    sed -i "s|^${key} *=.*|${key} = ${val}|" "$f"
  else
    echo "${key} = ${val}" >> "$f"
  fi
}

setup_auditd() {
  log "配置 auditd (登录/账户/命令审计)"

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

AUTHFAIL=/tmp/.security_authfail
alert() { /usr/local/bin/security-alert.sh "$1" "$2" "${3:-high}"; }
getf()  { echo "$1" | tr -d "\"'" | sed -n "s/.*$2=\([^ ]*\).*/\1/p" | head -1; }

DANGEROUS_PATTERNS='bash -i|sh -i|/dev/tcp/|/dev/udp/|nc -[a-zA-Z0-9]*e |ncat -[a-zA-Z0-9]*e |netcat|socat|mkfifo|curl[^|]*[|] *(ba)?sh|wget[^|]*[|] *(ba)?sh|base64 -d|echo.*>>.*/etc/passwd|echo.*>>.*/etc/sudoers|useradd -o|usermod -o|dpkg -i|rpm -ivh'

echo "[*] 审计告警监控器已启动: $(date '+%F %T')"
tail -n0 -F "$LOG" | while IFS= read -r line; do
  case "$line" in
    type=USER_LOGIN*)
      acct=$(getf "$line" acct); addr=$(getf "$line" addr); exe=$(getf "$line" exe); res=$(getf "$line" res)
      if [ "$res" = "success" ]; then
        alert "🖥 新登录" "用户 **${acct}** 通过 ${exe} 从 ${addr} 登录 ($(date '+%F %T'))" "warn"
        rm -f "$AUTHFAIL"
      fi
      ;;
    type=USER_AUTH*)
      res=$(getf "$line" res)
      if [ "$res" = "failed" ]; then
        n=$(( $(cat "$AUTHFAIL" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$AUTHFAIL"
        case "$n" in 5|10|20|40|80) alert "🚨 疑似暴力破解" "登录失败已达 ${n} 次, 攻击IP: $(getf "$line" addr)" "high";; esac
      fi
      ;;
    type=USER_ADD*|type=USER_DEL*|type=USER_CHAUTHTOK*)
      acct=$(getf "$line" acct); id=$(getf "$line" id)
      alert "👤 账户变更" "类型: $(echo "$line" | cut -d' ' -f1 | cut -d= -f2)  账户: ${acct} (uid=${id})" "high"
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
Wants=auditd.service

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
    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring \
      --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import >/dev/null 2>&1 && \
      chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
      > /etc/apt/sources.list.d/wazuh.list
    eval "$UPDATE"
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
  sed -i "s|<address>.*</address>|<address>${WAZUH_MANAGER_ADDR}</address>|" /var/ossec/etc/ossec.conf
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
  # dashboard admin: Summary 块中不带时间戳前缀的 "Password:" 行
  WAZUH_DASH_PASS=$(grep -E '^\s*Password: ' "$logf" | head -1 | sed 's/^\s*[Pp]assword: *//' | tr -d '\r') || true
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
  mem=$(free -m | awk '/^Mem:/{print $2}')
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

  # 检测 Web 端口是否被占用, 被占用则自动改用 8443
  if [ "$dash_port" = "443" ] && \
     ( ss -tlnp 2>/dev/null | grep -q ':443 ' || netstat -tlnp 2>/dev/null | grep -q ':443 ' ); then
    warn "端口 443 已被其他进程占用, Wazuh Web 控制台将改用 8443"
    warn "如需其他端口: WAZUH_DASHBOARD_PORT=xxxx bash $0"
    dash_port=8443
  fi
  DASHBOARD_PORT_USED="$dash_port"
  log "Wazuh Web 控制台端口: ${dash_port}"
  log "开始安装 Wazuh 全套, 预计 10-20 分钟, 日志: /root/wazuh-install.log"
  bash /root/wazuh-install.sh -a -i -p "$dash_port" > /root/wazuh-install.log 2>&1 \
    || die "Wazuh 安装失败, 请查看 /root/wazuh-install.log (结尾有错误原因; 重跑可加 --overwrite)"

  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port=1514/tcp --add-port=1515/tcp --add-port=55000/tcp --add-port=443/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  elif command -v ufw >/dev/null 2>&1; then
    ufw allow 1514/tcp; ufw allow 1515/tcp; ufw allow 443/tcp >/dev/null 2>&1 || true
  fi

  log "配置 Wazuh 告警转发到聊天渠道"
  cat > /var/ossec/integrations/custom-security <<'PYEOF'
#!/usr/bin/env python3
# Wazuh -> 多渠道告警转发 (由 install_security_monitor.sh 生成)
import json, sys, hmac, hashlib, base64, time, urllib.parse, urllib.request, re

conf = {}
try:
    for line in open("/etc/security-monitor.conf", encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        conf[k.strip()] = v.strip().strip('"').strip("'")
except Exception:
    pass

try:
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
# ============================ 每日巡检日报 ==================================
setup_daily_report() {
  log "配置每日安全巡检日报 (每天 08:00 推送)"

  cat > /usr/local/bin/security-daily-summary.sh <<'SUMEOF'
#!/usr/bin/env bash
# 每日安全巡检摘要 (由 install_security_monitor.sh 生成)
set -u
. /etc/security-monitor.conf
TMP=$(mktemp)
{
  echo "## 📋 每日安全巡检报告 $(date '+%F %T')"
  echo ""
  echo "### 1. 今日登录成功 (最近20条)"
  ausearch -ts today -m USER_LOGIN --success yes 2>/dev/null | tr -d '"' \
    | grep -oE 'acct=[^ ]*|addr=[^ ]*|exe=[^ ]*' | tail -60 || echo "无记录"
  echo ""
  echo "### 2. 今日登录失败次数: $(ausearch -ts today -m USER_AUTH --success no 2>/dev/null | wc -l)"
  echo ""
  echo "### 3. 今日账户变更"
  ausearch -ts today -m USER_ADD,USER_DEL,USER_CHAUTHTOK 2>/dev/null | tail -20 || echo "无记录"
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
  /usr/local/bin/security-alert.sh "✅ 安全巡检部署完成
服务器: ${host} (${ip})

已部署组件: ${comps:-无}
告警渠道: ${ALERT_CHANNELS}

此消息表示告警链路已打通。" "info" \
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
  echo ""
  echo "  文件清单:"
  echo "    告警分发脚本        /usr/local/bin/security-alert.sh"
  echo "    审计实时监控器      /usr/local/bin/audit-alert-watcher.sh"
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
  echo "    - 卸载: 停用 audit-alert-watcher/fail2ban/wazuh-agent 服务并删除对应包"
  echo "======================================================================"
}
# ================================ 卸载模式 ==================================
detect_installed() {
  HAVE_FAIL2BAN=no; HAVE_AUDITD=no; HAVE_WAZUH=none; HAVE_DAILY=no; HAVE_ALERT=no
  if [ -f /etc/fail2ban/jail.local ] || [ -f /etc/fail2ban/action.d/security-alert.conf ]; then HAVE_FAIL2BAN=yes; fi
  if [ -f /etc/audit/rules.d/security.rules ]; then HAVE_AUDITD=yes; fi
  if [ -f /etc/cron.d/security-monitor ]; then HAVE_DAILY=yes; fi
  if [ -f /usr/local/bin/security-alert.sh ]; then HAVE_ALERT=yes; fi
  if dpkg -l wazuh-manager 2>/dev/null | grep -q '^ii' || rpm -q wazuh-manager >/dev/null 2>&1; then
    HAVE_WAZUH=full
  elif dpkg -l wazuh-agent 2>/dev/null | grep -q '^ii' || rpm -q wazuh-agent >/dev/null 2>&1; then
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
  augenrules --load >/dev/null 2>&1 || auditctl -D >/dev/null 2>&1 || true
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

cleanup_wazuh() {
  if [ "$HAVE_WAZUH" = full ]; then
    log "卸载 Wazuh 全套 (将移除 wazuh-manager/indexer/dashboard/agent 全部组件)..."
    if [ -f /root/wazuh-install.sh ]; then
      bash /root/wazuh-install.sh --uninstall || warn "官方卸载未完全成功, 可手动: apt/yum remove wazuh-manager wazuh-indexer wazuh-dashboard wazuh-agent"
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
  echo "    告警脚本与配置    : $([ "$HAVE_ALERT" = yes ] && echo 已安装 || echo 未检测到)"
  echo ""

  choose "选择要卸载的组件 (可多选, 直接回车=全部):" DEL_SEL "no" \
    "1|Fail2ban 配置" \
    "2|auditd 审计与告警监控" \
    "3|Wazuh ($HAVE_WAZUH)" \
    "4|每日巡检日报" \
    "5|告警脚本与配置"
  DEL_SEL="${DEL_SEL:-all}"

  prompt REMOVE_PKGS "是否同时卸载软件包 (y=卸载包, n=仅删配置, 默认 n)" "n"

  local n
  DO_FAIL2BAN=no; DO_AUDITD=no; DO_WAZUH=no; DO_DAILY=no; DO_ALERT=no
  case "$DEL_SEL" in
    all) DO_FAIL2BAN=yes; DO_AUDITD=yes; DO_WAZUH=yes; DO_DAILY=yes; DO_ALERT=yes ;;
    *) IFS=',' read -ra d_arr <<< "$DEL_SEL"
       for n in "${d_arr[@]}"; do
         case "$n" in
           1) DO_FAIL2BAN=yes ;; 2) DO_AUDITD=yes ;; 3) DO_WAZUH=yes ;; 4) DO_DAILY=yes ;; 5) DO_ALERT=yes ;;
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
  [ "$DO_ALERT" = yes ] && items="${items:+$items, }告警配置"
  echo "  将清理: ${items:-无}"
  echo "  是否卸载软件包: $REMOVE_PKGS"
  echo -e "${C_YELLOW}==============================================${C_OFF}"
  confirm "确认执行卸载? 此操作不可恢复" || die "已取消卸载"

  [ "$DO_FAIL2BAN" = yes ] && cleanup_fail2ban
  [ "$DO_AUDITD" = yes ] && cleanup_auditd
  [ "$DO_WAZUH" = yes ] && cleanup_wazuh
  [ "$DO_DAILY" = yes ] && cleanup_daily
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
    log "自动模式: 组件开关 INSTALL_FAIL2BAN=$INSTALL_FAIL2BAN INSTALL_AUDITD=$INSTALL_AUDITD INSTALL_WAZUH=$INSTALL_WAZUH INSTALL_DAILY=$INSTALL_DAILY"
    if [ "$INSTALL_FAIL2BAN" = no ] && [ "$INSTALL_AUDITD" = no ] && [ "$INSTALL_WAZUH" = none ] && [ "$INSTALL_DAILY" = no ]; then
      die "--auto 模式未指定任何组件, 示例: INSTALL_FAIL2BAN=yes INSTALL_AUDITD=yes INSTALL_DAILY=yes bash $0 --auto"
    fi
  fi

  install_base
  setup_alert_scripts
  [ "$INSTALL_FAIL2BAN" = yes ] && setup_fail2ban
  [ "$INSTALL_AUDITD" = yes ] && { setup_auditd; setup_audit_watcher; }
  [ "$INSTALL_WAZUH" != none ] && setup_wazuh
  [ "$INSTALL_DAILY" = yes ] && setup_daily_report
  test_alerts
  summary
}

main "$@"
