# Fast DDS 内存池与 DataSharing 共享内存笔记

> 主题:RTPS 层的 Change/Payload 内存池体系,重点是 DataSharing 跨进程共享内存零拷贝,以及底层共享内存模块(段管理 / seqlock / robust 锁 / offset 寻址)。
> 结论先行:这套实现基本是**业界成熟标准手法的组合**,每一项都有权威出处(见文末引用)。

---

## 1. 全局视角:一条数据的两块内存

DDS 里"一条数据"由两块东西组成,各有各的池:

```
CacheChange_t(样本对象:序列号/GUID/kind/instanceHandle...)  ← Change Pool 管
     └── serializedPayload(真正的字节数据 buffer)             ← Payload Pool 管
```

| 维度 | 接口 | 管什么 | 特点 |
|---|---|---|---|
| 对象池 | `IChangePool` | `CacheChange_t` 对象 | 固定大小 |
| 内存池 | `IPayloadPool` | `SerializedPayload_t` 字节缓冲 | 大小可变 |

接口位置:`include/fastdds/rtps/history/IChangePool.hpp`、`include/fastdds/rtps/history/IPayloadPool.hpp`

---

## 2. 池实现全景(1 change + 3 payload = 4 个实现类)

```
IChangePool
   └── CacheChangePool              唯一实现,双 vector(free_caches_/all_caches_)

IPayloadPool
   ├── ① BasicPayloadPool           退化版:不建池,蹭 change 池;RTPS 裸层默认
   │      BaseImpl + 4 策略特化
   ├── ② TopicPayloadPool           真池:free-list + 原子引用计数;DDS 层
   │      + TopicPayloadPoolRegistry(进程内单例,按 topic 名共享)
   │      + PayloadNode(带 ref_counter)
   └── ③ DataSharingPayloadPool     共享内存零拷贝:跨进程同主机
          WriterPool(写) / ReaderPool(读)
```

横切维度:每种池内部还分 **4 种内存策略**
- `PREALLOCATED` 固定预分配、零运行期分配(实时系统)
- `PREALLOCATED_WITH_REALLOC` 保底 + 可增长(Fast DDS 默认)
- `DYNAMIC_RESERVE` 按需分配、用完真归还(省内存)
- `DYNAMIC_REUSABLE` 按需分配、留着复用(换吞吐)

### 三族 Payload Pool 对比

| | Basic | Topic | DataSharing |
|---|---|---|---|
| 内存位置 | 进程堆 | 进程堆 | **共享内存段** |
| 共享范围 | 单端点 | 同进程同topic | **跨进程同主机** |
| 寻址 | 指针 | 指针 | **offset(进程无关)** |
| 同步 | 无 | mutex+原子引用计数 | **无锁 seqlock** |
| 数据结构 | 蹭 change 池 | free-list | **环形缓冲+超越检测** |
| 语义 | 可靠 | 可靠 | 高吞吐可容忍丢 |
| 使用者 | `WriterHistory`/`BaseReader` 默认 | `DataReaderImpl`/`DataWriterImpl` | 开 DataSharing QoS 时 |

关键调用点:
- `src/cpp/rtps/history/WriterHistory.cpp:80` → `BasicPayloadPool::get(...)`
- `src/cpp/rtps/reader/BaseReader.cpp:70` → `BasicPayloadPool::get(...)`
- `src/cpp/fastdds/subscriber/DataReaderImpl.cpp:1901` → `TopicPayloadPoolRegistry::get(topic_name, config)`

---

## 3. TopicPayloadPool 要点(进程内共享)

- 双 vector:`free_payloads_` / `all_payloads_`(与 CacheChangePool 同款套路)。
- `PayloadNode` 内存布局:`[ref_counter | data_size | data_index | data...]`,元数据紧贴数据;`data - offset` 反推元数据。
- **零拷贝共享**:`get_payload(data,payload)` 里若 `data.payload_owner == this`(同池)→ 只 `reference()` 引用计数 +1,共享同一块内存。
- **回收**:`release_payload` 里 `dereference()` 归零者才放回 free-list(类似 shared_ptr)。
- **共享作用域**:进程内单例 `TopicPayloadPoolRegistry`(`static` 单例 + `unordered_map<topic名>`),共享 key = **(同进程 + 同 topic + 同内存策略)**。
- `TopicPayloadPoolRegistryEntry`:map 的 value,一 topic 对应 4 个策略插槽,用 `weak_ptr` → 无人使用自动回收。

> 两个价值要分清:**池复用**(free-list)单端点也有效;**引用计数零拷贝共享**才需要同进程多端点。
> 主战场:intraprocess(同进程 pub+sub,如 ROS 2 组件化容器,图像/点云零拷贝)。

文件:`src/cpp/rtps/history/TopicPayloadPool.{hpp,cpp}`、`TopicPayloadPoolRegistry*`

---

## 4. Intraprocess:如何判定"同进程"走零拷贝

判定**不在 get_payload 里**,而在**发现/匹配阶段**预先算好并缓存:

```
匹配阶段:ReaderLocator.cpp:85
   is_local_reader_ = RTPSDomainImpl::should_intraprocess_between(writer_guid, reader_guid)
   优先级:intraprocess > datasharing > network(见 line 86: is_datasharing &= !is_local_reader_)
        ↓ 结果缓存
writer 把 reader 分两个列表:matched_local_readers_(同进程) / 远程
        ↓ 发送时分流(StatefulWriter.cpp:2174)
   there_are_local_readers_ → deliver_sample_to_intraprocesses → intraprocess_delivery
        ↓ (StatefulWriter.cpp:423)
   local_reader->process_data_msg(change)   // 直接传指针,不序列化、不走网络
        ↓ reader 存 history 调 get_payload(data)
   data.payload_owner == this(共享同一 TopicPayloadPool) → 零拷贝
```

⭐ 所以"调哪个重载/是否零拷贝"是上游路由的**下游结果**,匹配时(GUID 比较)就定了。

---

## 5. DataSharingPayloadPool(跨进程共享内存零拷贝)★核心

### 5.1 共享内存段的三区结构

```
共享内存段 segment_:
   ① payloads_pool_  —— N 个 PayloadNode(元数据 + 真实数据)
   ② history_        —— offset 环形数组(记录哪些 payload 在历史里)
   ③ descriptor_     —— PoolDescriptor(history_size / notified_begin / notified_end / liveliness_sequence)
```

- WriterPool `create_only` 创建段;ReaderPool `open_read_only` 映射同一段。
- 只有 WriterPool 能 `get_payload(size)` 分配;ReaderPool 该重载直接 `return false`(只读消费)。

### 5.2 四大难题与解法

**难题①:指针跨进程无效 → 用 offset**
- 同一段共享内存在不同进程映射到不同基址(0x7000 vs 0x9000),存指针=野指针。
- `history_` 存 offset(相对段基址的偏移),写时 `get_offset_from_address`,读时 `get_address_from_offset`。
- offset = 地址 − 段基址;地址 = 段基址 + offset;段内布局相同 → offset 进程无关(类比:书的页码)。

**难题②:跨进程不宜加锁 → 无锁 seqlock**
- 写端:数据填完,**最后**写 `sequence_number`(signal ready)—— `WriterPool.hpp:284`。
- 取新块:**先**清零 `sequence_number` 标记脏 —— `DataSharingPayloadPool.hpp:208`。
- 读端:读完**再验一次** `sequence_number`,变了=被覆盖,丢弃重读 —— `ReaderPool.hpp:254`。
- 这就是 Linux 内核 **seqlock** 模式(读前读后验序列号)。

**难题③:writer 不等 reader → 环形缓冲 + 超越检测**
- `history_` 环形(`advance` 绕回),writer 可能套圈覆盖 reader 未读数据。
- `next_payload_` 用 64 位:**低 32 位=环形索引,高 32 位=圈数**,比圈数即可判断 writer 是否超越 reader(`ReaderPool.hpp:282` ensure_reading_reference_is_in_bounds)。
- 定位:高吞吐、writer 优先、可容忍丢(适合传感器流)。

**难题④:进程崩溃健壮性**
- WriterPool 析构只 `segment_->remove()` 标记删除,不销毁对象(reader 可能还在读),全部关闭后 OS 才回收(类 unlink 语义)—— `WriterPool.hpp:53`。
- reader 靠 seqlock 校验跳过脏/半写数据,writer 崩溃不会带崩 reader → **跨进程崩溃隔离远好于 intraprocess**。

文件:`src/cpp/rtps/DataSharing/{DataSharingPayloadPool.hpp, WriterPool.hpp, ReaderPool.hpp}`

---

## 6. 底层共享内存模块(`src/cpp/utils/shared_memory/`)

| 文件 | 作用 |
|---|---|
| `SharedMemSegment.hpp` | 段封装,基于 Boost.Interprocess |
| `SharedMemUUID.hpp` | UUID 唯一标识(含 `std::hash` 全特化,让 UUID 能当 unordered_map key) |
| `SharedDir.hpp` | 共享目录/锁文件路径 |
| `RobustSharedLock.hpp` | 健壮共享锁(flock) |
| `RobustExclusiveLock.hpp` | 健壮独占锁 |
| `RobustInterprocessCondition.hpp` | 健壮跨进程条件变量 |
| `SharedMemWatchdog.hpp` | 看门狗,清理僵死资源 |

### 6.1 段类型:T/U 两层模板参数

```cpp
template<typename T, typename U> class SharedSegment ...
   typedef T managed_shared_memory_type;   // 托管段:管"段内内容"(new/get/allocate)
   typedef U managed_shared_object_type;   // 底层对象:管"OS 资源"(主要 U::remove 删段)
```
- `SharedMemSegment` = `<basic_managed_shared_memory, shared_memory_object>`(纯内存,快)
- `SharedFileSegment` = `<basic_managed_mapped_file, file_mapping>`(文件映射,兼容性好)
- Boost 分两层:T 架在 U 之上,换 U 即换存储介质。

### 6.2 两进程如何拿到"同一段":靠段名握手

```
段名 = "fast_datasharing_" + writer_GUID    (generate_segment_name)
Writer:用自己 GUID 生成段名 → create_only 创建
   ↓ discovery(SPDP/EDP)把 writer GUID 传给 reader
Reader:用收到的 writer GUID + 同一函数 → 同样段名 → open_read_only 打开同段
```
⭐ OS 保证"同名=同一物理内存对象"。GUID 全局唯一 + discovery 传递 + 同规则派生段名 → 握手成立。
底层:POSIX `shm_open` / Windows `CreateFileMapping`(由 Boost 封装)。

### 6.3 RobustSharedLock:flock 做进程存活检测

- 用 `flock(fd, LOCK_SH/LOCK_EX, LOCK_NB)` 对锁文件加建议锁(`RobustSharedLock.hpp:349` Linux 版)。
- **健壮性根基**:flock 的锁在**进程退出/崩溃时由内核自动释放** → 天然可检测"创建者是否还活着"。
- 用途:检测某共享资源是否还有进程在用(`is_locked`),无人用则清理(`test_lock(..., remove_if_unlocked=true)`)。
- 对应注释:"holds a lock until destroyed, or until the creator process dies"。

---

## 7. 业界标准印证

| Fast DDS 做法 | 业界标准/出处 |
|---|---|
| 共享内存 IPC + offset_ptr | OS 标准 / Boost.Interprocess |
| 序列号乐观读(先写数据后写序列号,读后校验) | **Linux 内核 seqlock** |
| offset 而非指针 | seqlock 文档明确"读端不能用指针" → 印证设计 |
| flock 建议锁做进程存活检测 | 经典 Unix 手法 |
| robust 互斥/条件变量 | POSIX `PTHREAD_MUTEX_ROBUST` |
| 整体架构(共享内存池 + loan + 仅定长POD) | 与 Eclipse iceoryx(Bosch)、eCAL、CycloneDDS+iceoryx 收敛 |

### 引用链接
- Fast DDS 零拷贝官方文档:https://fast-dds.docs.eprosima.com/en/stable/fastdds/use_cases/zero_copy/zero_copy.html
- Linux Kernel seqlock:https://docs.kernel.org/locking/seqlock.html
- iceoryx "A True Zero-Copy RMW Implementation for ROS2"(ROSCON 2019, Bosch):https://roscon.ros.org/2019/talks/roscon2019_truezerocopy.pdf
- Fast-DDS Discussion #3654(data-sharing vs SHM transport):https://github.com/eProsima/Fast-DDS/discussions/3654
- Boost.Interprocess(offset_ptr / managed segments)官方文档
- POSIX `pthread_mutexattr_setrobust`

---

## 8. 一句话总纲

> 通信距离由近到远,性能与复杂度递增:
> **Basic(单端点轻量) → Topic(同进程零拷贝共享,引用计数)→ DataSharing(跨进程共享内存零拷贝,offset+seqlock+环形缓冲)**。
> DataSharing 正是"进程独立(故障隔离)+ 共享内存(高性能)"的甜点方案,化解"性能 vs 隔离"矛盾;底层靠段名握手(GUID+discovery)、offset 寻址、seqlock 无锁、flock 健壮锁支撑,全部为业界成熟标准手法。
