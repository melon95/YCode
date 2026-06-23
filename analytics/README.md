# ycode 用户量统计（Cloudflare Worker）

把 Tauri 的更新检查端点换成一个自己的 Worker：它每次返回真实的 `latest.json`
（代理 GitHub Releases），同时记录一次**匿名**活跃实例 ping，从而得到
DAU / MAU / 安装总量，而不破坏自动更新。

## 收集了什么（以及没收集什么）

每次更新检查，客户端通过请求头发送：

| Header              | 内容                          |
| ------------------- | ----------------------------- |
| `x-ycode-instance`  | 随机 UUID（每次安装一个，存 localStorage） |
| `x-ycode-version`   | App 版本，如 `0.3.0`             |
| `x-ycode-os`        | `macos` / `windows` / `linux` |
| `x-ycode-arch`      | `aarch64` / `x86_64`          |

**不收集** IP、文件路径、项目名、命令内容或任何可定位到个人的信息。
UUID 与机器/用户无关；清空 App 数据即重置（记为一次新安装）。

去重逻辑：D1 里 `(instance, day)` 唯一，同一天多次启动只算一次，
所以 `COUNT(DISTINCT instance)` 是真实的活跃数。

## 部署步骤

```bash
cd analytics
npm install
npx wrangler login

# 1) 创建 D1 数据库，把输出里的 database_id 填进 wrangler.toml
npx wrangler d1 create ycode-analytics

# 2) 建表（远程）
npm run db:init

# 3) 设置 /stats 的访问令牌（随便一串强随机字符串）
npx wrangler secret put STATS_TOKEN

# 4) 部署，记下输出的 https://ycode-updater.<你的子域>.workers.dev
npm run deploy
```

## 最后一步：把端点指向 Worker

部署成功后，编辑 `../src-tauri/tauri.conf.json`，把第一个 endpoint 里的
`YOUR_SUBDOMAIN` 换成你的真实 workers.dev 子域：

```json
"endpoints": [
  "https://ycode-updater.<你的子域>.workers.dev/releases/latest.json",
  "https://github.com/melon95/YCode/releases/latest/download/latest.json"
]
```

GitHub 那条是兜底：万一 Worker 没部署/宕机，Tauri 会自动回退，
更新功能永远不会因为统计服务而失效。改完重新打包发版即可生效。

## 查看数据

```bash
curl "https://ycode-updater.<你的子域>.workers.dev/stats?token=<你的STATS_TOKEN>"
```

返回示例：

```json
{
  "dau": 42,
  "mau": 318,
  "total_installs": 1205,
  "by_version": [{ "version": "0.3.0", "n": 250 }, { "version": "0.2.0", "n": 68 }],
  "by_os": [{ "os": "macos", "n": 290 }, { "os": "windows", "n": 28 }],
  "generated_at": "2026-06-23T08:00:00.000Z"
}
```

## 本地调试

```bash
npm run db:init:local          # 在本地 D1 建表
npm run dev                    # 启动本地 Worker
# 另开终端模拟一次 ping：
curl -H "x-ycode-instance: test-uuid" -H "x-ycode-version: 0.0.0" \
     -H "x-ycode-os: macos" -H "x-ycode-arch: aarch64" \
     http://localhost:8787/releases/latest.json
curl "http://localhost:8787/stats"   # 本地默认无 token
```

## 说明 / 可选项

- **隐私合规**：作为开发者工具，建议在设置或 README 里写明收集内容并提供开关。
  统计完全搭在更新检查上——用户若关闭自动更新检查，就不会上报。
- **数据增长**：每实例每天一行。需要时可定期清理：
  `DELETE FROM pings WHERE day < date('now','-400 day');`
- **安装量 vs 活跃量**：`total_installs` 是历史出现过的去重实例数（近似累计安装），
  `dau`/`mau` 才是活跃口径。GitHub Release 下载量可作为另一个交叉参考。
