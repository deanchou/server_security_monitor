# 安全巡检系统一键部署脚本

Linux 服务器自动化安全巡检部署工具：**Fail2ban（暴力破解防护）+ auditd（审计）+ Wazuh（HIDS，可选）+ 多渠道实时告警（钉钉 / 企业微信 / Telegram / 邮件）+ 资源水位告警（CPU/内存/磁盘/负载，可选）+ 每日安全日报**。

单脚本、交互式/自动双模式，支持 Debian / Ubuntu / RHEL / CentOS / Rocky / Alma / Fedora。

---

## 功能特性

| 组件 | 说明 |
|------|------|
| **Fail2ban** | SSH 暴力破解自动封禁（次数/窗口/时长/白名单可配），封禁与解封实时推送告警 |
| **auditd** | 登录/账户变更/关键文件（passwd、shadow、ssh 配置、cron、.ssh 等）/危险命令（反弹 shell、管道 curl\|bash、base64 解码等）审计，实时监控可疑事件 |
| **Wazuh**（可选） | Agent 模式：上报到已有 manager；全套模式：本机部署 manager+indexer+dashboard（官方 all-in-one），告警自动转发到聊天渠道 |
| **每日巡检日报** | 每天 00:00 推送：**昨日**登录记录与失败次数（ausearch USER_LOGIN，与实时登录提醒完全同源）、账户变更（auditd，中文化）、当前封禁 IP、系统负载与内存/磁盘（封禁与负载为实时快照）|
| **资源监控**（可选） | CPU/内存/磁盘/负载 超阈值实时告警（systemd 周期采集，两级阈值 warn/critical，冷却去重防刷屏）|
| **时区修改**（可选） | 一键将系统时区设为 上海 / 北京 / 巴基斯坦 / 印度尼西亚首都(雅加达)；首次修改自动备份原时区，卸载时可还原 |
| **多渠道告警** | 钉钉（支持加签）/ 企业微信 / Telegram / 邮件，可多选；统一告警脚本 `/usr/local/bin/security-alert.sh` |

## 环境要求

- **系统**：Debian 10-13 / Ubuntu 18.04-24.04 / RHEL、CentOS、Rocky、Alma 7-9 / Fedora（需能访问外网安装软件包）
- **权限**：必须 root（`sudo`）
- **内存**：仅 Fail2ban+auditd 约 512MB；**Wazuh 全套需 ≥4GB**（官方要求，脚本会检测并提示）
- **依赖**：脚本自动安装 `curl`、`openssl`、`python3` 等

## 快速开始

### 1. 上传脚本（注意保持 LF 换行）

```bash
scp install_security_monitor.sh root@服务器IP:/root/
```

> ⚠️ **不要**用记事本/WinSCP 文本模式/复制粘贴上传，会导致 Windows 换行（CRLF）报错。若报 `$'\r': command not found` 或 `set: pipefail: invalid option`：
> ```bash
> sed -i 's/\r$//' install_security_monitor.sh
> ```

### 2. 交互式安装（推荐）

```bash
bash install_security_monitor.sh
```

按提示依次选择：

1. **组件**（可多选，回车默认 `1,2,5,6`）：
   - `1` Fail2ban · `2` auditd · `3` Wazuh Agent · `4` Wazuh 全套 · `5` 每日日报 · `6` 资源监控
   - `7` 时区修改：按提示选择 上海 / 北京 / 巴基斯坦 / 印度尼西亚首都(雅加达)
   - 输入 `all` 安装 1,2,5,6（不含 Wazuh）
2. Wazuh 参数（选了 Wazuh 才问）：agent 需填 manager 地址；全套会**在线检测最新版本**（如 4.14.7），回车用最新，也可指定旧版
3. **告警渠道**（可多选，直接回车=不配置即仅写本地日志不推送，`0` 同效）：1 钉钉 · 2 企业微信 · 3 Telegram · 4 邮件
4. 各渠道的 Webhook/Token/邮箱等参数（重装/升级时会自动读取已有 `/etc/security-monitor.conf` 作为默认值并回显，直接回车即保留原值；密钥类只显示前缀）
5. Fail2ban / auditd 阈值参数（选了 `7` 时还会询问要设置的时区）
6. 确认清单 → 开始安装

安装结束会**发送一条测试告警**验证链路，并打印常用命令与文件清单。

### 3. 自动模式（--auto，批量部署）

用环境变量直接指定，不询问：

```bash
# 例1: Fail2ban + auditd + 日报, 钉钉告警
INSTALL_FAIL2BAN=yes INSTALL_AUDITD=yes INSTALL_DAILY=yes \
ALERT_CHANNELS=dingtalk DINGTALK_WEBHOOK='https://oapi.dingtalk.com/robot/send?access_token=xxx' \
bash install_security_monitor.sh --auto

# 例2: 仅装 Wazuh Agent 上报到已有 manager, Telegram 告警
INSTALL_WAZUH=agent WAZUH_MANAGER_ADDR='10.0.0.5' \
ALERT_CHANNELS=telegram TG_BOT_TOKEN='xxx' TG_CHAT_ID='123456' \
bash install_security_monitor.sh --auto

# 例3: 仅修改时区为巴基斯坦 (UTC+5)
INSTALL_TIMEZONE=yes TIMEZONE=Asia/Karachi \
bash install_security_monitor.sh --auto

# 例4: 时区联动安全巡检一起设 (北京时区)
INSTALL_FAIL2BAN=yes INSTALL_DAILY=yes INSTALL_TIMEZONE=yes TIMEZONE=Asia/Shanghai \
bash install_security_monitor.sh --auto
```

> 自动模式默认**全部组件关闭**，未指定任何组件会报错退出（防误装）。

## 环境变量参考（自动模式）

| 变量 | 默认 | 说明 |
|------|------|------|
| `INSTALL_FAIL2BAN` | no | yes 安装 Fail2ban |
| `INSTALL_AUDITD` | no | yes 安装 auditd |
| `INSTALL_WAZUH` | none | `agent` / `full` |
| `INSTALL_DAILY` | no | yes 配置每日日报 |
| `INSTALL_TIMEZONE` | no | yes 修改系统时区 |
| `TIMEZONE` | 中文交互选择 | 时区名，支持 `Asia/Shanghai`(上海/北京)、`Asia/Karachi`(巴基斯坦)、`Asia/Jakarta`(印尼首都雅加达)、或任何 `/usr/share/zoneinfo/` 下存在的时区（如 `Asia/Tokyo`） |
| `ALERT_CHANNELS` | 空 | 逗号分隔：`dingtalk,wechat,telegram,email` |
| `DINGTALK_WEBHOOK` / `DINGTALK_SECRET` | 空 | 钉钉机器人地址 / 加签密钥（可选） |
| `WECHAT_WEBHOOK` | 空 | 企业微信机器人地址 |
| `TG_BOT_TOKEN` / `TG_CHAT_ID` | 空 | Telegram Bot Token / Chat ID |
| `EMAIL_TO` `SMTP_SERVER` `SMTP_USER` `SMTP_PASS` `SMTP_FROM` | 空 | 邮件告警（SMTP） |
| `F2B_MAXRETRY` | 5 | 窗口内失败次数阈值 |
| `F2B_FINDTIME` | 10m | 统计窗口 |
| `F2B_BANTIME` | 1h | 封禁时长 |
| `F2B_IGNOREIP` | 127.0.0.1 | 白名单（空格分隔） |
| `AUDIT_EXECVE` | yes | 是否审计全部命令执行（日志量大） |
| `WAZUH_VERSION` | 空（自动检测最新） | 指定版本如 `4.9` |
| `WAZUH_DASHBOARD_PORT` | 443 | Wazuh Web 端口（被占用自动改 8443） |
| `WAZUH_MANAGER_ADDR` | 空 | agent 模式必填：manager 地址 |
| `WAZUH_ALERT_LEVEL` | 10 | Wazuh 告警阈值（≥该级别推送） |
| `INSTALL_RESOURCE_MONITOR` | no | yes 安装资源监控（CPU/内存/磁盘/负载 阈值告警）|
| `RES_CPU_WARN` / `RES_CPU_CRIT` | 80 / 90 | CPU 告警 / 严重阈值（%）|
| `RES_MEM_WARN` / `RES_MEM_CRIT` | 80 / 90 | 内存 告警 / 严重阈值（%）|
| `RES_DISK_WARN` / `RES_DISK_CRIT` | 80 / 90 | 磁盘 告警 / 严重阈值（%）|
| `RES_LOAD_WARN` / `RES_LOAD_CRIT` | 空 | 负载 1 分钟告警 / 严重阈值；空 = 自动取 CPU 核数 / 核数×2 |
| `RES_INTERVAL` | 300 | 检查间隔（秒）|
| `RES_COOLDOWN` | 1800 | 同一指标重复告警冷却（秒，防刷屏）|
| `RES_DISK_IGNORE` | 空 | 忽略的挂载点（逗号分隔，如 `/snap,/mnt/backup`）|

## 时区修改说明

选中 `7 时区修改`（或自动模式 `INSTALL_TIMEZONE=yes`）后，脚本会把系统时区设为所选地区：

| 选项 | 具体时区 | UTC 偏移 | 说明 |
|------|----------|----------|------|
| 上海 | `Asia/Shanghai` | UTC+8 | 中国标准时间（北京时间属于同一时区） |
| 北京 | `Asia/Shanghai` | UTC+8 | 与上海同为东八区，IANA 无独立 `Asia/Beijing`，统一使用 `Asia/Shanghai` |
| 巴基斯坦 | `Asia/Karachi` | UTC+5 | 巴基斯坦标准时间（卡拉奇） |
| 印度尼西亚（首都） | `Asia/Jakarta` | UTC+7 | 印尼首都雅加达（WIB 西区） |

行为说明：

- **北京与上海是同一时区**（均为 `Asia/Shanghai`，UTC+8），IANA 时区库里北京没有独立条目，故两者都映射到 `Asia/Shanghai`。
- 脚本通过 `timedatectl set-timezone`（无 systemd 时直接软链接 `/etc/localtime`）设置，并同步更新 `/etc/timezone`。
- 首次修改会**自动备份原时区**到 `/etc/security-monitor-tz.orig`，卸载（选项 7）时自动还原回安装前的时区。
- 若已安装每日日报，脚本会给 `/etc/cron.d/security-monitor` 追加 `TZ=` 行，确保每天 00:00 的日报按新时区执行。
- 时区独立于其他组件，可仅修改时区而不装任何安全组件。

## 告警渠道获取方法

| 渠道 | 获取方法 |
|------|---------|
| **钉钉** | 群设置 → 智能群助手 → 添加机器人 → 自定义 → 复制 Webhook；安全设置可选"加签"（填密钥） |
| **企业微信** | 企业微信群 → 添加群机器人 → 复制 Webhook 地址 |
| **Telegram** | 找 [@BotFather](https://t.me/BotFather) 创建 Bot 拿 Token；向 [@userinfobot](https://t.me/userinfobot) 发消息拿 Chat ID |
| **邮件** | 任意支持 SMTP 的邮箱；QQ 邮箱等需用**授权码**而非登录密码 |

## 告警脚本行为说明

`/usr/local/bin/security-alert.sh` 是统一告警分发入口，Fail2ban/auditd/资源监控/每日日报/部署完成测试均调用它。几个关键行为：

- **主机名前缀**：所有告警标题自动加 `[主机名]` 前缀（如 `[web01] 💾 磁盘告警`）。多台服务器共用同一个钉钉群/Telegram bot/邮箱时，一眼区分来源，无需在每个告警源单独配置。
- **响应真实校验**：钉钉/企业微信/Telegram 的 API **失败也返回 HTTP 200**（带 `errcode≠0` 或 `"ok":false`），脚本解析 JSON 判断真实成败，失败如实报 `errcode`/`error_code` + 描述，**不会误报「已发送」**。
- **Telegram 自动去 markdown**：告警正文含 `**粗体**`/`## 标题`/`- 列表`/`` `代码` `` 等 markdown 语法（钉钉/企业微信原生渲染），但 Telegram 不解析这些符号、会原样外露。脚本在发送前把 markdown 剥成纯文本（`**粗体**→粗体`、`## 标题→标题`、`- 项→• 项`、分割线删除），Telegram 显示干净可读，不依赖 `parse_mode`、不会因转义失败丢消息。
- **Telegram 429 自动重试**：多机并发高频告警可能触发限流（`error_code=429` + `retry_after`），脚本按 `retry_after` 秒退避**最多重试 3 次**，仍失败才报错；重试期间不影响其它渠道。
- **多服务器共用一个 Telegram bot**：脚本只发送（`sendMessage`）、不接收（不 `getUpdates`/不 webhook），无「抢 bot」冲突；唯一风险是上述 429 限流，已自动重试。
- **告警日志**：每次分发都写一行到 `/var/log/security-alert.log`（保留 30 天，见 `/etc/logrotate.d/security-alert`），可 `tail -f` 追溯。
- **手动调用**：
  ```bash
  /usr/local/bin/security-alert.sh "标题" "正文"            # 默认级别 high
  /usr/local/bin/security-alert.sh "标题" "正文" info      # info/warn/high
  /usr/local/bin/security-alert.sh "标题" - <<<"从 stdin 读正文"   # 长正文/管道
  ```
- **级别语义**：`info`（部署完成/解封等常规通知）、`warn`（资源警告级、新登录）、`high`（封禁、疑似爆破、可疑命令、资源严重级）。邮件主题带 `[安全告警]`，Telegram 文本带级别 emoji（🟢 info / 🟡 warn / 🔴 high）替代原 `[info]`/`[warn]`/`[high]` 文本前缀。
- **配置热更新**：改完 `/etc/security-monitor.conf`（渠道参数/资源阈值）**无需重启任何服务**——每次告警都是新进程重新 source 该 conf，下次触发即生效。

## Wazuh 说明

- **版本自动检测**：优先使用在线检测到的最新正式版（GitHub API，超时 15s），失败回退内置默认 4.14；下载目录自动取主次版本号（如 4.14.7 → `packages.wazuh.com/4.14/`）
- **端口冲突**：443 被占用时自动改用 8443（部署后按提示访问 `https://IP:8443`）
- **Debian 兼容**：wazuh-install.sh 硬性依赖 Ubuntu 特有的 `software-properties-common` 包，脚本自动创建 dummy 包跳过检查
- **安装日志**：`/root/wazuh-install.log`，dashboard 管理员账号密码也在里面
- **账号密码自动提取**：安装完成后脚本自动解析日志，将 dashboard `admin` 密码、API `wazuh-wui` 密码（日志无则从 dashboard 配置 `wazuh.yml` 提取）直接显示在部署摘要里，无需手动翻日志
- **全套安装**：10-20 分钟，内存不足会警告并带 `-i` 忽略官方检测（高风险，不建议 <4G 强装）
- **agent 模式**：自动配置 manager 地址并重启 agent；如要注册 agent 需在 manager 上另行授权（`wazuh-agent` 官方注册流程）

## Wazuh 安装后基础配置（实现基本安全检测）

Wazuh 全套装好后，下面几步让它真正“在做检测”。核心结论：**Wazuh 自带的检测大多默认开启，主要做两件事——(1) 登录 Dashboard 确认/改密码，(2) 给要监控的服务器注册 Agent**；其余是确认与调优。

### 0. 先理清“谁在被监控”

- **本机（装了 manager 的这台）**：manager 自带 `agent 000`（即 manager 自己），**默认就跑 SCA / FIM / rootkit / 资产清单 / 漏洞扫描**，无需再装 agent。
- **其它服务器**：必须装并注册 `wazuh-agent` 才能监控。本脚本只在主机装 Wazuh 全套，不自动装远端 agent。

### 1. 登录 Dashboard + 改密码

```bash
# 1a. 取 admin 初始密码（wazuh-install.sh 生成时已存盘）
cat /wazuh-install-files/wazuh-install-files/passwords.wazuh.txt 2>/dev/null | grep -A1 admin
# 或重新生成/查看：
# /var/ossec/scripts/wazuh-passwords-tool.sh -a   # 会随机化

# 1b. 确认服务都起来了
systemctl status wazuh-manager wazuh-indexer wazuh-dashboard --no-pager

# 1c. 浏览器访问
#   https://<本机IP>:<WAZUH_DASHBOARD_PORT，默认443，被占时8443>
#   用户名 admin，密码见上
```

首次登录后建议立刻改 admin 密码：

```bash
/var/ossec/scripts/wazuh-passwords-tool.sh -u admin -p '你的强密码'
```

### 2. 注册被监控服务器的 Agent（关键步骤）

> 只监控本机一台可跳过本节——manager(000) 已覆盖。

**2a. 开防火墙端口（manager 侧）**：agent 与 manager 通信需要两个端口，安装脚本默认只开了 dashboard 端口，需补开：

```bash
# 1514/UDP  = agent 上报数据
# 1515/TCP  = agent 注册(enrollment, authd)
ufw allow 1514/udp 1515/tcp     # 或对应 iptables/firewalld
```

**2b. 用 Dashboard 向导注册（最省事）**：Dashboard → **Server management → Deploy new agents** → 选操作系统 → 填 agent IP（可选）→ 生成一条形如 `curl ... | sudo bash` 的一键安装命令，拷到被监控服务器执行。向导已把 manager 地址、注册口令烘焙进命令。

或用命令行（manager 侧）：

```bash
/var/ossec/bin/manage_agents -a <agent_IP> -n <昵称>     # 注册
/var/ossec/bin/manage_agents -l                          # 列出
```

被监控机装 agent 后编辑 `/var/ossec/etc/ossec.conf`：

```xml
<client>
  <server><address>本机(manager)IP</address>...</server>
</client>
```

重启 agent：`systemctl restart wazuh-agent`，在 Dashboard → Agents 看「Active」即连上。

### 3. 基础安全检查（多数默认开，逐项确认即可）

Wazuh 的检测由 agent 端采集 + manager 端规则解码两段组成。下面各项基本默认开启，确认 agent `ossec.conf` 没被关即可（manager 000 同理）：

| 检查项 | ossec.conf 片段 | Dashboard 模块 | 默认 |
|---|---|---|---|
| **SCA 基线扫描**（CIS 配置合规）| `<sca><enabled>yes</enabled>` | Security Configuration Assessment | ✅开 |
| **Rootkit/恶意软件**（隐藏进程/端口/可疑文件）| `<rootcheck>` | （并入 Security events）| ✅开 |
| **文件完整性 FIM**（监控 `/etc`、`/usr/bin` 等关键目录）| `<syscheck>` | Integrity Monitoring | ✅开 |
| **资产清单**（软件包/进程/端口/用户）| `<syscollector>` | Inventory | ✅开 |
| **漏洞检测**（CVE 比对已装软件）| manager 端 `<vulnerability-detector>` | Vulnerabilities | ✅开但**需联网拉 CVE 源** |
| **日志收集**（auth.log / syslog / 应用日志）| `<localfile>` | Security events | ✅开 |
| **MITRE ATT&CK 映射** | 规则内置 tag | MITRE ATT&CK | ✅开 |

确认某个 agent 是否真在跑这些（在被监控机执行）：

```bash
/var/ossec/bin/wazuh-control status        # 各子模块 running?
grep -E '<sca|<syscheck|<rootcheck|<syscollector|<vulnerability' /var/ossec/etc/ossec.conf
```

**漏洞检测注意**：`<vulnerability-detector>` 默认开启但依赖 manager **联网下载 NVD / Debian / Canonical / RedHat 等 CVE 源**，离线环境拉不到源 → 该模块空白属正常。首次拉源要等几分钟~几十分钟。看进度：

```bash
tail -f /var/ossec/logs/ossec.log | grep -i vulnerab
```

### 4. 让 Wazuh 也消费你已有的 auditd（推荐，避免割裂）

本脚本已在每台机装了 auditd + `audit-alert-watcher`（把高危审计事件推到你的 Telegram/钉钉/企微）。Wazuh 同样能解码 auditd 事件并映射 MITRE，建议让 **agent 读 `/var/log/audit/audit.log`**，在 Dashboard 里集中可见：

在被监控机 `/var/ossec/etc/ossec.conf` 加：

```xml
<localfile>
  <log_format>audit</log_format>
  <location>/var/log/audit/audit.log</location>
</localfile>
```

重启 agent：`systemctl restart wazuh-agent`。

> 与本脚本 `audit-alert-watcher` 的分工建议：
> - **Wazuh** → Dashboard 集中可视化、MITRE 映射、长期留存、合规报告；
> - **audit-alert-watcher → security-alert.sh → IM 通道** → 实时手机推送。
> 两者读同一份 `audit.log` 不冲突，互补。若嫌重复推送，可二选一（一般保留 IM 推送做即时、Wazuh 做分析）。

### 5. 验证检测真的生效（30 秒自测）

在任一被监控机触发几条事件，然后去 Dashboard → **Security events** 看是否亮灯：

```bash
# 触发 ① 账户变更
sudo useradd -m testuser && sudo userdel -r testuser
# 触发 ② FIM
echo "wazuh-fim-test" | sudo tee -a /etc/wazuh-test      # 之后可删
# 触发 ③ SCA 重跑
/var/ossec/bin/wazuh-control restart client
```

manager 侧实时看告警：

```bash
tail -f /var/ossec/logs/alerts/alerts.json | python3 -m json.tool
```

Dashboard 各模块几秒~1分钟内应出现对应条目。若 Security events 空，多半是 agent 没连上（步骤 2 没做好）。

### 6. 调优要点（可选，基础跑通后再做）

1. **告警级别门槛**：Dashboard 默认显示 level ≥ 3。想只看高危，加 filter `rule.level >= 7`。level 12+ 多为入侵确证，可据此做 IM 推送门槛。
2. **Agent 分组**：按角色建 group（web/db/dba…），下发不同 `ossec.conf`（不同 FIM 路径、不同 SCA 策略），比逐台改高效。
3. **SCA 策略裁剪**：默认对每个 OS 都跑对应 CIS 策略，条目几百~上千。只关心强要求的，在 group 配置里 `policies` 只列你要的那几份，减少噪声。
4. **FIM 白名单**：`/etc` 下高频变动文件（如 `/etc/resolv.conf`）加 `<ignore>`，避免告警刷屏。
5. **Wazuh 告警进你的 IM**：Wazuh 全套模式已通过本脚本内置的 `custom-security` 集成，把 level ≥ `WAZUH_ALERT_LEVEL`（默认 10）的告警转发到钉钉/企业微信/Telegram（与本脚本的 fail2ban/auditd/资源监控共用同一套渠道配置）。改阈值改 `/etc/security-monitor.conf` 后无需重启 Wazuh（集成脚本每次调用重新读取）。

### 小结清单（按顺序做）

- [ ] 登录 Dashboard、改 admin 密码（步骤 1）
- [ ] 若监控其它机：开 1514/1515、用向导注册 agent（步骤 2）
- [ ] 确认 SCA/FIM/rootcheck/syscollector/vulnerability-detector 都 `yes`（步骤 3 表）
- [ ] 让 agent 读 `audit.log`，与本脚本 watcher 互补（步骤 4）
- [ ] 触发自测事件，Dashboard 各模块亮灯（步骤 5）
- [ ] 按需做分组/SCA 裁剪/FIM 白名单（步骤 6）

做到步骤 5，**“基本安全检查”就真正落地了**：配置基线合规、文件篡改、rootkit、资产清单、CVE 漏洞、登录/账户异常全在 Dashboard 可见，高危项还能经 `custom-security` 集成推到你手机。

## 生成的文件清单

| 路径 | 说明 |
|------|------|
| `/etc/security-monitor.conf` | 告警渠道配置（权限 600，可手动改后重启服务生效） |
| `/usr/local/bin/security-alert.sh` | 统一告警分发脚本（可直接手动调用：`security-alert.sh "标题" "内容"`） |
| `/usr/local/bin/audit-alert-watcher.sh` | auditd 实时监控器（systemd: `audit-alert-watcher`） |
| `/usr/local/bin/security-daily-summary.sh` | 每日日报脚本 |
| `/etc/fail2ban/jail.local` | Fail2ban 配置（含封禁/解封告警动作） |
| `/etc/fail2ban/action.d/security-alert.conf` | Fail2ban 告警动作定义 |
| `/etc/audit/rules.d/security.rules` | 审计规则（关键文件 + 命令审计） |
| `/etc/systemd/system/audit-alert-watcher.service` | 监控器 systemd 单元 |
| `/etc/cron.d/security-monitor` | 每日 00:00 日报 cron |
| `/etc/logrotate.d/security-alert` | 告警日志轮转（保留 30 天） |
| `/var/ossec/integrations/custom-security` | Wazuh→聊天渠道告警转发（仅全套模式） |
| `/usr/local/bin/resource-monitor.sh` | 资源监控脚本（CPU/内存/磁盘/负载 阈值告警，仅 `INSTALL_RESOURCE_MONITOR=yes`）|
| `/etc/systemd/system/resource-monitor.service` | 资源监控 systemd 单元（`--loop` 周期采集）|
| `/etc/security-monitor-tz.orig` | 修改时区前备份的原时区（仅 `INSTALL_TIMEZONE=yes` 时生成，卸载时还原）|
| `/var/log/security-alert.log` | 告警发送历史 |

## 常用命令

```bash
fail2ban-client status sshd          # 查看封禁状态
fail2ban-client unban 1.2.3.4        # 手动解封
auditctl -l                          # 查看已加载审计规则
ausearch -k cmd_audit | aureport -i  # 查询命令审计记录
ausearch -ts today -m USER_LOGIN --success yes   # 今日登录成功
journalctl -u audit-alert-watcher    # 监控器日志
tail -f /var/log/security-alert.log  # 告警历史
systemctl restart wazuh-manager      # Wazuh 告警转发改动后重启
systemctl status resource-monitor      # 资源监控运行状态
resource-monitor.sh --check            # 干跑一次, 打印各指标状态(不发告警)
resource-monitor.sh --test             # 强制发一条测试告警验证渠道
journalctl -u resource-monitor -f      # 资源监控日志
```

### Wazuh 常用命令

**服务与状态**（部署 Wazuh 全套后）

```bash
systemctl status wazuh-manager wazuh-indexer wazuh-dashboard   # 三组件运行状态
systemctl restart wazuh-manager                                 # 重启 manager（规则/集成改动后生效）
systemctl restart wazuh-indexer                                 # 重启索引引擎
systemctl restart wazuh-dashboard                               # 重启 Web 控制台
/var/ossec/bin/wazuh-control status                            # 查看 wazuh 各进程状态
/var/ossec/bin/wazuh-control info                              # 版本与编译信息
/usr/share/wazuh-indexer/bin/wazuh-indexer --version           # indexer 版本
```

**Agent 管理**（在 manager 上执行）

```bash
/var/ossec/bin/agent_control -l              # 列出所有 agent 及连接状态
/var/ossec/bin/agent_control -i <agent-id>   # 查看指定 agent 详情
/var/ossec/bin/agent_control -R <agent-id>   # 远程重启指定 agent
/var/ossec/bin/agent_control -s -a           # 同步配置到所有 agent
/var/ossec/bin/agent_control -r -a           # 移除所有失联 agent（慎用）
/var/ossec/bin/manage_agents                 # 交互式 agent 管理（导入/导出 key）
```

**日志与告警**（manager 上）

```bash
tail -f /var/ossec/logs/ossec.log            # manager 运行日志
journalctl -u wazuh-manager --since today    # manager 服务日志
journalctl -u wazuh-agent -f                 # 本机 agent 日志
cat /var/ossec/logs/client.keys              # agent 注册 key 列表
```

**告警查询**（manager 上）

```bash
tail -f /var/ossec/logs/alerts/alerts.json   # 实时告警（JSON 格式）
tail -f /var/ossec/logs/alerts/alerts.log    # 实时告警（纯文本格式）
grep -c '"rule.level"' /var/ossec/logs/alerts/alerts.json                  # 今日告警总数
grep '"rule.level" : 1[0-9]' /var/ossec/logs/alerts/alerts.json | tail    # 只看高等级(≥10)告警
```

**规则 / 解码器调试**

```bash
/var/ossec/bin/wazuh-logtest                # 交互式测试：粘贴一条日志看匹配哪条规则
/var/ossec/bin/verify_rules -r /var/ossec/etc/rules/local_rules.xml        # 校验自定义规则文件
```

**Indexer 引擎**

```bash
curl -k -u admin:<密码> "https://localhost:9200/_cluster/health?pretty"   # 集群健康状态
curl -k -u admin:<密码> "https://localhost:9200/_cat/indices?v"           # 索引列表与大小
curl -k -u admin:<密码> "https://localhost:9200/_cat/nodes?v"             # 节点状态
```

**API（端口 55000，勿暴露公网）**

```bash
# 获取 API token（用户 wazuh-wui，密码见 /root/wazuh-install.log）
TOKEN=$(curl -k -u wazuh-wui:<密码> -X POST "https://localhost:55000/security/user/authenticate" \
  -H "Content-Type: application/json" | python3 -c "import json,sys;print(json.load(sys.stdin)['data']['token'])")
curl -k -H "Authorization: Bearer $TOKEN" "https://localhost:55000/agents?limit=10"   # 查询 agent 列表
curl -k -H "Authorization: Bearer $TOKEN" "https://localhost:55000/alerts?limit=5"    # 查询最近告警
```

**存储与维护**

```bash
df -h /var/ossec /var/lib/wazuh-indexer      # 检查磁盘（索引数据增长快，建议单独分区）
/var/ossec/bin/wazuh-db -s                   # manager 数据库状态
# 索引生命周期管理(ILM)策略默认 90 天，可在 dashboard 的 Stack Management 中调整
```

> 凭据说明：dashboard 的 `admin` 用户、API 的 `wazuh-wui` 用户、indexer 的 `admin` 用户密码均记录在 **/root/wazuh-install.log**。安装完成后脚本会自动提取并在摘要中显示；也可随时 `grep -A1 'User: admin' /root/wazuh-install.log` 查看。

## Wazuh Dashboard 反向代理（Caddy / Nginx）

脚本默认让 dashboard 直接监听 `443`（被占用则 `8443`），并对外放行该端口。生产环境建议把 dashboard 收回回环、用 Caddy 或 Nginx 在前面做 TLS 终结，只暴露反代端口。三个关键点：① dashboard 自带 HTTPS + **自签证书**，上游需跳过证书校验或信任其 CA；② OpenSearch Security 插件需信任代理的 `X-Forwarded-*`，否则登录 cookie/重定向会失效；③ 443 可能与反代冲突，需让出。

### 0. 确认现状

```bash
ss -tlnp | grep -E ':443 |:8443 '                      # 当前监听地址/端口
grep -E 'server\.(host|port)' /etc/wazuh-dashboard/opensearch_dashboards.yml
```

### 1. 把 dashboard 收回 127.0.0.1 （可选）

编辑 `/etc/wazuh-dashboard/opensearch_dashboards.yml`：

```yaml
server.host: "127.0.0.1"              # 只听回环, 外部无法直连
server.port: 8443                     # 挑一个本机端口, 避开 443
server.xforwarded.supportedProxies: ["127.0.0.1/32"]   # 信任本机反代的转发头
```

```bash
systemctl restart wazuh-dashboard
ss -tlnp | grep 8443                  # 应只见 127.0.0.1:8443
```

### 2a. Caddy（推荐，自动 HTTPS）

```bash
# Debian/Ubuntu 安装(官方源)
apt install -y debian-keyring gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy.list
apt update && apt install caddy
# RHEL 系: dnf install 'dnf-command(copr)' && dnf copr enable @caddy/caddy && dnf install caddy
```

`/etc/caddy/Caddyfile`：

```caddyfile
wazuh.example.com {
    reverse_proxy https://127.0.0.1:8443 {
        transport http {
            tls
            tls_insecure_skip_verify            # 上游自签证书, 本机直连可跳过
            # 或更严谨: tls_trusted_ca_cert_file /etc/wazuh-dashboard/certs/root-ca.pem
        }
        header_up Host {host}                  # 透传域名, 让 cookie/重定向基于该域名
    }
}
# 无域名/内网用自签内部 CA: 把首行换成 ":443 {" 并在块内加 "tls internal"
```

```bash
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

### 2b. Nginx

```bash
apt install -y nginx   # 或 dnf install nginx
```

在 `nginx.conf` 的 `http {}` 顶部加（WebSocket 升级映射，只需一处）：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

`/etc/nginx/conf.d/wazuh.conf`：

```nginx
server {
    listen 443 ssl http2;
    server_name wazuh.example.com;

    ssl_certificate     /etc/letsencrypt/live/wazuh.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/wazuh.example.com/privkey.pem;
    # 证书可用 certbot --nginx -d wazuh.example.com 自动申请

    # 上游 dashboard 是 HTTPS + 自签证书
    proxy_ssl_verify off;            # 或 proxy_ssl_trusted_certificate /etc/wazuh-dashboard/certs/root-ca.pem;
    proxy_ssl_server_name on;

    client_max_body_size 50m;         # 允许上传报告/CSV 导出
    proxy_read_timeout  300s;        # 长查询/报告生成
    proxy_send_timeout  300s;

    # OpenSearch Dashboards 响应头较大, 默认 buffer 会 502 "upstream sent too big header"
    proxy_buffer_size        128k;
    proxy_buffers            4 256k;
    proxy_busy_buffers_size 512k;

    location / {
        proxy_pass https://127.0.0.1:8443;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        # WebSocket（实时日志/报告）
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }
}

server {                               # http → https 跳转
    listen 80;
    server_name wazuh.example.com;
    return 301 https://$host$request_uri;
}
```

```bash
nginx -t && systemctl reload nginx
```

### 3. 防火墙

```bash
# 放行反代 443
firewall-cmd --permanent --add-service=https && firewall-cmd --reload   # 或 ufw allow 443/tcp
# 移除外部对 dashboard 直连端口的访问(脚本此前放行过)
firewall-cmd --permanent --remove-port=8443/tcp 2>/dev/null && firewall-cmd --reload
# ufw: ufw delete allow 8443/tcp
```

> dashboard 已绑 `127.0.0.1`，即使防火墙没删该端口，外部也连不上，删掉只是更干净。

### 4. 验证与排错

```bash
curl -kI https://wazuh.example.com           # 应返回 200/302(登录页)
journalctl -u caddy -f   # 或 journalctl -u nginx -f / journalctl -u wazuh-dashboard -f
```

| 现象 | 原因 / 解决 |
|------|------|
| 登录后立即跳回登录页 / 401 | dashboard 未配 `server.xforwarded.supportedProxies`，或反代未透传 `Host`（Caddy `header_up Host {host}` / Nginx `proxy_set_header Host $host`）|
| 502 Bad Gateway | dashboard 未重启成 `127.0.0.1:8443`；或未对自签证书跳过校验（Caddy `tls_insecure_skip_verify` / Nginx `proxy_ssl_verify off`）|
| Nginx 报 `upstream sent too big header` | 未调大 `proxy_buffer_size`/`proxy_buffers`（见上方配置）|
| 仍能直连 `https://IP:8443` | `server.host` 没改回 `127.0.0.1`，或防火墙没删该端口 |
| 想部署在子路径 `/wazuh` | dashboard 设 `server.basePath: "/wazuh"`，Caddy/Nginx 用 `reverse_proxy /wazuh/*` / `location /wazuh/`；根域名反代无需此项 |

> 整个方案只动 dashboard 的配置文件、系统防火墙与反代配置，**不修改本安装脚本**；改完 `systemctl restart wazuh-dashboard` + reload 反代即生效。

## 卸载

```bash
bash install_security_monitor.sh --uninstall   # 或 --remove / -u
```

- 自动检测已装组件 → 多选要清理的项（直接回车=全部）→ 选择是否连软件包一起卸载（默认**仅删配置**，保留软件包）→ 确认后执行
- Wazuh 全套：优先调用官方 `wazuh-install.sh --uninstall` 彻底卸载；agent 仅删配置或连同包
- 清理范围：服务、配置、cron、日志轮转、仓库源、GPG key、告警脚本

## 常见问题排查

| 现象 | 处理 |
|------|------|
| `$'\r': command not found` / `set: pipefail: invalid option` | 文件被转成 Windows 换行：`sed -i 's/\r$//' install_security_monitor.sh` |
| Wazuh 安装中途失败 | 查看 `/root/wazuh-install.log` 结尾错误；重跑 `bash /root/wazuh-install.sh -a -i -o -p <端口>` 带 `-o` 覆盖 |
| apt update 报 GPG 过期 | 检查第三方源（如 caddy cloudsmith 源密钥过期），禁用或更新后再装 |
| Debian 报 `software-properties-common` 缺失 | 脚本已自动创建 dummy 包；若失败手动：`apt install software-properties-common` 无此包时需跳过 Wazuh 依赖检查 |
| 测试告警没收到 | 检查 `/etc/security-monitor.conf` 各渠道参数；手动跑 `/usr/local/bin/security-alert.sh "测试" "内容"` 看报错 |
| SSH 不是 22 端口 | 编辑 `/etc/fail2ban/jail.local` 中 `port` 后 `systemctl restart fail2ban` |
| 想监控 nginx/apache/ftp | 在 `/etc/fail2ban/jail.local` 添加对应监狱（如 `[nginx-http-auth] enabled = true`） |
| 443 端口被占用 | 自动改 8443；或 `WAZUH_DASHBOARD_PORT=xxxx bash install_security_monitor.sh` |
| 资源告警收不到 | `resource-monitor.sh --check` 看是否真超阈值；`--test` 测渠道；检查 `RES_DISK_IGNORE` 是否把目标盘忽略了，或阈值设得太高 |
| 时区改完没生效/想看当前时区 | `date` 查看当前时间；`timedatectl` 查看时区；改完需确认 `/etc/localtime` 软链接指向 `/usr/share/zoneinfo/<时区>` |
| 想还原原时区 | 重跑卸载并勾选 `7 时区`（会从 `/etc/security-monitor-tz.orig` 还原），或手动 `timedatectl set-timezone <原时区>` |
| 多台服务器共用一个 Telegram bot/群会冲突吗 | 不冲突（脚本只发送、不接收，不会“抢 bot”）。但多机并发高频告警可能触发 429 限流，脚本会按 `retry_after` 自动重试最多 3 次；钉钉/企微/Telegram 失败会显示真实 `errcode`/`error_code` 而非误报“已发送” |
| 告警分不清是哪台服务器发的 | 所有告警标题由 `security-alert.sh` 自动加 `[主机名]` 前缀（如 `[web01] 💾 磁盘告警`），多机共用渠道也能一眼区分来源 |

## 安全提示

- 告警 Webhook 属于敏感凭据，`/etc/security-monitor.conf` 已设为 600 权限
- **勿将 Wazuh dashboard（443/8443）直接暴露公网**，建议仅内网/跳板机访问，或经 Caddy/Nginx 反向代理发布（见上方「Wazuh Dashboard 反向代理」专节）；API 端口 55000 同理
- Fail2ban 白名单默认仅本机回环地址，请将常用运维 IP 加入 `F2B_IGNOREIP`，避免误封
- `AUDIT_EXECVE=yes` 会记录所有普通用户命令（审计日志增长较快），磁盘紧张可关闭
- 保持系统与 Wazuh 及时更新（脚本支持指定 `WAZUH_VERSION` 回退/升级）

## 适用场景

- 单台/多台 Linux 服务器安全基线巡检（脚本自带自动模式，可结合配置管理批量下发）
- 需要"有事情立刻知道"的实时告警（登录、爆破、账户变更、危险命令）
- 已有 Wazuh 平台，只需批量接入 agent 上报
