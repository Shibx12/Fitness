# Release Checklist

## 工具链与配置

- [ ] 使用 Apple 当前允许 App Store 提交的稳定版 Xcode 构建；确认 iOS 27 与 Workout Zones API 已正式可提交。
- [ ] 核对 Bundle ID、版本号、build 号、Team、证书、描述文件和 HealthKit capability。
- [ ] Debug、Release、Archive、Analyze 和全部 XCTest 通过，且没有源码 warning。
- [ ] 在归档产物中确认 `PrivacyInfo.xcprivacy`、HealthKit entitlement 和本地化资源存在。
- [ ] 在 App Store Connect 完成隐私问卷、出口合规、截图、元数据和 TestFlight 审查。

## HealthKit 与数据

- [ ] 真机验证首次授权、拒绝、稍后授权、权限撤回和无数据状态。
- [ ] 用真实 Apple Watch workout 验证自动配置、用户自定义配置及 3、5、6、9 区间。
- [ ] 验证同一筛选范围内 BPM 边界变化提示，以及缺少 zone 时的明确文案。
- [ ] 验证成功空刷新清除旧数据；断网/查询失败保留旧数据并显示过期提示。
- [ ] 从旧版本升级，确认旧缓存被删除并从 HealthKit 完整重建。
- [ ] 锁屏后检查缓存/CSV 的完整文件保护；分享结束和页面退出后确认临时 CSV 被清理。
- [ ] 在数据选择页下拉刷新，确认成功空结果会清空旧数据，失败时保留旧数据并标记过期。
- [ ] 选择一条包含路线和 Apple Watch 跑步动态的跑步导出，核对 CSV 中 workout 元数据、事件、活动分段、统计、原始样本、心率区间、来源/设备和全部路线点；逐项拒绝权限时确认只缺少对应数据且不会导出其他健康类别。

## UI、可访问性与本地化

- [ ] iPhone SE 尺寸、主流尺寸和最大尺寸检查布局与横向图表滚动。
- [ ] 浅色/深色、高对比度、区分颜色、Reduce Motion 全部检查。
- [ ] Dynamic Type 从默认到最大辅助字号；确认筛选行和指标切换为纵向且无裁切。
- [ ] VoiceOver 顺序、标签、选择状态、刷新/导出状态和按钮点击区域检查。
- [ ] 简体中文与英文逐页检查；确认没有截断、未翻译键或错误占位符。

## 性能与稳定性

- [ ] Instruments 测量冷启动、首次 HealthKit 全量加载、刷新、长历史滚动和 CSV 导出。
- [ ] 用 Time Profiler 检查主线程；用 Allocations/Leaks 检查长历史、反复筛选与分享。
- [ ] 用 Network/energy diagnostics 和 MetricKit/TestFlight 指标观察崩溃、卡顿、内存和电量。
- [ ] 压测大量 workout、长距离跑步、长采样缺口、暂停/恢复和取消中的查询。

## 发布前回归

- [ ] 周汇总、筛选持久化、心率区间、配速、效率、步频和 CSV 内容逐项回归。
- [ ] 飞行模式、HealthKit 查询失败、低磁盘空间、后台/前台切换和强制退出恢复检查。
- [ ] 不包含测试数据、敏感日志、硬编码密钥、开发服务器或无用资源。
