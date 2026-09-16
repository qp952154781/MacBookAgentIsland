# AgentIsland · 刘海灵动岛

English: [README.en.md](README.en.md)

把 Mac 的屏幕刘海变成 Claude Code / Codex 的额度与会话面板。

以下截图均为内置 mock 数据，额度、套餐、会话和系统指标均为演示值。
截图日期使用固定示例时间并按 UTC 显示；已移除 EXIF/XMP 等附加元数据。

**收起**：左侧 Claude 剩余额度，右侧 Codex 剩余额度。

![收起态](docs/images/collapsed.png)

**活动**：会话运行时，对应图标旋转并显示活动条（下图为静态帧）。

![活动态](docs/images/active.png)

**展开**：系统指标、两张额度卡；双列会话按家分列，左侧 Claude、右侧 Codex。

![展开面板](docs/images/expanded.png)

默认显示剩余额度，悬停展开；也可选择点击展开。点击顶部固定，再次点击或点击岛外收起。会话行可查看详情，较多会话可滚动。默认优先内建屏，无刘海时显示顶部胶囊。全屏默认隐藏，可在设置中开启“全屏时显示”。会话变化不会自行展开窗口。

## 它能做什么

- 一眼查看 Claude / Codex 的剩余额度与重置时间。
- 会话进行中显示旋转图标和活动条，有计划时显示进度。
- 悬停或点击展开，查看会话状态、当前动作与上下文。
- 会话按状态排序：执行中最前，其次思考中（压缩上下文、重试中同级），再依次为等待授权、等待输入、出错、空闲、已结束。同一优先级内按项目归类，项目组按组内最新活动时间排序，无项目名的排在该档末尾；组内按活动时间倒序。双列时两家各自排序，单列时合并排序。
- 展开时显示网速、CPU、内存与可用的风扇转速。
- 会话结束不会自动弹出，保持安静。

设置 → 会话列表 → 布局默认为“自动”：至少 5 个未结束会话，且面板可用居中宽度至少 880 pt 时按家分两列（左 Claude、右 Codex），列头显示各家的活跃数。可固定选择“单列”（合并列表）或“双列”（不受会话数量限制）；屏幕可用宽度不足时，即使选择“双列”也会自动回退单列。双列长度独立，空列显示占位提示，短列下方留空；展开详情仅改变所在列，两列一起滚动。

## 系统要求

- macOS 14+，Apple Silicon 或 Intel。
- 有刘海的 MacBook 体验最佳；无刘海屏自动降级为顶部胶囊。
- 已安装并登录 Claude Code / Codex，才有对应服务的数据。
- 从源码构建需要 Swift 6 工具链，Command Line Tools 即可，无需 Xcode。

## 数据与隐私

**本项目不收集任何数据，没有遥测，不上传会话内容。** 下述本地读取用于在你的 Mac 上显示信息。

图标在运行时从本机已安装的 Claude / ChatGPT 应用读取，未将第三方图标文件打包或作为独立素材分发；演示截图仅展示界面效果；未安装时使用自绘图标。

AgentIsland 读取以下本地数据以显示会话、动作、上下文与额度：

- `~/.claude/sessions/*.json`：会话与进程信息；不读取 `*.key`。
- `~/.claude/projects/*/*.jsonl`：主会话 transcript，增量读取，不读取子代理记录。
- `~/Library/Application Support/Claude/claude-code-sessions/` 下的 `local_*.json`：桌面会话标题、归档状态。
- `~/.codex/state_*.sqlite`：只读查询会话索引；失败时扫描今天/昨天的 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`。
- Codex rollout 中的 `token_count` / `rate_limits`：启动时的本地额度，以及 app-server 失败时的兜底。缓存数据会显示来源与时间。

Claude 网页或桌面登录不一定提供 Claude Code 的 OAuth 额度权限。请在终端执行一次 `claude auth login`；不在 PATH 时，可在设置中复制已定位的完整登录命令。运行时额度客户端通过系统 `/usr/bin/security` 读取 `Claude Code-credentials` 钥匙串项；该项不存在时，兼容读取 `~/.claude/.credentials.json`。令牌只在内存中使用，不写入 AgentIsland 配置、日志或导出；不会读取 `~/.codex/auth.json`，也不会持有 Codex token。

AgentIsland 自己发起的 HTTP 请求仅访问 `api.anthropic.com` 的 Claude 额度接口，不上传会话内容，不跟随重定向，不保存 HTTP 缓存或 Cookie，没有遥测。Codex 额度通过官方 `codex app-server` 子进程查询；官方子进程可能访问自己的服务端，因此“除 api.anthropic.com 外不联网”仅适用于 AgentIsland 自身的 HTTP 客户端，不能作为整个子进程树的网络承诺。

AgentIsland 自身只读 Claude / Codex 的数据与配置，不安装 hook、不修改 statusLine。续期时由官方 CLI 自行更新其凭据，详见下文。设置保存在 AgentIsland 自己的 UserDefaults 中。解析异常只显示通用提示，不输出损坏记录原文。`--dump sessions` 会包含会话标题、项目路径和动作，请仅在本机检查，分享前自行脱敏。

## 构建与安装

要求 macOS 14 或以上、Swift 6 工具链；仅使用系统框架，无第三方依赖。Command Line Tools 即可，无需 Xcode。

```sh
scripts/build.sh release
scripts/test.sh
scripts/bundle.sh
```

将生成的 `dist/AgentIsland.app` 拷贝到 `/Applications` 后打开。已有旧版时，请先从岛的右键菜单退出旧版。

也可运行 `scripts/install.sh` 自动构建、退出旧进程并安装。它会先验证新包，再替换旧包；旧包保留为 `/Applications/AgentIsland.previous.app`，确认正常后可手动移除。脚本不自动启动浮层，也不会申请管理员权限；无 Applications 写权限时请手动拷贝。

应用采用本机 ad-hoc 签名，未做 Apple 公证。release 构建会映射源码路径并移除可执行文件中的调试映射，避免附带构建者的绝对路径；本地调试请使用默认 debug 构建。应用自身图标由 `scripts/make-icon.sh` 调用 CoreGraphics 绘制并优先通过 `iconutil` 打包；若当前系统环境无法编码 ICNS，脚本会明确提示并用同一组 PNG 写入原生 ICNS 容器。应用自身图标没有使用第三方图片或官方 logo。

公开版应用标识为 `org.agentisland.AgentIsland`。从早期开发版升级时，旧偏好设置不会自动迁移；请先在旧版关闭开机启动，安装新版后重新设置并按需开启。

## 开机启动

右键岛 → 设置 → 开机启动。先把应用放进“应用程序”，再开启。若显示需要批准，请在“系统设置 → 通用 → 登录项与扩展”允许 AgentIsland。关闭同一开关即可取消。直接运行 `.build` 下的可执行文件不适合注册登录项。

也可运行 `/Applications/AgentIsland.app/Contents/MacOS/AgentIsland --login-item on` 开启（`off` 关闭、`status` 查询）；命令输出实际状态的 JSON 后立即退出，需要系统批准时会给出提示。

## 限制与已知问题

- 应用使用 ad-hoc 签名，未做 Apple 公证。首次打开若被系统拦截，请在“系统设置 → 隐私与安全性”中允许打开。
- 锁屏或睡眠期间暂停额度轮询，解锁或唤醒后恢复，因此显示的数据可能短暂陈旧。
- **Claude 令牌续期会启动官方 CLI**：access token 通常约 8 小时过期；普通非交互查询无法触发续期。临近或已经过期、或遇到认证失败时，App 会通过隐藏伪终端运行一次交互式 Claude Code，待输入框就绪后发送本地 `/usage` 命令，让官方 CLI 完成续期，再退出。此过程不发送对话提示、不消耗模型额度；App 不自行调用刷新接口或写入钥匙串。官方 CLI 可能联网并更新自己的凭据。
- 续期使用 AgentIsland 的专用目录，并通过启动参数关闭 Chrome 提示和 Remote Control。遇到首次设置、目录信任或登录提示时会退出并提示你在终端完成，**不会代替你确认**。登录失效或 CLI 界面变化仍可能需要人工处理。
- 本地会话与额度接口可能随官方客户端版本变化；风扇指标在不支持的设备上会隐藏。构建目标支持两种处理器架构，不代表已覆盖所有设备组合的实机验收。

## 常见问题

**岛不显示**：确认应用运行于桌面会话；默认全屏隐藏，请退出全屏或在设置中开启“全屏时显示”。检查内建屏和主屏顶部；断开屏幕后会重新选择可用屏幕。没有可用 NSScreen 的后台会话无法显示浮层。系统自动隐藏菜单栏可能使 `visibleFrame` 与全屏相同，也会按全屏设置处理。

**额度未连接**：展开后查看卡片提示。Claude 请先完成 `claude auth login`；App 会尝试自动续期，明确提示登录失效时再重新登录。网络失败、请求过于频繁会显示错误或保留上次成功数据并标记陈旧（悬停卡头状态可查看原因），稍后自动退避重试，也可点击刷新。Codex 请安装并登录官方客户端；缺少可执行文件、启动失败、超时和接口错误都有提示。

**Codex 额度不更新**：本地 rollout 额度只随 Codex 新的 token_count 记录更新，不保证实时。查看来源和更新时间；确认官方客户端已登录，手动刷新以重新查询 app-server。索引被锁、损坏或不存在时会自动读取会话目录，并在会话区提示。

**会话记录异常**：截断或替换后重新读取；超过 16 MiB（16 × 1,048,576 字节）的单行、非 UTF-8 或坏 JSON 行会跳过并提示，其余行继续处理。每家最多保留 50 个近期会话，列表超过面板高度时可滚动查看。长标题按既有规则省略，可展开详情查看更多信息。

**重置时间异常**：过去的重置时间显示“—”，超出可显示范围时显示“时间异常”。系统时钟变化会触发刷新。锁屏或进入睡眠状态时暂停额度轮询和系统指标采样，会话扫描限为每家最多 30 秒一次；实际系统睡眠期间进程不执行，唤醒或解锁后立即重新读取。

## 本地验证

```sh
scripts/snapshot.sh
.build/release/AgentIsland --measure --mock idle --exit-after 300
.build/release/AgentIsland --measure --mock busy --exit-after 300
```

开发者可在自己的桌面会话中验证真实数据：

```sh
dist/AgentIsland.app/Contents/MacOS/AgentIsland --measure --exit-after 300
```

报告含 `dataMode`、`presentation`、CPU、驻留内存、真实数据峰值、`firstQuotaMs` / `firstSessionMs`。首次指标从程序入口起使用单调时钟计时，到真实服务结果进入 Store；空订阅不计入会话首批，错误不计入额度首批。它们不是屏幕实际绘制时间。`presentation=headless` 的结果不能替代窗口、真实数据、显示器和能耗验收。

## 致谢 / 灵感来源

受 Notchy、NookX 等刘海应用启发。AgentIsland 是独立项目，与 Anthropic、OpenAI 及上述应用没有隶属关系。

## 许可证：MIT

见 [LICENSE](LICENSE)。Copyright (c) 2026 AgentIsland contributors。
