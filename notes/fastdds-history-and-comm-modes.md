# Fast DDS：History 与通信模式判定笔记

> 主题：RTPS 的核心数据容器 **History**（它是什么、什么角色、跨层继承），以及**接收端如何判定用哪种通信模式**（进程内 / 跨进程共享内存 / SHM传输 / UDP / TCP），外加进程内内存管理、共享内存生命周期、seqlock 与套圈检测的细节补充。
> 前置笔记：`notes/fastdds-memory-management.md`、`notes/fastdds-payloadpool-datasharing.md`（内存池 / DataSharing 细节）。
> 定位：本篇是"数据层"学习的收尾，下一段进入 **RTPS 协议引擎**（Writer/Reader 状态机）。

---

## 0. 一句话总览

**History（RTPS 规范里叫 HistoryCache）是 RTPS 端点存放数据样本 `CacheChange_t` 的核心容器**，是 DDS 应用层与 RTPS 协议引擎共享的"账本"；它通过**继承跨越两层**（基类在 RTPS，子类在 DDS）。通信模式（Intraprocess / DataSharing / SHM / UDP / TCP）在**发现-匹配阶段一次性判定并缓存**，依据是对端广播的 **GUID 前缀（编码 host/process）+ DataSharing 配置 + Locator 列表**，按性能优先级依次尝试。

---

## 1. History 是什么、什么角色

- **定位**：RTPS 端点的"数据仓库"。协议引擎不直接碰用户数据，只操作 History 里的 `CacheChange_t`。
- **存储核心**：`std::vector<CacheChange_t*> m_changes`，按 `history_order_cmp` **有序**（同 Writer 按序列号，跨 Writer 按源时间戳）。
- **五大职责**：① 存储 ② 有序维护 ③ 查找定位（`find_change`/`get_change`）④ QoS 容量执行（ResourceLimits / KEEP_LAST·KEEP_ALL）⑤ 内存借还（配合 `IChangePool`/`IPayloadPool`）。
- **只管逻辑账本，不管物理内存**：内存交给两个池，通过 virtual 钩子 `do_release_cache` 触发归还——"账本与内存分离"是零拷贝的前提。

### 有序不变量带来的红利
- `get_min_change` = `front()`、`get_max_change` = `back()`，**O(1)**（HEARTBEAT 报告 [min,max] 直接用）。
- 插入用 `lower_bound + history_order_cmp` 定位，**O(log n)**，`insert` 保持有序。
- `changesRbegin()` 直接拿最新样本（KEEP_LAST 深度 1 场景）。

---

## 2. 关键澄清：History 属于 RTPS，靠"继承"承上启下

**History 本身就在 RTPS 层**（`src/cpp/rtps/history/`），由 RTPS 引擎直接操作，**不是 DDS 与 RTPS 之间的独立一层**。它之所以是两层交汇点，是因为**类层次跨越两层**：

```
        History                 抽象基类        (RTPS 层)
       ╱        ╲
WriterHistory   ReaderHistory    RTPS 层具体类（序列号 / 有序 / 重传查找）
      │              │
DataWriterHistory  DataReaderHistory   DDS 层子类（instance 分组 / Lifespan / Ownership …）
```

- 基类（RTPS）：`WriterHistory`/`ReaderHistory` 管协议需要的东西。
- 子类（DDS）：`DataWriterHistory`/`DataReaderHistory` 叠加 DDS 语义。
- **所有权/操作权**：对象由 **DDS 层创建**，建 RTPSWriter/Reader 时**传入指针**（`history->mp_writer = this` 绑定）；之后 **RTPS 做协议同步、DDS 做 write/take**，同一个对象两层共享。

### 两种 History 的角色
| | WriterHistory | ReaderHistory |
|---|---|---|
| 比喻 | 发件底稿（留着以备重传） | 收件箱（排序去重后交应用） |
| 入口 | `write()` → `add_change()`，分配递增序列号 | 网络收到 → `change_received()` |
| 何时删 | 全员 ACK 且 QoS 允许 / KEEP_LAST 顶旧 | `take()` 取走后归还池 |

> 关键：**同一条数据在 Writer 端和 Reader 端各存一份 CacheChange**，两个 History 是独立账本。

---

## 3. History 是可靠性协议的账本

RTPS 可靠通信全建立在 History 之上：
- **HEARTBEAT**：Writer 报告 History 里 [min,max]（= `get_min/max_change`）。
- **ACKNACK**：Reader 比对自己缺哪些序列号 → Writer `find_change` 重发。
- **GAP**：Writer 发现 Reader 要的数据已被 QoS 删除 → 告知"别等了"。

---

## 4. 接收端如何判定通信模式（★重点）

**判定发生在发现/匹配阶段，结果缓存；不是每条消息临时判断。** 依据来自对端 EDP 广播的元数据，按性能优先级依次尝试：

```
① 同进程？        → Intraprocess（直接指针传递 + 引用计数，连序列化都可能省）
② DataSharing 兼容？→ 跨进程共享内存零拷贝（seqlock 环形缓冲）
③ 按 Locator 选传输：
      同主机 + SHM Locator → SHM 传输
      有 UDP Locator       → UDP
      有 TCP Locator       → TCP
```

### 4.1 GUID 前缀编码了身份（无需额外交换）
`src/cpp/rtps/common/GuidUtils.hpp` 中前缀 12 字节布局：

| 字节 | 内容 | 用途 |
|---|---|---|
| 0-1 | 厂商 ID | 标识实现 |
| **2-3** | **host_id** | 判断同主机（`is_on_same_host_as` 比 2-3） |
| **4-7** | **PID + 随机数** | 判断同进程（`is_on_same_process_as` 比 2-7） |
| 8-11 | participant_id | 区分同进程多参与者 |

> 用 PID 低 16 位 + 随机 16 位（而非纯 PID）：避开 K8s PID 命名空间冲突、重启后旧参与者误判等问题。

### 4.2 Intraprocess 判定
`RTPSDomainImpl::should_intraprocess_between`：**同进程（GUID 2-7 相同）+ 库设置开启**（默认 `INTRAPROCESS_FULL`；`USER_DATA_ONLY` 排除 builtin；SPDP 永远禁用避免跨域）。结果缓存为 `is_local_reader_`。

### 4.3 DataSharing 判定
`BaseReader::is_datasharing_compatible_with`：双方 **kind ≠ OFF + `domain_ids` 有交集**。domain_id 默认含主机唯一标识 → 跨主机不匹配（SHM 本就只能同主机）。

### 4.4 两个层次别混淆
- **Intraprocess / DataSharing = 投递机制**（绕过/简化协议栈）。
- **SHM / UDP / TCP = 传输**（都要完整序列化 + 走 RTPS 消息，只是通道不同）。
- 性能序：Intraprocess > DataSharing > SHM 传输 > UDP/TCP。

---

## 5. 进程内（Intraprocess）内存管理

- **不绕过上限**，与普通模式共用同一套 QoS 资源模型；只改投递方式（Writer 直接调 Reader 的 `process_data_msg` 传指针）。
- Reader 收到后**仍用自己的** `change_pool_`/`payload_pool_` 预留资源：
  - payload：同 Topic 同进程共享 `TopicPayloadPool` 时零拷贝（`payload_owner==this` → 引用计数 +1），否则拷贝；
  - change 信封：各自独立，照占额度。
- **到达上限的处理**：
  - `KEEP_LAST(depth)`：覆盖最旧（不阻塞发送方）。
  - `KEEP_ALL + RELIABLE`：背压——`reserve_cache` 失败 → `process_data_msg` 返回 false → `intraprocess_delivery` 返回 false → Writer 保留重投 → 最终 `write()` 阻塞至 `max_blocking_time` 超时。
  - `BEST_EFFORT`：直接丢弃。
- 拒收时 `release_payload` + `release_cache` 归还池，防泄漏。
- 关键代码：`StatefulReader::process_data_msg`（reserve_cache 上限闸在约 625 行）、`StatefulWriter::intraprocess_delivery`（约 412 行）。

---

## 6. 跨进程共享内存：生命周期与并发细节（补充）

### 6.1 谁销毁、如何销毁
- **Writer 创建**段（`create_only`，名字由 Writer GUID 生成）；**Reader 只 `open_read_only`，从不销毁**。
- Writer 析构调 `segment_->remove()`（≈ `shm_unlink`）——**只解除名字，标记删除**。
- 物理内存靠**内核引用计数**：名字解除 + 最后一个映射者 `munmap`（含进程退出）→ 计数归零才真正回收。
- **无轮询、无通知**：Reader 退出只是 munmap 使计数 -1；恰好成为最后一个时触发回收。等同文件 `unlink` 后等最后一个 fd 关闭。
- 崩溃残留的僵尸段：`RobustSharedLock`/`flock`/`is_zombie` 在**创建时**兜底清理（`init_shared_segment` 先 `T::remove`）。

### 6.2 脏数据检测（seqlock，读方判断）
- Writer 写入：所有元数据填完，**最后**才写 `sequence_number`（"数据就绪"信号）；复用槽位前 `reset()` 清为 unknown（"施工中"）。
- Reader `read_from_shared_history`：**读前读后各取一次序列号**，命中任一即脏 → 丢弃重来：
  - `check == Unknown`（施工中）；
  - `check != 读前序列号`（读到一半被覆盖）。

### 6.3 环形缓冲"套圈"检测（64 位索引）
- 索引 = **高 32 位圈数 + 低 32 位槽位下标**；`advance` 每满一圈"圈数+1、槽位归零"，整体单调递增可比较。
- `ensure_reading_reference_is_in_bounds`：
  - Reader 落后 **≥2 圈** → 必被套；
  - **恰好 1 圈** → 再比槽位：`Reader槽 <= Writer槽` 则被套（`<=` 保守 + `history_size = pool_size+1` 留一格）。
- 被套后跳到"最老仍有效"位置继续读，丢弃中间被覆盖的样本（日志 warn "overtook reader"）。
- 无锁、无轮询，仅一个 64 位整数比较。

---

## 7. 顺带积累的优秀接口设计（Fast DDS 通用范式）

| 设计 | 体现 | 解决的问题 |
|---|---|---|
| NTS / 加锁成对 | `find_change` vs `find_change_nts` | 组合操作原子性 vs 不重复加锁 |
| virtual 定制点 + 默认实现 | `remove_change_nts` 超时重载（基类忽略、子类按需重写） | 基类定流程，子类按需扩展 |
| 工厂 + 私有构造 | `RTPSDomain::createParticipant` | 保证对象要么完全可用要么不给 |
| 纯虚接口隔离 | `IPayloadPool` / `IChangePool` | 依赖抽象、可替换 |
| RAII 借贷（loan） | `DataReader::read/take` + `return_loan` | 资源借还闭环、防泄漏 |
| 统一 `ReturnCode_t` | DDS 层错误码 | 实时友好（不用异常）、表达力强 |
| PIMPL | `DataReader` ↔ `DataReaderImpl` | ABI 稳定 + 编译隔离 |
| 配置对象 | QoS / Attributes | 可扩展、向后兼容 |

### 若干实现细节
- `std::unique_lock<M> lk(m, std::defer_lock)` + `try_lock_until`：实现"带超时加锁"（`lock_guard` 做不到）。
- `remove_change(ch)` 默认超时 `now() + hours(24)`：近似无限，又避免 `time_point::max()` 相加溢出。
- `RecursiveTimedMutex`（递归锁）：支持 `remove_all_changes → remove_change` 嵌套加锁。
- `history_order_cmp` 单独成 `inline` 头（`ChangeComparison.hpp`）：被 RTPS/DDS/测试 4 处复用，保证各层排序规则唯一一致。

---

## 8. 与 iceoryx 的对比（零拷贝 IPC）

| 维度 | iceoryx | Fast DDS DataSharing |
|---|---|---|
| 架构 | 中心化（RouDi 守护进程） | 去中心化（每 Writer 自建段） |
| 内存 | 全局分级 mempool + chunk | 每 Writer 一个环形段 |
| 崩溃清理 | RouDi 集中回收 | `RobustSharedLock`/`flock` 分布式检测 |
| 并发 | 无锁 SPMC 队列 + 引用计数 | seqlock + 环形缓冲 + 引用计数 |
| 寻址 | 共享内存偏移 | 共享内存偏移（offset） |
| 跨主机 | 否（纯本机） | 否（DataSharing 本机；DDS 可回退网络） |
| 定位 | 独立 IPC 中间件 | DDS 的投递优化 |

---

## 9. 快速索引（关键文件）

| 主题 | 文件 |
|---|---|
| History 基类 | `include/fastdds/rtps/history/History.hpp`、`src/cpp/rtps/history/History.cpp` |
| Writer/Reader History（RTPS） | `include/fastdds/rtps/history/WriterHistory.hpp`、`ReaderHistory.hpp` |
| DataWriter/Reader History（DDS） | `src/cpp/fastdds/publisher/DataWriterHistory.*`、`src/cpp/fastdds/subscriber/history/DataReaderHistory.*` |
| 排序器 | `src/cpp/rtps/common/ChangeComparison.hpp` |
| GUID 身份编码 | `src/cpp/rtps/common/GuidUtils.hpp`、`include/fastdds/rtps/common/Guid.hpp`、`GuidPrefix_t.hpp` |
| Intraprocess 判定 | `src/cpp/rtps/domain/RTPSDomain.cpp`（`should_intraprocess_between`） |
| DataSharing 判定 | `src/cpp/rtps/reader/BaseReader.cpp`（`is_datasharing_compatible_with`） |
| 进程内投递/接收 | `src/cpp/rtps/writer/StatefulWriter.cpp`、`src/cpp/rtps/reader/StatefulReader.cpp` |
| DataSharing 池 | `src/cpp/rtps/DataSharing/WriterPool.hpp`、`ReaderPool.hpp` |

---

## 10. 下一段学习路线（RTPS 协议引擎）

```
第 1 站：Writer/Reader 类族 + Stateless vs Stateful（已开始）
第 2 站：ReaderProxy（写方视角）/ WriterProxy（读方视角）——"状态"的载体
第 3 站：四种协议消息 DATA / HEARTBEAT / ACKNACK / GAP
第 4 站：可靠通信状态机（重传 / 丢包恢复 / 流控闭环）
第 5 站：发现引擎 PDP / EDP
```

**第 1 站要点**：`RTPSWriter/RTPSReader`（公共API）→ `BaseWriter/BaseReader`（内部基类）→ `Stateless/Stateful`。核心分野是**是否记录对端状态**：Stateless 不记（`ReaderLocator` 只记地址，BEST_EFFORT、无重传、用于 SPDP 发现）；Stateful 记录每个对端（`ReaderProxy`/`WriterProxy`，RELIABLE、支持重传、HEARTBEAT/ACKNACK）。Proxy 就是"状态"的载体。
