# 安全巡检系统一键部署脚本

Linux 服务器自动化安全巡检部署工具：**Fail2ban（暴力破解防护）+ auditd（审计）+ Wazuh（HIDS，可选）+ 多渠道实时告警（钉钉 / 企业微信 / Telegram / 邮件）+ 每日安全日报**。

单脚本、交互式/自动双模式，支持 Debian / Ubuntu / RHEL / CentOS / Rocky / Alma / Fedora。

---

## 功能特性

| 组件 | 说明 |
|------|------|
| **Fail2ban** | SSH 暴力破解自动封禁（次数/窗口/时长/白名单可配），封禁与解封实时推送告警 |
| **auditd** | 登录/账户变更/关键文件（passwd、shadow、ssh 配置、cron、.ssh 等）/危险命令（反弹 shell、管道 curl\|bash、base64 解码等）审计，实时监控可疑事件 |
| **Wazuh**（可选） | Agent 模式：上报到已有 manager；全套模式：本机部署 manager+indexer+dashboard（官方 all-in-one），告警自动转发到聊天渠道 |
| **每日巡检日报** | 每天 08:00 推送：当日登录成功/失败、账户变更、当前封禁 IP、系统负载 |
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

1. **组件**（可多选，回车默认 `1,2,5`）：
   - `1` Fail2ban · `2` auditd · `3` Wazuh Agent · `4` Wazuh 全套 · `5` 每日日报
   - 输入 `all` 安装 1,2,5（不含 Wazuh）
2. Wazuh 参数（选了 Wazuh 才问）：agent 需填 manager 地址；全套会**在线检测最新版本**（如 4.14.7），回车用最新，也可指定旧版
3. **告警渠道**（可多选，`0` 跳过）：1 钉钉 · 2 企业微信 · 3 Telegram · 4 邮件
4. 各渠道的 Webhook/Token/邮箱等参数
5. Fail2ban / auditd 阈值参数
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
```

> 自动模式默认**全部组件关闭**，未指定任何组件会报错退出（防误装）。

## 环境变量参考（自动模式）

| 变量 | 默认 | 说明 |
|------|------|------|
| `INSTALL_FAIL2BAN` | no | yes 安装 Fail2ban |
| `INSTALL_AUDITD` | no | yes 安装 auditd |
| `INSTALL_WAZUH` | none | `agent` / `full` |
| `INSTALL_DAILY` | no | yes 配置每日日报 |
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

## 告警渠道获取方法

| 渠道 | 获取方法 |
|------|---------|
| **钉钉** | 群设置 → 智能群助手 → 添加机器人 → 自定义 → 复制 Webhook；安全设置可选"加签"（填密钥） |
| **企业微信** | 企业微信群 → 添加群机器人 → 复制 Webhook 地址 |
| **Telegram** | 找 [@BotFather](https://t.me/BotFather) 创建 Bot 拿 Token；向 [@userinfobot](https://t.me/userinfobot) 发消息拿 Chat ID |
| **邮件** | 任意支持 SMTP 的邮箱；QQ 邮箱等需用**授权码**而非登录密码 |

## Wazuh 说明

- **版本自动检测**：优先使用在线检测到的最新正式版（GitHub API，超时 15s），失败回退内置默认 4.10；下载目录自动取主次版本号（如 4.14.7 → `packages.wazuh.com/4.14/`）
- **端口冲突**：443 被占用时自动改用 8443（部署后按提示访问 `https://IP:8443`）
- **Debian 兼容**：wazuh-install.sh 硬性依赖 Ubuntu 特有的 `software-properties-common` 包，脚本自动创建 dummy 包跳过检查
- **安装日志**：`/root/wazuh-install.log`，dashboard 管理员账号密码也在里面
- **账号密码自动提取**：安装完成后脚本自动解析日志，将 dashboard `admin` 密码、API `wazuh-wui` 密码（日志无则从 dashboard 配置 `wazuh.yml` 提取）直接显示在部署摘要里，无需手动翻日志
- **全套安装**：10-20 分钟，内存不足会警告并带 `-i` 忽略官方检测（高风险，不建议 <4G 强装）
- **agent 模式**：自动配置 manager 地址并重启 agent；如要注册 agent 需在 manager 上另行授权（`wazuh-agent` 官方注册流程）

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
| `/etc/cron.d/security-monitor` | 每日 08:00 日报 cron |
| `/etc/logrotate.d/security-alert` | 告警日志轮转（保留 30 天） |
| `/var/ossec/integrations/custom-security` | Wazuh→聊天渠道告警转发（仅全套模式） |
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

## 卸载

```bash
bash install_security_monitor.sh --uninstall   # 或 --remove / -u
```

- 自动检测已装组件 → 多选要清理的项 → 选择是否连软件包一起卸载（默认**仅删配置**，保留软件包）→ 确认后执行
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

## 安全提示

- 告警 Webhook 属于敏感凭据，`/etc/security-monitor.conf` 已设为 600 权限
- **勿将 Wazuh dashboard（443/8443）暴露公网**，建议仅内网/跳板机访问；API 端口 55000 同理
- Fail2ban 白名单默认仅本机回环地址，请将常用运维 IP 加入 `F2B_IGNOREIP`，避免误封
- `AUDIT_EXECVE=yes` 会记录所有普通用户命令（审计日志增长较快），磁盘紧张可关闭
- 保持系统与 Wazuh 及时更新（脚本支持指定 `WAZUH_VERSION` 回退/升级）

## 适用场景

- 单台/多台 Linux 服务器安全基线巡检（脚本自带自动模式，可结合配置管理批量下发）
- 需要"有事情立刻知道"的实时告警（登录、爆破、账户变更、危险命令）
- 已有 Wazuh 平台，只需批量接入 agent 上报
