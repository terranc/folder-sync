# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.1] - 2026-11-03

### Changed

- 进度浮层默认黑底调整为 35% 不透明，hover 时恢复全不透明，兼顾下层内容可见性与操作时的可读性。
- 浮层拖拽位置仅在本次显示期间有效，消失后重新出现时恢复设置中的左下角或右下角。
- 应用版本更新为 2.2.1（build 5）。

### Fixed

- 修复 hover 显示操作按钮和当前文件时，浮层高度、内部间距和背景位置发生抖动的问题。
- 修复浮层内容区域无法拖动及拖动不跟手的问题，改用屏幕坐标计算窗口位移。

## [2.2.0] - 2026-11-03

### Added

- 日志列表改为分批加载：默认显示最近 15 条，滚动到底部附近每次追加 50 条，最多 1000 条。
- 单条日志展开后的文件清单位置保持不变（首次 15 条，每次「查看更多」再加 50 条）。

### Fixed

- 修复快速切换分支或同一秒内连续保存同一文件时，远端可能残留旧版本的问题。自动推送改用 `--checksum`，不再只依赖文件大小和整秒修改时间。
- 修复 pending 变更通知可能被去重吞掉的问题：改为单调递增的 generation 标识，相同路径重复写入也会再次通知。
- 修复 worker 在取空队列与退出之间到达的写入可能无人消费的问题：取空后延迟 0.3 秒再确认一次。

### Changed

- 应用版本更新为 2.2.0（build 4）。

## [2.1.0]

- 初始版本。
