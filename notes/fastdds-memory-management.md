# Fast DDS 底层内存管理笔记

> 配套类图:`notes/fastdds-datatypes-classdiagram.drawio`
> 相关笔记:`notes/fastdds-payloadpool-datasharing.md`（Payload Pool + DataSharing 细节）

---

## 0. 一句话总览

Fast DDS 底层内存管理 = **"信封池（CacheChangePool，按数量）+ 数据池（IPayloadPool，按大小）"双池解耦**，由 `WriterHistory/ReaderHistory` 协调；数据池提供三档能力——Basic（基础复用）、Topic（同进程引用计数零拷贝）、DataSharing（跨进程共享内存 + seqlock）；四种内存策略在"预分配换实时性"与"动态分配换省内存"之间权衡；再辅以 realloc 安全、`flock` 僵尸检测、健壮跨进程条件变量、读优先 `shared_mutex` 等一整套工业级健壮性机制。

---

## 1. 核心思想：两个正交的池

一条数据被拆成两块独立管理的内存：

```
CacheChange_t（信封 / 元数据）          ← IChangePool 管理，按【数量】池化
      │ 内嵌 serializedPayload 成员
SerializedPayload_t.data（数据缓冲区）   ← IPayloadPool 管理，按【字节大小】池化
```

**为什么拆开：**

| | CacheChange_t 结构体 | payload.data 缓冲区 |
|---|---|---|
| 大小 | 固定（元数据） | 可变（取决于消息） |
| 池化依据 | 按数量 | 按字节大小 |
| 生命周期 | 每样本一个 | 可被多 change 共享、跨进程、零拷贝 |
| 谁管 | `IChangePool` | `IPayloadPool` |

**谁协调：** `WriterHistory` 同时持有两个池，配对使用：

```cpp
// src/cpp/rtps/history/WriterHistory.cpp (约 407-433)
if (!change_pool_->reserve_cache(reserved_change)) { ... }          // ① 借空信封
if (!payload_pool_->get_payload(payload_size,
        reserved_change->serializedPayload)) {                      // ② 往信封装数据
    change_pool_->release_cache(reserved_change);
}
```

---

## 2. Change 池：CacheChangePool

- 实现 `IChangePool`（`src/cpp/rtps/history/CacheChangePool.h/.cpp`）。
- 两个向量：`all_caches_`（全部，用于析构）+ `free_caches_`（空闲复用）。
- `create_change()` = `new CacheChange_t()`，`destroy_change()` = `delete change`，**只管结构体本身，从不碰 payload 数据**。
- `.h` 注释明确：`payload_initial_size is not being used`。
- 释放复用：`return_cache_to_pool()` 只重置元数据（kind / GUID / seqNum / inline_qos.length=0…）再放回 `free_caches_`；`DYNAMIC_RESERVE` 模式用 swap-and-pop 真正 delete。

---

## 3. Payload 池：IPayloadPool 三大家族

接口（`include/fastdds/rtps/history/IPayloadPool.hpp`）：

```cpp
virtual bool get_payload(uint32_t size, SerializedPayload_t& payload) = 0;             // 新建
virtual bool get_payload(const SerializedPayload_t& data, SerializedPayload_t& payload) = 0; // 拷贝/零拷贝
virtual bool release_payload(SerializedPayload_t& payload) = 0;
```

| 家族 | 场景 | 关键机制 |
|---|---|---|
| **BasicPayloadPool** | 默认、点对点 | 搭 `CacheChangePool` 复用，无独立 free-list；`BasicPayloadPool::get(cfg, change_pool_)` |
| **TopicPayloadPool** | 同进程、同 topic、多端点 | `PayloadNode` 带 atomic `ref_counter` 零拷贝共享；`TopicPayloadPoolRegistry` 单例按 topic 复用 |
| **DataSharingPayloadPool** | 跨进程 | 共享内存 + seqlock，near-zero-copy 且进程隔离 |

继承关系：

```
IPayloadPool
├─ BasicPayloadPool
├─ ITopicPayloadPool
│    └─ TopicPayloadPool
│         ├─ PreallocatedTopicPayloadPool
│         ├─ PreallocatedReallocTopicPayloadPool
│         ├─ DynamicTopicPayloadPool
│         └─ DynamicReusableTopicPayloadPool
└─ DataSharingPayloadPool
     ├─ WriterPool
     └─ ReaderPool
```

---

## 4. 四种内存管理策略

| 策略 | 预分配 | 可增长 | 释放行为 | 适用 |
|---|---|---|---|---|
| `PREALLOCATED_MEMORY_MODE` | ✅ 定长 | ❌ | 回收进 free-list | 硬实时，杜绝运行时分配抖动 |
| `PREALLOCATED_WITH_REALLOC_MEMORY_MODE` | ✅ | ✅ 扩容 | 回收进 free-list | 实时 + 偶发大消息 |
| `DYNAMIC_RESERVE_MEMORY_MODE` | ❌ 按需 | ✅ | 真正 delete | 内存敏感 |
| `DYNAMIC_REUSABLE_MEMORY_MODE` | ❌ | ✅ | 回收进 free-list 复用 | 大小波动大 |

**取舍：** 实时/硬实时用 `PREALLOCATED`；内存敏感/长尾大小用 `DYNAMIC_*`。

---

## 5. 零拷贝的两条路径

### 5.1 同进程：TopicPayloadPool
- 多个 reader 共享同一份 `PayloadNode`，靠 atomic `ref_counter` 计数。
- `get_payload(const data&, payload)`：若 `data.payload_owner == this` 则零拷贝（引用计数 +1），否则真拷贝。
- `payload_owner` 指针标识"这块内存归哪个池管"，决定正确的 `release_payload`。
- 是否走同进程由 RTPS 发现/匹配阶段决定（`RTPSDomainImpl::should_intraprocess_between`，比较 GUID），结果缓存为 `is_local_reader_`。

### 5.2 跨进程：DataSharingPayloadPool
- 三段共享内存：payload 环形缓冲 + history + descriptor。
- **offset 而非指针**寻址（不同进程映射基址不同）。
- **seqlock 乐观并发**：writer 写完最后更新 `sequence_number`；reader 读前读后校验一致才采信。
- 环形缓冲用 64-bit 索引检测覆盖（overtake）。
- **通知链路**（数据面 / 通知面分离）：
  - 数据段按 writer GUID 命名；通知段按 reader GUID 命名。
  - `DataSharingNotification`：reader 建的跨进程 cv + mutex + `atomic<bool> new_data`。
  - `DataSharingNotifier`：writer 侧 `open` reader 通知段，写完数据远程 `notify()`。
  - `DataSharingListener`：reader 侧监听线程，被唤醒后遍历各 writer 数据段用 seqlock 拉数据，喂给统一的 `process_data_msg` 管线。

---

## 6. 健壮性设计

- **realloc 安全**：`SerializedPayload_t::reserve` 先存 `old_data` 再 realloc，异常安全，并 `memset` 新空间。
- **崩溃恢复**：共享段析构 `segment_->remove()`；`RobustSharedLock`（基于 `flock`）检测"僵尸段"——进程崩溃时内核自动释放文件锁，别的进程据此判定资源可回收（`is_zombie`）。
- **健壮跨进程条件变量**：`RobustInterprocessCondition` 用固定大小的 `interprocess_semaphore` 池 + 侵入式链表（用 uint32 索引代替指针），抗崩溃，弥补 `std::condition_variable`（进程内）与 Boost 原生 `interprocess_condition`（不够健壮）的不足。

---

## 7. 并发原语：自研 shared_mutex

- 文件：`src/cpp/utils/shared_mutex.hpp`（源自 Howard Hinnant 经典实现）。
- `state_` 位打包：最高位 `write_entered_`（写标志）+ 低位 `n_readers_`（读者计数），用 `CHAR_BIT` 计算。
- 提供读优先 / 写优先两个特化；Fast DDS **默认读优先**，支持读锁可重入。
- 为何不用 `std::shared_mutex`：标准不保证读写优先级（平台相关，写优先下会出特定死锁）、读锁不可重入、且需兼容 pre-C++17。

---

## 8. 与业界对比

- **对象池 + 内存策略**：高频实时系统标配（游戏引擎、交易系统同理）。
- **DataSharing（共享内存 + seqlock + 健壮锁）**：对标 iceoryx（真零拷贝 IPC）；僵尸检测/租约思想与 Chubby/ZooKeeper 一脉相承。是有论文与工业实践支撑的成熟范式。

---

## 9. 快速索引（关键文件）

| 模块 | 文件 |
|---|---|
| CacheChange 结构 | `include/fastdds/rtps/common/CacheChange.hpp` |
| SerializedPayload | `include/fastdds/rtps/common/SerializedPayload.hpp` / `.cpp` |
| Change 池接口/实现 | `include/fastdds/rtps/history/IChangePool.hpp`、`src/cpp/rtps/history/CacheChangePool.h/.cpp` |
| Payload 池接口 | `include/fastdds/rtps/history/IPayloadPool.hpp` |
| Basic/Topic 池 | `src/cpp/rtps/history/BasicPayloadPool*`、`TopicPayloadPool*` |
| 协调者 | `src/cpp/rtps/history/WriterHistory.cpp` |
| DataSharing | `src/cpp/rtps/DataSharing/*`（Pool / Notification / Notifier / Listener） |
| 共享内存/健壮锁 | `src/cpp/utils/shared_memory/*`（SharedMemSegment / RobustSharedLock / RobustInterprocessCondition） |
| 读写锁 | `src/cpp/utils/shared_mutex.hpp` |
