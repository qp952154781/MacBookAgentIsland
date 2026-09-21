# 演示截图

所有素材均由 App 的离屏路径生成（静态图 `--snapshot`、动图 `--snapshot-animation`，社交预览图由 `readme-expanded` 快照加文字合成），只使用内置的演示数据：额度、套餐、会话标题、项目名、自定义数据源与系统指标均为虚构，不读取真实账号、会话或设置，也不执行任何用户命令。`active.png` 是动画的静态帧。

| 文件 | 快照场景 | 内容 | 输出尺寸 |
|---|---|---|---|
| `demo.gif` | `--snapshot-animation` | README 顶部动图：从刘海展开、停留、收回，25 fps、3 秒、循环 | 900 × 470 |
| `social-preview.png` | 由 `readme-expanded` 合成 | GitHub 社交预览图（仓库 Settings → Social preview 手动上传） | 1280 × 640 |
| `collapsed.png` | `collapsed-idle` | 收起态，两家剩余额度（「显示两翼」样式） | 800 × 140 |
| `active.png` | `collapsed-both-active` | 活动态，双侧旋转图标与活动条 | 800 × 140 |
| `expanded.png` | `readme-expanded` | 展开态：含 GPU 的顶部指标带、两张额度卡、8 个虚构会话按家分列（760 pt 双列） | 1017 × 542 |
| `custom-sources.png` | `readme-custom` | 展开态：Claude、Codex 与 2 个自定义数据源组成 2×2 额度卡 | 1000 × 728 |

生成方式：

动图（曲线取自 App 的 `IslandMotion`，改动画参数后重跑即可同步）：

```sh
scripts/build.sh release
TZ=UTC .build/release/AgentIsland --snapshot-animation out/demo-animation
cp out/demo-animation/demo-expand.gif docs/images/demo.gif
```

静态截图（`TZ=UTC` 保证时间显示与说明一致）：

```sh
TZ=UTC scripts/snapshot.sh out/snapshots
sips --cropToHeightWidth 140 800 --cropOffset 0 320 out/snapshots/collapsed-idle.png --out docs/images/collapsed.png
sips --cropToHeightWidth 140 800 --cropOffset 0 320 out/snapshots/collapsed-both-active.png --out docs/images/active.png
sips --cropToHeightWidth 830 1556 --cropOffset 0 102 out/snapshots/readme-expanded.png --out /tmp/expanded.png
sips --resampleWidth 1017 /tmp/expanded.png --out docs/images/expanded.png
sips --cropToHeightWidth 900 1236 --cropOffset 0 102 out/snapshots/readme-custom.png --out /tmp/custom.png
sips --resampleWidth 1000 /tmp/custom.png --out docs/images/custom-sources.png
```

提交前已清除 PNG 中的附加元数据（如创建软件、拍摄设备等信息）。
