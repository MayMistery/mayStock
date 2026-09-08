# 宏观情报站

MayStock 的原生情报窗口提供今天前 7 天至后 30 天的事件日历、宏观日报、最近 1 小时局势，以及每 30 分钟检查一次的事件快报。每日默认 08:00（Asia/Taipei）生成日报；预测默认覆盖未来 **1 小时**。关注列表中的每个标的均参与判断，包括菜单栏隐藏的标的。

情报通过 Python **Claude Agent SDK 0.2.152** 调用 Claude Code，固定使用 `model_hub/es1_orange_o50[1m]`。模型不可用时显示失败并保留已有情报，不自动替换模型。SDK 的 `[1m]` 后缀由 Claude Code 转换为大上下文请求配置。

## 安装与连接

```sh
./Scripts/setup-intelligence.sh
```

该脚本在 `~/Library/Application Support/MayStock/IntelligenceRuntime` 安装独立 Python 环境，不修改系统 Python。运行时脚本随应用打包，开发时也可从 `Intelligence/runner.py` 运行。安装依赖及打包方式以脚本为准。

原生 Claude 登录和钥匙串认证保持可用。企业路由可使用受保护的文件：

`~/Library/Application Support/MayStock/Intelligence/connection.json`

文件内容是环境变量名到字符串值的 JSON 映射，支持 `ANTHROPIC_BASE_URL`、`ANTHROPIC_CUSTOM_HEADERS`、`ANTHROPIC_AUTH_TOKEN`、`ANTHROPIC_API_KEY` 等连接字段。该文件应保持权限 `0600`，不放入仓库或应用包。可用 `MAYSTOCK_INTELLIGENCE_CONNECTION` 指向其他受保护文件。认证值不会进入研究提示词、日志或报告。

连接读取顺序为：Claude 用户设置中的允许列表 `env` → 情报专用连接文件 → 当前进程的显式环境变量。后者优先。不会执行 `apiKeyHelper`、Shell 配置、用户 hooks 或插件。需要指定 Claude Code 二进制时可设置 `MAYSTOCK_CLAUDE_PATH`；默认使用 PATH 中的 Claude，否则使用 SDK 自带版本。

诊断命令（将 Python 路径替换为实际虚拟环境路径）：

```sh
python Intelligence/runner.py --doctor
python Intelligence/runner.py --smoke-model
python Intelligence/runner.py --smoke-retrieval
```

`--doctor` 不访问模型，只报告版本、路径和已配置的环境变量**名称**。`--smoke-model` 会实际调用固定模型并检查结构化输出。`--smoke-retrieval` 检查新闻发现与官方日历，明确返回不可读取的来源。

## 来源与时间规则

每次自动搜索全球局势、美国政策和加密市场。Bing News RSS 和 Google News RSS 只用于发现线索；引用依据来自实际读取的发布者网页。Google 的聚合链接先解析为原始发布者，再读取正文。每日预加载 BLS 官方 ICS、Fed FOMC 日历和 BEA 官方 ICS，覆盖通胀、就业、利率、GDP/PCE 等事件。日历时间由程序解析，日报在并行读取少量新闻原文后通过一次 SDK 结构化调用完成摘要和预测；小时/快报可以在受限预算内使用只读研究工具补充核验。

发生时间与发布时间分别保存。快报/小时更新仅接受原文能够明确证明**事件发生日期、时分和时区**的事件；只有日期、直播时间标题、旧事件的新报道及模糊的“刚刚”等内容不进入短窗口快报。多个日期和不相关时刻不能交叉组合。计划发布时间仍是计划，排期经过不证明事件已经发生。

快报仅覆盖 `(本次时间−30分钟, 本次时间]`；小时更新覆盖 `(本次时间−60分钟, 本次时间]`。快报对既有事件去重，不补报睡眠或停机期间已经过期的旧事件。必需新闻搜索未完成，或发现新闻线索但没有读到任何发布者原文时显示失败。已读取原文后，个别页面或补充搜索失败仍可生成部分覆盖结果，并把覆盖警示放在开头。没有合格新事件的快报保持静默，状态仍显示覆盖缺口；空结果只说明已读取来源未核验到新事件，不断言全面无新闻。日历采用请求的 IANA 时区计算 38 个当地日期，跨夏令时也按当地日期处理。

报告的可选字段 `coverageComplete` 由程序检查本轮访问记录后生成，模型不参与判断。页面读取、补充搜索或官方日历存在已知失败时为 `false`；`true` 仅表示本轮没有已知访问失败，不保证穷尽全网，也不代表报价新鲜或预测可靠。部分覆盖不会降低事件时间、原文依据、去重或方向预测的校验要求，旧归档可不包含此字段。

官方日历不可读取时会明确标记覆盖不完整，不推算缺失日程。2026-09-08 的现场验证中，BLS 直接访问返回 HTTP 403；Fed 和 BEA 官方来源可读取。BLS 不可读时，额外读取圣路易斯联储 FRED 的 CPI 发布日历，并明确标记这是 FRED 转引来源；其他 BLS 指标仍标记缺口。网页访问限制、消息披露延迟及无法证明发生时分均可能导致漏报；系统不会以模型历史知识补齐这些证据。

## 预测与失败行为

每个标的显示 `up`、`down`、`neutral` 或 `insufficient`，并附事件依据、驱动因素和失效条件。报价必须来自请求，价格有效且时间在最近 5 分钟内；缺失、陈旧、未来报价或没有已核验事件依据时强制 `insufficient`。这些是未经校准的模型判断，置信度不代表统计胜率。该模块不执行交易。

报价统一复用主线行情源，按关注项的交易所选择 OKX 或 Yahoo Finance，包括菜单栏隐藏的标的。美股可采用来源提供的常规、盘前或盘后市场报价，始终保留真实市场时间，不能用检索时间替代；缺少市场时间的报价不会生成行情记录。超过 5 分钟就不支持方向预测。美股较前收盘涨幅不填写为加密资产的 `change24h`，情报模块不另行维护一套报价协议。

Swift 负责调度、持久化和重试；Python 只接收一次请求并产生一次结果。正常 stdout 为一个报告 JSON；失败为 `{"error":"已脱敏的说明"}`，并以非零状态退出。总体运行有 480 秒限制；日报模型阶段为 180 秒，小时/快报模型阶段为 360 秒，取消时关闭 SDK 连接。校验失败最多在同一 SDK 会话内修正一次，沿用本次原文证据。已有好数据在失败后继续保留，界面另行显示失败状态。短窗口事件在输出完成时再次检查是否仍在最近 30/60 分钟内；报告覆盖终点仍是检索开始时刻，不声称覆盖生成期间的新消息。

SDK 禁用内置工具、用户/项目设置、hooks、插件、skills、自动记忆和其他 MCP 连接；仅开放 `search_news`、`fetch_page` 两个只读研究工具。HTTPS 检索拒绝本地/私有地址、凭证 URL 和非标准端口，在连接时固定已核验的公网 IP，保持原始主机名的 TLS 校验，并逐跳验证重定向。检索不使用本机代理设置；模型路由仍可使用明确配置的代理。

## 开发验证

```sh
.build/intelligence-venv/bin/python -m unittest discover -s Intelligence/tests -v
```

测试覆盖旧事新发、发布时间与发生时间混淆、不相关日期与时刻组合、短窗口边界、去重、同一日历同时发布的不同指标、缺失/陈旧报价、完整关注列表、夏令时、来源原文核验、必需检索失败与部分覆盖的边界、程序覆盖字段及 SDK 设置隔离。

数据结构详见 [INTELLIGENCE-CONTRACT.md](INTELLIGENCE-CONTRACT.md)。SDK 配置依据 [Python Agent SDK 官方参考](https://code.claude.com/docs/en/agent-sdk/python)、[结构化输出](https://code.claude.com/docs/en/agent-sdk/structured-outputs) 和 [设置隔离边界](https://code.claude.com/docs/en/agent-sdk/claude-code-features)。
