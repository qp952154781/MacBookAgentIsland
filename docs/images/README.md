# 演示截图

三张 PNG 均由 App 的离屏 `--snapshot` 路径生成，再用系统 `sips` 裁剪。该路径固定调用 `IslandStore.mock`，额度、套餐、标题、系统指标、背景与几何均为演示数据，不读取真实账号或会话。`active.png` 是动画的静态帧。

| 文件 | 场景 | 输出尺寸 |
|---|---|---|
| `collapsed.png` | idle / collapsed，两家剩余额度 | 800 × 140 |
| `active.png` | busy / active，双侧图标与活动条 | 800 × 140 |
| `expanded.png` | sessions-grid-12 / expanded，指标、额度卡、12 个假会话按家分列（左 Claude 6 个、右 Codex 6 个；首屏各显示 3 个，其余一起滚动） | 1200 × 525 |

在项目根目录复现：

```sh
scripts/snapshot.sh out/snapshots/m6
mkdir -p docs/images
sips --cropToHeightWidth 140 800 --cropOffset 0 320 out/snapshots/m6/collapsed-idle.png --out docs/images/collapsed.png
sips --cropToHeightWidth 140 800 --cropOffset 0 320 out/snapshots/m6/collapsed-both-active.png --out docs/images/active.png
swift -module-cache-path .build/module-cache tools/scrub-png.swift docs/images/collapsed.png docs/images/active.png
```

M8 的按家分列展开态单独生成，不改动收起态与活动态图片：

```sh
scripts/snapshot.sh out/snapshots/m8
sips --cropToHeightWidth 840 1920 --cropOffset 0 60 out/snapshots/m8/sessions-grid-12.png --out docs/images/expanded.png
sips --resampleWidth 1200 docs/images/expanded.png
swift -module-cache-path .build/module-cache tools/scrub-png.swift docs/images/expanded.png
```

源快照位于被忽略的 `out/`；本目录中的三张小图供 README 引用，应与文档一起纳入版本控制。`scripts/snapshot.sh` 固定以 `TZ=UTC` 启动离屏进程；日期来自固定 mock 时间戳，并以 UTC 显示，不暴露运行机器的本地时区。直接调用 `--snapshot` 时也应加 `TZ=UTC`。额度与基础会话对应 `MockData.swift`，按家分列的会话来自 `SnapshotExporter.sessionGridFixtures` 的手写样例，系统指标与屏幕几何对应 `SnapshotExporter.swift`，不代表作者的账号、设备或使用习惯。

最后一步按 PNG 区块白名单保留像素、透明度和标准色彩信息，移除 EXIF、XMP、文本、时间等附加元数据，像素数据不重编码。`sips -g all` 不会列出所有 XMP 字段，不能单独作为元数据清理的依据。
