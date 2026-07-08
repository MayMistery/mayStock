<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="MayStock 图标">
</p>

<h1 align="center">MayStock</h1>

<p align="center">
  优雅的 macOS 菜单栏应用，实时监控系统指标与加密货币行情。
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="LICENSE">MIT 许可证</a>
</p>

---

## 功能特性

- **菜单栏显示** — 实时指标：`BTC 62213 | CPU 12% | MEM 8.2G | NET 1.5 KB/s`
- **悬浮图表面板** — 鼠标悬停即显示专业金融图表
- **图表类型** — K线图、深度图、成交量图、折线图
- **时间跨度** — 从 1 秒到 7 天可自由配置
- **OKX 实时数据** — 通过 WebSocket 从 OKX 公共 API 获取 BTC/USDT 实时行情
- **系统监控** — CPU、内存、网络流量（原生 macOS API）
- **右键设置** — 完整的配置窗口（通用、监控项、外观）
- **完全可配置** — 添加/删除/排序监控项，自定义图表类型和显示标签

## 系统要求

- macOS 26.0+（Tahoe）
- Swift 6.0+

## 安装

```bash
git clone https://github.com/yourname/MayStock.git
cd MayStock
make run
```

Release 模式构建，安装到 `/Applications/MayStock.app`，并自动启动。

## 使用方式

| 操作 | 效果 |
|------|------|
| **悬浮** 菜单栏项 | 显示图表 Popover |
| **左键点击** 菜单栏项 | 切换图表 Popover |
| **右键点击** 菜单栏项 | 打开上下文菜单（设置 / 退出） |

### Makefile 命令

```bash
make build     # 构建 Release 二进制
make install   # 构建 + 安装到 /Applications
make run       # 构建 + 安装 + 启动
make clean     # 清理构建产物和应用
make uninstall # 从 /Applications 卸载
```

## 架构

```
Sources/MayStock/
├── App/                  — 入口、AppDelegate、StatusBarController
├── Features/
│   ├── Charts/           — K线、深度、成交量、折线图视图
│   ├── Popover/          — 悬浮面板 + 图表选择器
│   └── Settings/         — 设置窗口（通用、监控、外观）
├── Services/
│   ├── MarketData/       — OKX WebSocket、消息解析、数据提供
│   ├── SystemMonitor/    — CPU、内存、网络监控
│   └── Configuration/    — JSON 持久化
└── Models/               — 领域模型（MonitorItem、OHLC、OrderBook 等）
```

## 数据来源

- **加密货币**: OKX WebSocket API v5 (`wss://ws.okx.com:8443/ws/v5/public`)
- **系统指标**: macOS 原生 Mach/BSD API (`host_statistics`, `host_statistics64`, `getifaddrs`)

## 许可证

[MIT](LICENSE)
