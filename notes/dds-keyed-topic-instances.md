# DDS Keyed Topic & Instance 完全笔记

> 围绕 Fast DDS `topic_instances` 示例的系统性总结
> 涵盖：核心概念、API、生命周期、QoS、序列化、应用场景、对比生态、常见陷阱

---

## 目录

1. [核心概念](#1-核心概念)
2. [InstanceHandle_t 详解](#2-instancehandle_t-详解)
3. [Instance 生命周期](#3-instance-生命周期)
4. [Publisher 端 API](#4-publisher-端-api)
5. [Subscriber 端 API](#5-subscriber-端-api)
6. [Instance 相关 QoS](#6-instance-相关-qos)
7. [`topic_instances` 示例分析](#7-topic_instances-示例分析)
8. [代码生成与序列化](#8-代码生成与序列化)
9. [真实工业应用场景](#9-真实工业应用场景)
10. [与其他系统对比](#10-与其他系统对比)
11. [常见陷阱](#11-常见陷阱)
12. [ROS 2 的限制](#12-ros-2-的限制)
13. [快速速查表](#13-快速速查表)

---

## 1. 核心概念

### 1.1 三层数据模型

```
┌─────────────────────────────────────────────────────┐
│  Topic（话题）                                       │
│  例："/cars/positions"                              │
├─────────────────────────────────────────────────────┤
│  Instance（实例）= Topic 内一个"对象"               │
│    ⭐ 用 @Key 字段区分                              │
│    ├─ Instance "Car_001"                            │
│    ├─ Instance "Car_002"                            │
│    └─ Instance "Car_003"                            │
├─────────────────────────────────────────────────────┤
│  Sample（样本）= Instance 的一次更新                │
│    Instance "Car_001":                              │
│       ├─ Sample @ t=1: pos(0,0)                     │
│       ├─ Sample @ t=2: pos(1,0)                     │
│       └─ Sample @ t=3: pos(2,0)                     │
└─────────────────────────────────────────────────────┘
```

### 1.2 关键类比

| DDS 概念 | 数据库类比 | 信箱类比 |
|---|---|---|
| Topic | 表 | 信箱 |
| Instance | 表中的一行（主键标识） | 收件人 |
| Sample | 该行历史更新记录的一次 | 写给收件人的一封信 |

### 1.3 本质

**DDS Keyed Topic 把"消息流"升级为"分布式对象状态数据库"**

- 普通 Topic：append-only 消息流（类似 Kafka）
- Keyed Topic：每个对象有独立状态机 + 生命周期

### 1.4 IDL 中如何声明

```idl
struct ShapeType {
    @Key string color;      // ⭐ key 字段
    long shapesize;
    long x;
    long y;
};
```

⭐ **@Key** 注解决定了哪个字段作为 instance 的"身份证"。

---

## 2. InstanceHandle_t 详解

### 2.1 数据结构

```cpp
struct InstanceHandle_t {
    octet value[16];   // ⭐ 固定 16 字节（128 bit）
};
```

### 2.2 为什么是 16 字节？

- 兼容 RTPS GUID（16 字节）
- 兼容 MD5 hash（16 字节）
- 兼容 IPv6 地址长度
- 128 bit 足够防止哈希碰撞

### 2.3 计算算法（compute_key）

```cpp
if (max_key_cdr_typesize <= 16) {
    // ① key 字段总大小 ≤ 16 字节
    handle = 直接拷贝 key 字段的字节
} else {
    // ② key 字段太大（如 string）
    handle = MD5(序列化后的 key 字段)
}
```

### 2.4 实际例子

**例 1：string key（需要 MD5）**

```idl
struct ShapeType {
    @Key string color;   // string 长度可变
}
```

```
color = "RED"
   ↓
max_key_cdr_typesize > 16
   ↓
handle = MD5(encoded("RED")) = { 0xAB, 0xCD, ..., 0x12 }
```

**例 2：整数 key（直接拷贝）**

```idl
struct Position {
    @Key uint32 id;     // 4 字节 ≤ 16
}
```

```
id = 42
   ↓
handle.value = { 0x00, 0x00, 0x00, 0x2A, 0, 0, ..., 0 }
```

### 2.5 fastddsgen 生成的代码

`ShapeTypePubSubTypes.cxx` 中（关键代码）：

```cpp
bool ShapeTypePubSubType::compute_key(
    const void* const data,
    InstanceHandle_t& handle,
    bool force_md5)
{
    ...
    if (force_md5 || ShapeType_max_key_cdr_typesize > 16) {
        // MD5 路径
        eprosima::fastdds::MD5 md5;
        md5.init();
        md5.update(key_buffer, ...);
        md5.finalize();
        for (uint8_t i = 0; i < 16; ++i) {
            handle.value[i] = md5.digest[i];
        }
    } else {
        // 直接拷贝路径
        for (uint8_t i = 0; i < 16; ++i) {
            handle.value[i] = key_buffer[i];
        }
    }
    return true;
}
```

---

## 3. Instance 生命周期

### 3.1 三种状态

```
                   register_instance()
                 ┌─────────────────────┐
                 ↓                     │
        ┌─── ALIVE ───┐                │
        │             │                │
write() │             │ ✦ dispose()    │
继续    │             │                │
        ↓             ↓                │
   ALIVE         NOT_ALIVE_DISPOSED    │
        │             │                │
        │             │ register_      │
        │             └────────────────┘
        │
        │ 所有 publisher 退出
        ↓
   NOT_ALIVE_NO_WRITERS
```

### 3.2 状态表

| 状态 | 触发 | 含义 |
|---|---|---|
| `ALIVE_INSTANCE_STATE` | `register_instance()` 或 `write()` | ✅ 实例存在且有 publisher |
| `NOT_ALIVE_DISPOSED_INSTANCE_STATE` | publisher 调用 `dispose()` | ⚠️ 实例**主动注销**（"对象消失"）|
| `NOT_ALIVE_NO_WRITERS_INSTANCE_STATE` | 所有 publisher 退出 | ⚠️ 实例**被动失联**（"对象失联"）|

### 3.3 关键区分

- **DISPOSED** = "我主动告诉你这个对象消失了"（明确语义）
- **NO_WRITERS** = "写它的人都走了，状态未知"（不确定）

---

## 4. Publisher 端 API

### 4.1 完整 API 表

| API | 作用 | 触发的 state 变化 |
|---|---|---|
| `register_instance(data)` | 注册新实例 | → ALIVE（返回 handle） |
| `write(data, handle)` | 发送样本 | 保持 ALIVE |
| `dispose(data, handle)` | 注销实例 | → DISPOSED |
| `unregister_instance(data, handle)` | 撤销注册 | → NO_WRITERS（如果是最后一个） |

### 4.2 完整用法

```cpp
ShapeType red;
red.color("RED");

// ① 注册（可选，但推荐）
auto h = writer_->register_instance(&red);

// ② 写多个样本
red.x(0);  writer_->write(&red, h);   // sample 1
red.x(1);  writer_->write(&red, h);   // sample 2
red.x(2);  writer_->write(&red, h);   // sample 3

// ③ dispose（标记消亡）
writer_->dispose(&red, h);

// ④ unregister（释放本 publisher 的所有权）
writer_->unregister_instance(&red, h);
```

### 4.3 `dispose` vs `unregister` 的区别

| 操作 | 语义 | 通知状态 |
|---|---|---|
| `dispose` | "这个对象消失了" | DISPOSED |
| `unregister` | "我不再管这个对象了" | NO_WRITERS（仅最后一个 publisher） |

⭐ **dispose 是"应用语义"，unregister 是"传输层语义"**。

---

## 5. Subscriber 端 API

### 5.1 SampleInfo 结构

```cpp
struct SampleInfo {
    InstanceHandle_t instance_handle;     // ⭐ 这条样本属于哪个 instance
    InstanceStateKind instance_state;     // ⭐ 当前 instance 状态
    SampleStateKind sample_state;         // 这条样本是否被读过
    ViewStateKind view_state;             // 这是不是新 instance
    bool valid_data;                      // ⭐ 数据是否有效（dispose 时无效）
    InstanceHandle_t publication_handle;  // 是哪个 publisher 发的
    Time_t source_timestamp;              // 发送时间戳
    int32_t disposed_generation_count;    // 该 instance 被 dispose 过几次
    int32_t no_writers_generation_count;  // 该 instance 被全员退出过几次
    ...
};
```

### 5.2 典型订阅模式

```cpp
void on_data_available(DataReader* reader) {
    SampleInfo info;
    while (RETCODE_OK == reader->take_next_sample(&shape, &info)) {
        switch (info.instance_state) {
            case ALIVE_INSTANCE_STATE:
                if (info.valid_data) {
                    // 处理实际数据
                    samples_per_instance_[info.instance_handle]++;
                }
                break;
            case NOT_ALIVE_DISPOSED_INSTANCE_STATE:
                // 处理 dispose 通知
                // ⚠️ 此时 shape 可能只有 key 字段
                disposed_instances_.push_back(info.instance_handle);
                break;
            case NOT_ALIVE_NO_WRITERS_INSTANCE_STATE:
                // 处理 publisher 全员退出
                break;
        }
    }
}
```

### 5.3 take vs read

| 函数 | 行为 |
|---|---|
| `take_next_sample` | 读取**并删除**（多数场景用这个） |
| `read_next_sample` | 只读取，**保留**（peek 场景） |

---

## 6. Instance 相关 QoS

### 6.1 Resource Limits（内存预算）

```cpp
qos.resource_limits().max_instances = 100;             // 最多 100 个 instance
qos.resource_limits().max_samples_per_instance = 10;   // 每个 instance 最多缓存 10 样本
qos.resource_limits().max_samples = 1000;              // 总样本上限
```

⭐ **必须满足**：`max_samples ≥ max_instances × max_samples_per_instance`

### 6.2 History（每个 instance 独立）

```cpp
qos.history().kind = KEEP_LAST_HISTORY_QOS;
qos.history().depth = 10;          // ⭐ 每个 instance 保留 10 个最新样本
```

⭐ **关键**：`depth` 是 **per-instance**，不是 global！

### 6.3 Durability

```cpp
qos.durability().kind = TRANSIENT_LOCAL_DURABILITY_QOS;
// ⭐ 新订阅者接入时，自动收到每个 ALIVE instance 的历史样本
```

### 6.4 Ownership（高级）

```cpp
qos.ownership().kind = EXCLUSIVE_OWNERSHIP_QOS;
// ⭐ 同一个 instance 同一时刻只能有一个 publisher "拥有"
// 用于冗余热备场景
```

### 6.5 Deadline / Lifespan（per-instance）

```cpp
qos.deadline().period = Duration_t(1, 0);    // 每秒每个 instance 至少更新一次
qos.lifespan().duration = Duration_t(5, 0);  // 每个样本 5 秒后过期
```

---

## 7. `topic_instances` 示例分析

### 7.1 示例配置

```cpp
// PublisherApp.cpp (96-115)
writer_qos.reliability().kind = RELIABLE_RELIABILITY_QOS;
writer_qos.durability().kind = TRANSIENT_LOCAL_DURABILITY_QOS;
writer_qos.history().kind = KEEP_LAST_HISTORY_QOS;
uint32_t sample_limit = samples_ + 1; // ⭐ +1 留给 dispose 样本

writer_qos.resource_limits().max_instances = instances_;
writer_qos.history().depth = sample_limit;
writer_qos.resource_limits().max_samples_per_instance = sample_limit;
writer_qos.resource_limits().max_samples = sample_limit * instances_;

// 多实例时切换为异步发布
if (instances_ > 1) {
    writer_qos.publish_mode().kind = ASYNCHRONOUS_PUBLISH_MODE;
}
```

### 7.2 Publisher 端的 register + write + dispose

```cpp
// 构造时：为每个颜色注册 instance
for (int i = 0; i < instances_; i++) {
    ShapeType shape_;
    shape_.color(shape_config_.colors[i]);   // "RED" / "GREEN" / "BLUE" ...
    InstanceHandle_t instance = writer_->register_instance(&shape_);
    instance_handles_.push_back(instance);
}

// 主循环：write 数据
for (int i = 0; i < instances_; i++) {
    writer_->write(&shape_, instance_handles_[i]);
}

// 达到样本数：dispose
if (samples_sent == samples_) {
    writer_->dispose(&shape_, instance);
}
```

### 7.3 Subscriber 端的双阶段退出

```cpp
void run() {
    // 阶段 1：等所有 instance 收齐样本
    cv_.wait(lock_, [&] {
        return stop_receiving_samples_.load() || is_stopped();
    });

    // 阶段 2：再等 50ms 看 dispose 通知
    cv_.wait_for(timeout_lock, std::chrono::milliseconds(50u), [&]() {
        return instances_disposed() || is_stopped();
    });

    stop();
}
```

### 7.4 关键设计亮点

| 设计 | 价值 |
|---|---|
| **两阶段退出** | 保证 dispose 通知机制被充分测试 |
| **`color_per_instance_` 备份** | dispose 时 shape.color() 可能为空 |
| **双 stop 标志** | 分开"停止统计"和"完全退出" |
| **三种 instance_state 全覆盖** | ALIVE / DISPOSED / NO_WRITERS |
| **资源限制精确匹配** | 不浪费内存，不丢消息 |

---

## 8. 代码生成与序列化

### 8.1 fastddsgen 生成的文件

```
ShapeType.idl                          ← 用户定义
   ↓ fastddsgen
ShapeType.hpp / .cxx                   ← 类型代码
ShapeTypePubSubTypes.hpp / .cxx        ← TypeSupport（含 compute_key）
ShapeTypeCdrAux.hpp / .ipp             ← CDR 序列化
ShapeTypeTypeObjectSupport.hpp / .cxx  ← XTypes 反射
```

### 8.2 三个核心类型别名

`ShapeTypePubSubTypes.cxx` 第 33-35 行：

```cpp
using SerializedPayload_t   = eprosima::fastdds::rtps::SerializedPayload_t;
using InstanceHandle_t      = eprosima::fastdds::rtps::InstanceHandle_t;
using DataRepresentationId_t = eprosima::fastdds::dds::DataRepresentationId_t;
```

| 类型 | 作用 |
|---|---|
| `SerializedPayload_t` | 网络传输的字节载荷（类似 HTTP Body） |
| `InstanceHandle_t` | 实例的 16 字节 ID（类似银行账号） |
| `DataRepresentationId_t` | CDR 编码版本（XCDRv1 / v2） |

### 8.3 序列化整体流程

```
应用层：ShapeType { color="RED", x=100 }
   ↓ writer_->write(&shape)
   
1️⃣ compute_key(shape, handle)         ← InstanceHandle_t
   ↓ MD5("RED") → handle.value[16]
   
2️⃣ serialize(shape, payload, XCDRv2)  ← DataRepresentationId_t
   ↓ shape → payload.data 字节
   
3️⃣ 网络发送 SerializedPayload_t        ← SerializedPayload_t
   ↓ UDP/SHM/TCP
   
4️⃣ 对端 deserialize(payload, &shape)
   ↓
应用层收到 RED 形状 ✅
```

---

## 9. 真实工业应用场景

### 9.1 场景矩阵

| 场景 | Key 字段 | Instance 数量 | 关键 QoS |
|---|---|---|---|
| **自动驾驶物体追踪** | `object_id` | 10-100 | RELIABLE + KEEP_LAST(1) |
| **飞机追踪** | `icao_address` | 100-10000 | RELIABLE + TRANSIENT_LOCAL |
| **战术目标** | `track_id` | 100-1000 | RELIABLE + Liveliness |
| **电网设备** | `device_id` | 1000-100000 | TRANSIENT_LOCAL + RELIABLE |
| **机器人** | `robot_id` | 10-100 | RELIABLE + Liveliness |
| **股票行情** | `ticker` | 1000-10000 | TRANSIENT_LOCAL + BEST_EFFORT |
| **病人监护** | `patient_id` | 10-1000 | RELIABLE + DEADLINE |
| **仿真实体** | `entity_id` | 100-10000 | KEEP_LAST(1) + BEST_EFFORT |

### 9.2 共同特征

适合用 Keyed Topic 的场景都有这些特点：

1. ⭐ **"对象集合"语义**：不是事件流，是一群对象的状态
2. ⭐ **对象有独立生命周期**：会出现、会消失
3. ⭐ **关心"最新状态"**：不是事件历史
4. ⭐ **需要独立管理**：每个对象有独立 history / QoS
5. ⭐ **新订阅者立刻同步状态**：TRANSIENT_LOCAL 保证

### 9.3 不适合 Keyed Topic 的场景

- 日志收集（按时间流，不关心"哪条日志"）
- 点击流（追加数据，不需要 dispose）
- 监控指标采样（关心趋势）
- 简单广播通知

### 9.4 真实使用者

- **自动驾驶**：Apex.AI、Baidu Apollo、Autoware
- **航空**：FAA、Eurocontrol、洛克希德·马丁
- **军事**：美国海军 AEGIS、DARPA OMS/FACE
- **工业**：西门子 SCADA、施耐德电气
- **机器人**：KUKA、ABB、Apex.OS

---

## 10. 与其他系统对比

### 10.1 综合对比表

| 系统 | 类似概念 | 与 DDS Instance 差异 |
|---|---|---|
| **MQTT** | Topic 分层 (`/cars/car_001/pos`) | 无生命周期、无 dispose 概念 |
| **MQTT 5 Retained** | Retained Message | 只能保留 1 条历史 |
| **Kafka** | Compacted Topic Key | 有 key 但没"对象状态机" |
| **NATS JetStream KV** | Bucket Key | 最接近，但需要中心 Server |
| **Redis Hash** | HSET key field | 需要主动轮询 |
| **gRPC** | 完全没有 | 需要自己实现 |
| **ROS 1** | 完全没有 | — |
| **ROS 2** | rosidl 不支持 `@Key` | 要绕过 rclcpp 用 Fast DDS |

### 10.2 用 Protobuf 模拟 Keyed Topic 的代码量

| 方案 | 代码量 |
|---|---|
| **DDS (Fast DDS)** | ~50 行 C++ ✅ |
| **Kafka Compacted Topic** | ~150 行 + Kafka 集群运维 |
| **NATS JetStream KV** | ~100 行 + NATS Server |
| **Redis Pub/Sub + Hash** | ~200 行 + 处理竞态 |
| **gRPC Server Streaming** | ~400 行 + 维护 Server |
| **原始 Protobuf 自研** | ~2000+ 行（半个 DDS）❌ |

⭐ **代码量直接反映抽象层次**。

---

## 11. 常见陷阱

### 陷阱 1：把 Topic 和 Instance 搞混

```
❌ "我想要每辆车一个 topic"
✅ "我想要一个 topic，每辆车一个 instance"
```

### 陷阱 2：以为 dispose 会删除内存

```
❌ dispose 后内存就释放了
✅ DDS 只是把 state 标记为 DISPOSED
   订阅者还能拿到这条 dispose 通知 + 之前的历史样本
```

### 陷阱 3：忘记设 max_instances

```cpp
// 默认 max_instances = 4096
// 如果你的应用有 100 万个 instance：
// ⚠️ DDS 会内存爆炸
```

### 陷阱 4：用浮点数做 key

```idl
struct BadKey {
    @Key float id;    // ❌ 精度问题
}
```

```
1.0 vs 1.00001 → 视为不同 instance
⚠️ 业务逻辑出错
```

### 陷阱 5：dispose 后再 write

```cpp
writer_->dispose(...);
writer_->write(...);   // ⚠️ 重新激活 instance（state → ALIVE）
```

⭐ `topic_instances` demo 的 PublisherApp 就有这个潜在问题。

### 陷阱 6：忘记给 dispose 留缓存槽位

```cpp
// ❌ 错误：忘记 +1
uint32_t sample_limit = samples_;

// ✅ 正确
uint32_t sample_limit = samples_ + 1;  // include dispose sample
```

### 陷阱 7：QoS 不对称导致匹配失败

```
Publisher: RELIABLE + TRANSIENT_LOCAL
Subscriber: BEST_EFFORT + VOLATILE
   ↓
⚠️ Subscriber QoS 弱于 Publisher → 匹配失败
```

⭐ DDS 强制 **Reader QoS ≥ Writer QoS**，否则不匹配。

---

## 12. ROS 2 的限制

### 12.1 现状

| 系统 | 能用 Keyed Topic 吗？ |
|---|---|
| **ROS 1** | ❌ 完全不能（不是 DDS） |
| **ROS 2 标准 API** | ❌ **不直接支持** ⚠️（巨坑） |
| **ROS 2 + 变通方案** | ✅ 可以（5 种方法） |

### 12.2 5 种变通方案

| 方案 | 上手难度 | Keyed 完整度 | 推荐度 |
|---|---|---|---|
| 1. namespace 模拟 | ⭐ | 30% | ⭐⭐ |
| 2. 手动 map | ⭐⭐ | 40% | ⭐⭐ |
| 3. XML profile | ⭐⭐⭐ | 50% | ⭐⭐⭐ |
| 4. **直接 Fast DDS** | ⭐⭐⭐⭐ | **100%** | ⭐⭐⭐⭐⭐ |
| 5. 改 rosidl | ⭐⭐⭐⭐⭐ | 100% | ⭐ |

### 12.3 推荐：方案 4（绕过 rclcpp 直接用 Fast DDS）

```cpp
class HybridNode : public rclcpp::Node {
public:
    HybridNode() : Node("hybrid_node") {
        // ROS 2 部分
        log_pub_ = create_publisher<std_msgs::msg::String>("logs", 10);
        
        // Fast DDS 原生部分（用 Keyed Topic）
        // ⚠️ 注意 ROS 2 topic 命名规则：rt/ 前缀
        dds_topic_ = dds_participant_->create_topic(
            "rt/car_positions",     // ⭐ 前缀
            type_.get_type_name(), 
            TOPIC_QOS_DEFAULT);
        // ... 完整 DDS API
    }
};
```

### 12.4 真实工业实践

- **Apollo（百度）**：放弃 ROS 2，自研 CyberRT
- **Apex.OS**：基于 ROS 2 但增强 Keyed Topic 支持
- **Autoware**：基于 ROS 2，应用层 hack 实现 instance 语义

---

## 13. 快速速查表

### 13.1 IDL 速查

```idl
struct MyType {
    @Key string id;          // 单 key
    @Key uint32 category;    // 复合 key（多个 @Key）
    double value;
}
```

### 13.2 Publisher 速查

```cpp
// QoS 必备
writer_qos.reliability().kind = RELIABLE_RELIABILITY_QOS;
writer_qos.durability().kind = TRANSIENT_LOCAL_DURABILITY_QOS;
writer_qos.history().kind = KEEP_LAST_HISTORY_QOS;
writer_qos.history().depth = N;
writer_qos.resource_limits().max_instances = M;
writer_qos.resource_limits().max_samples_per_instance = N;
writer_qos.resource_limits().max_samples = N * M;

// API 流程
auto h = writer_->register_instance(&data);  // 注册
writer_->write(&data, h);                     // 发送
writer_->dispose(&data, h);                   // 注销
writer_->unregister_instance(&data, h);       // 撤销
```

### 13.3 Subscriber 速查

```cpp
// QoS 必须 ≥ Publisher
reader_qos.reliability().kind = RELIABLE_RELIABILITY_QOS;
reader_qos.durability().kind = TRANSIENT_LOCAL_DURABILITY_QOS;
// ... 镜像配置

// 处理三种状态
while (RETCODE_OK == reader->take_next_sample(&data, &info)) {
    if (info.instance_state == ALIVE_INSTANCE_STATE && info.valid_data) {
        // 处理数据
    } else if (info.instance_state == NOT_ALIVE_DISPOSED_INSTANCE_STATE) {
        // 处理 dispose
    } else if (info.instance_state == NOT_ALIVE_NO_WRITERS_INSTANCE_STATE) {
        // 处理 publisher 全员退出
    }
}
```

### 13.4 InstanceHandle_t 速查

```cpp
struct InstanceHandle_t {
    octet value[16];   // 16 字节
};

// 计算规则：
//   key 大小 ≤ 16 字节  → 直接拷贝
//   key 大小 > 16 字节  → MD5
```

### 13.5 关键数字记忆

| 数字 | 含义 |
|---|---|
| **16** | InstanceHandle 字节数（= MD5 长度） |
| **4096** | max_instances 默认值 |
| **400** | max_samples_per_instance 默认值 |
| **5000** | max_samples 默认值 |
| **3** | instance_state 状态数（ALIVE/DISPOSED/NO_WRITERS） |
| **+1** | 给 dispose 样本预留的额外槽位 |

---

## 14. 知识体系总图

```
┌───────────────────────────────────────────────────────────────┐
│                  DDS INSTANCE 完整知识图谱                     │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  📐 概念层                                                    │
│     Topic ── Instance ── Sample                              │
│                ↑                                              │
│              InstanceHandle_t (16 字节)                       │
│                                                               │
│  🏗 实现层                                                    │
│     @Key 注解 → compute_key() → MD5 或直接拷贝                │
│                                                               │
│  🛠 API 层                                                    │
│     Publisher:  register / write / dispose / unregister      │
│     Subscriber: SampleInfo.{instance_state, instance_handle} │
│                                                               │
│  🔄 状态机                                                    │
│     ALIVE ↔ DISPOSED ↔ NO_WRITERS                            │
│                                                               │
│  ⚙ QoS 层                                                    │
│     resource_limits.max_instances                            │
│     resource_limits.max_samples_per_instance                 │
│     history.depth (per instance!)                            │
│     durability.kind (TRANSIENT_LOCAL)                        │
│     ownership.kind (EXCLUSIVE 选其一 publisher)              │
│     deadline.period (per instance!)                          │
│                                                               │
│  🌐 应用场景                                                  │
│     自动驾驶物体追踪 / 飞机追踪 / 战术目标 /                  │
│     电网设备 / 机器人 / 股票行情 / 病人监护                   │
│                                                               │
│  ⚠ 陷阱                                                       │
│     混淆 topic/instance / dispose 不删内存 /                  │
│     忘 max_instances / 浮点 key / dispose 后 write           │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

---

## 15. 学习收尾检查清单 ✅

学完 Keyed Topic 后，你应该能回答：

- [ ] Topic / Instance / Sample 三者的关系？
- [ ] `@Key` 注解的作用？
- [ ] `InstanceHandle_t` 是怎么算出来的？什么时候用 MD5，什么时候直接拷贝？
- [ ] Instance 有几种状态？分别在什么时候触发？
- [ ] `dispose` 和 `unregister_instance` 的区别？
- [ ] Subscriber 怎么知道一个 instance 被 dispose 了？
- [ ] `valid_data` 字段什么时候为 false？
- [ ] `max_instances` / `max_samples_per_instance` / `max_samples` 三者的关系？
- [ ] 为什么 `history.depth` 是 per-instance？
- [ ] `TRANSIENT_LOCAL` 在 Keyed Topic 场景的独特价值？
- [ ] 为什么 `sample_limit = samples_ + 1`？
- [ ] 多 instance 时为什么要切到 `ASYNCHRONOUS_PUBLISH_MODE`？
- [ ] dispose 后再 write 会发生什么？
- [ ] ROS 2 标准 API 为什么不能用 `@Key`？怎么解决？
- [ ] 为什么 MQTT 不能完全替代 DDS Keyed Topic？

---

## 16. 参考资料

### 16.1 标准文档

- [OMG DDS 1.4 Specification](https://www.omg.org/spec/DDS/1.4/)
- [OMG DDS-XTypes 1.3](https://www.omg.org/spec/DDS-XTypes/1.3/)
- [OMG DDS-RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5/)

### 16.2 Fast DDS 资源

- [Fast DDS 官方文档](https://fast-dds.docs.eprosima.com/)
- 本仓库示例：`examples/cpp/topic_instances/`

### 16.3 相关示例

- `examples/cpp/hello_world/` — DDS 基础
- `examples/cpp/topic_instances/` — Keyed Topic ⭐ 本笔记重点
- `examples/cpp/content_filter/` — Keyed Topic 的延伸
- `examples/cpp/discovery_server/` — 中心化发现
- `examples/cpp/flow_control/` — 流量控制

---

> **总结**：DDS Keyed Topic 是 DDS 区别于其他消息中间件的核心特性，它把"消息流"升级为"分布式对象状态数据库"。所有需要追踪"一组动态变化实体"的工业场景（自动驾驶、航空、军事、电网、机器人）都离不开它。
