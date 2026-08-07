# 误用驱动鲁棒性测试活动：Wi-Fi 生命周期模块

## 0. 范围

- 系统：Wi-Fi lifecycle module
- 版本：9d18f24
- 环境：专用测试板，模拟 wpa control socket

## 1. 声明与风险

| ID | 声明 | 影响 | 可能性 | 风险分 |
|---|---|---:|---:|---:|
| C1 | 未绑定接口时 enable 明确失败且不创建后台线程 | 3 | 4 | 12 |
| C2 | disable 后到达的旧扫描事件不能修改新实例 | 5 | 3 | 15 |

## 2. 轻量行为模型

- 状态：UNINIT、READY、ENABLED、SCANNING、DISABLED
- 操作：init、bind_ifname、enable、scan、disable、deliver_scan_result
- 所有权：实例 generation 标识回调所属对象

## 3. 场景

### S01：未绑定接口直接 enable

- 关联声明：C1
- 前置状态：init 完成，状态 READY，ifname 未绑定
- 正常种子路径：init → bind_ifname(wlan0) → enable
- 主要误用或故障：跳过 bind_ifname，直接调用 enable
- 操作与时间线：T+0 查询线程和 fd 基线；T+10ms 调用 enable；T+20ms 查询状态、线程和 fd；T+100ms 再次查询
- 期望不变量：返回明确错误；状态保持 READY；不创建 worker、socket 或定时器；随后绑定接口仍可正常 enable
- Oracle：比对调用前后状态、线程集合、fd 集合和定时器计数，并执行后续合法生命周期健康检查
- Oracle 执行状态：EXECUTED
- Oracle 断言总数：5
- Oracle 失败数：0
- Oracle 输出：enable 返回 ERR_IFNAME_NOT_BOUND；状态 READY；线程差集为空；fd 差集为空；后续 bind_ifname 与 enable 成功
- Oracle 证据：EV-S01-ORACLE
- 扰动命中状态：PROVEN
- 命中观测来源：调用审计分支计数器和调用序号 1842
- 扰动落地证据：调用审计记录显示 enable 在 ifname 为空时进入拒绝分支，调用序号 1842
- 扰动命中证据：EV-S01-LANDING
- 恢复要求：无需重启或清理即可继续 bind_ifname 和 enable
- 安全边界与停止条件：仅在专用测试板执行；若线程数增长超过 2 或 watchdog 超过 2 秒立即停止
- 复现信息：构建 9d18f24；配置哈希 67ca；操作历史 run-20260806-S01.json；无随机 Seed
- 结果：PASS-EVIDENCED
- 责任分类：SUT
- 回归沉淀：tests/wifi/test_enable_without_ifname.c

### S02：disable 后旧扫描结果到达

- 关联声明：C2
- 前置状态：实例 generation=41，状态 SCANNING，事件中继已保存扫描事件
- 正常种子路径：enable → scan → deliver_scan_result → disable
- 主要误用或故障：在 scan 后先 disable，再延迟投递 generation=41 的旧扫描结果
- 操作与时间线：T+0 scan；T+8ms 捕获事件；T+10ms disable；T+20ms 创建 generation=42；T+30ms 投递旧事件；T+50ms 查询新实例状态和结果缓存
- 期望不变量：旧事件被拒绝；generation=42 的状态、缓存和计数器不改变；无 UAF；新实例可再次 scan
- Oracle：检查 generation 匹配、结果缓存哈希、事件接收和丢弃计数、ASan 输出，并执行新实例 scan 健康检查
- Oracle 执行状态：EXECUTED
- Oracle 断言总数：5
- Oracle 失败数：0
- Oracle 输出：stale_event_drop 增加 1；generation=42 缓存哈希保持 5f2a；ASan 无报告；新 scan 完成
- Oracle 证据：EV-S02-ORACLE
- 扰动命中状态：PROVEN
- 命中观测来源：事件中继序号 92017、generation 日志和 stale_event_drop 计数器
- 扰动落地证据：事件日志记录 generation=41 在 generation=42 创建后被中继投递，事件序号 92017
- 扰动命中证据：EV-S02-LANDING
- 恢复要求：系统保持 ENABLED，新实例不需要重建即可继续扫描
- 安全边界与停止条件：专用测试板；事件只投递一次；出现 UAF、watchdog 或缓存写入立即停止并保全 Core
- 复现信息：构建 9d18f24；事件历史 run-20260806-S02.json；固定延迟 20ms；调度器记录 trace-92017
- 结果：PASS-EVIDENCED
- 责任分类：SUT
- 回归沉淀：tests/wifi/test_stale_scan_event.c

## 4. 安全与证据数据

- 环境隔离：专用测试板，不连接生产控制面
- 禁止操作：禁止连接真实用户网络、写入生产凭证或执行不可逆设备操作
- 自动停止条件：出现 UAF、watchdog 超过 2 秒、线程增长超过 2 或缓存被旧事件修改时立即停止
- 恢复验证：活动结束后重启模块并完成一次 init → bind_ifname → enable → scan → disable 正常生命周期
- 证据数据级别：INTERNAL
- 最小采集范围：仅模块日志、线程/fd 快照、事件历史和 ASan 输出
- 脱敏方式：设备序列号替换为测试编号，不采集 Wi-Fi 密码和访问令牌
- 访问与存放：仅项目测试组可访问的受控构建目录
- 保存与销毁：保存 90 天，缺陷关闭且回归稳定后按项目策略销毁
- 导出复核：导出前扫描凭证、用户标识、SSID 和客户数据，发现敏感字段则先脱敏

## 5. 结果与发布结论

- 已验证声明：C1、C2
- 未验证声明：无
- 剩余风险：不同内核调度下的极窄竞态窗口由长稳活动继续覆盖
- 阻塞项：无
- 环境恢复状态：RESTORED
- 环境恢复证据：EV-RECOVERY
- 发布结论：PASS
