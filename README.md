# Fitness

Fitness 是一个 iPhone SwiftUI App，从 HealthKit 读取户外跑步，展示周汇总、Apple Watch 心率区间、配速、跑步效率和步频，并支持按跑步筛选和按需导出 CSV。

最近一次跑步卡片将心率、配速与 HealthKit Workout Route 的实际海拔绘制为三条时间线；底部交互指标保持为时间、心率和配速，海拔不进入底部指标。

## 技术基线

- Xcode 27 / Swift 5 language mode
- iOS 27.0+
- SwiftUI、Swift Charts、HealthKit
- 无第三方依赖
- 共享 Scheme：`Fitness`

项目有意保留 iOS 27 和 Apple Workout Zones API。正式发布前必须使用 Apple 允许提交到 App Store 的稳定版 Xcode 再完成归档验证。

## 架构与数据流

`FitnessApp` 创建 `HealthDataStore`。Store 先读取短期派生缓存，再通过 `HealthDataLoading` 请求 HealthKit；`HealthKitManager` actor 查询 workout 及关联样本，`HealthDataProcessor` 生成纯派生指标，最后由 SwiftUI 卡片读取不可变的 `OutdoorRun` 值。

```text
SwiftUI -> HealthDataStore (@MainActor)
        -> HealthDataLoading
        -> HealthKitManager (actor, bounded queries)
        -> HealthDataProcessor
        -> OutdoorRun values
        -> protected, non-backed-up v5 cache
```

失败的刷新保留最近一次成功数据并标记为过期；成功但为空的刷新会清空界面和缓存。数据选择页使用下拉刷新。CSV 仅在用户点击分享后生成，除 App 派生指标外，还按需读取所选 workout 在 HealthKit 中可访问的统计、原始数量样本、元数据、事件、活动分段、Apple Workout Zones 与路线点；文件使用完整保护，并在分享结束或页面退出时删除。

## Apple Watch 心率区间约束

- 唯一来源是每次 `HKWorkout` 关联的 `HKWorkoutZoneGroup`。
- 保存 HealthKit 配置来源、实际 3–9 个 zone、Zone 编号、BPM 边界及 Apple 已归类时长。
- 不用年龄、最大/静息心率、Karvonen 或其他公式生成或修正 zone。
- 聚合只累计同编号 zone 的 Apple 时长；只有所有相关边界一致时才显示统一 BPM 范围。
- 缺失 zone 的 workout 保持缺失并明确展示，不生成替代数据。
- v5 缓存增加最近一次跑步的速度/心率时间轴和 Apple 跑步步幅；升级后从 HealthKit 重建，不沿用缺少这些字段的旧缓存。

## 构建与测试

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project Fitness.xcodeproj -scheme Fitness \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete build-for-testing

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
xcodebuild -project Fitness.xcodeproj -scheme Fitness \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

执行 XCTest 需要已安装的 iOS 27 Simulator Runtime，或在具有合法签名和 HealthKit 权限的测试设备上运行。HealthKit 真数据、后台/锁屏文件保护、VoiceOver、Dynamic Type 和性能仍应按 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) 在真机复核。

## 隐私

App 首次分析只请求读取 workout、步数、距离、速度和心率，不写入 HealthKit。用户主动导出时，才进一步请求与所选跑步相关的能量、训练负荷、跑步动态及路线读取权限。Apple Fitness 没有独立导出 API；它写入且获授权的 workout 数据通过 HealthKit 导出。派生缓存位于 Caches、启用完整文件保护并排除备份。隐私清单声明 UserDefaults 的 `CA92.1` 原因；日志和 CSV 不写入密钥或 token。
