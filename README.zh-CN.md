# QuotaBar

[English](README.md) | **中文**

一个 macOS 菜单栏应用，统一监控你在各云厂商（火山方舟 / 智谱 / DeepSeek / 月之暗面 / 腾讯 / 阿里，以及以后想加的任何厂商）的 **Coding Plan、Coding Agent、API Key 额度与消耗**。

> 灵感来自 ClaudeBar。一个菜单栏，看遍所有 AI 编程额度。

## 功能

- **菜单栏动态显示 + 三格信号条图标**：近5小时 与 近一周 用量哪个百分比高就显示哪个（`5H 100.0%` / `W 6.9%`）。信号条为三根从低到高的竖条，形状固定不变，颜色随消耗档位变化：绿 <50% / 黄 50–75% / 橙 75–90% / 红 ≥90%（失败全灰）。每 10 分钟自动刷新。
- **多套餐标签切换（参考 ClaudeBar）**：菜单栏标题显示当前套餐；菜单里「切换套餐」区点击即切换、数据立即刷新。内置两个套餐（方舟CodingPlan / 方舟AgentPlan），可无限添加任意厂商的套餐或 API Key。
- **额度窗口菜单（含进度条）**：近5小时 / 近一天 / 近一周 / 近一月 的已用百分比、人性化重置时间（今天 21:31 / 明天 00:44 / 10月5日 00:00，不显示时区），以及每行 **10 格彩色进度条**（按档位着色，剩余格子浅灰）。
- **设置面板（菜单「设置…」）**：增删改套餐，每个套餐独立配置认证方式与凭据：
  - `arkcli 本机登录`：复用本机 `arkcli` 登录态查询（火山套餐最简单）
  - `AK/SK 直查`：填火山引擎访问密钥（Access Key / Secret Key），通过官方 OpenAPI `GetAFPUsage` 直查 Agent Plan 额度——不依赖本机 arkcli 登录，可分享给任何机器
- **📊 模型价格·类型·三榜单（官方价）**（⌘P）：16 款模型官方 API 标价（对数刻度，蓝=输入 橙=输出）+ 模态类型徽标 + LMArena ELO / LiveBench Coding / SWE-bench Verified 三榜单分数与名次 + Opus 4.8（编程基准）/ Sonnet（日常基准）高亮 + 按榜单或价格排序。
- ⌘R 立即刷新，⌘Q 退出。

## 环境要求

- macOS 11.0+
- 火山方舟套餐查询：本机安装并登录 `arkcli`（`npm i -g @volcengine/ark-cli && arkcli auth login`），或在火山引擎控制台「访问控制 → 访问密钥」创建 AK/SK 填入。

## 运行

```bash
open /Applications/QuotaBar.app
# 或按下方说明从源码构建
```

## 配置与分享

- 配置保存在 `~/Library/Application Support/QuotaBar/config.json`——单个 JSON 文件包含所有套餐与凭据。
- 分享给别人：把 App 和该配置文件一起拷贝即可。Agent Plan 套餐推荐用 **AK/SK** 认证方式，对方无需你的 arkcli 登录态。
- 凭据只存本机，App 直接调用各厂商官方接口取数，不上传任何服务器。

## 从源码构建

```bash
git clone https://github.com/liuchang5/quotabar.git
cd quotabar
swiftc -O -swift-version 5 -o QuotaBar main.swift -framework AppKit -framework Foundation -framework CryptoKit
mkdir -p /Applications/QuotaBar.app/Contents/MacOS
cp QuotaBar /Applications/QuotaBar.app/Contents/MacOS/QuotaBar
# 用本仓库的 Info.plist 生成 /Applications/QuotaBar.app/Contents/Info.plist
open /Applications/QuotaBar.app
```

单文件 Swift（AppKit），无外部依赖。

## 数据源说明

- **Coding Plan 个人版**：无公开用量 OpenAPI，本工具复用本机 `arkcli`（SSO 登录态）查询。
- **Agent Plan 个人版**：支持 `arkcli` 与官方 OpenAPI `GetAFPUsage` 两种方式（POST `https://ark.cn-beijing.volcengineapi.com/?Action=GetAFPUsage&Version=2024-01-01`，HMAC-SHA256 签名）。

## 截图

（待补充）

## License

MIT
