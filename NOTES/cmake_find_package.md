# CMake `find_package` 的两种查找模式总结

> 学习笔记 · 来源：Fast-DDS 源码阅读

## 1. 核心概念

`find_package(X)` 有 **两种工作模式**：


| 模式            | 找什么文件                              | 谁提供                   | 依赖哪个路径变量            |
| ------------- | ---------------------------------- | --------------------- | ------------------- |
| **Module 模式** | `FindX.cmake`                      | **使用方/CMake/项目自己** 提供 | `CMAKE_MODULE_PATH` |
| **Config 模式** | `XConfig.cmake` 或 `x-config.cmake` | **被找的库** 自己安装的        | `CMAKE_PREFIX_PATH` |


> 一句话区分：**Find = "外人去找它"，Config = "库自己介绍自己"**。

---

## 2. 默认调用顺序

```cmake
find_package(X REQUIRED)        # 等价于 find_package(X MODULE REQUIRED) 的默认行为
```

CMake 的执行顺序：

```
① 先走 Module 模式：搜 FindX.cmake
      ↓ 找到 → 执行 → 完成
      ↓ 没找到
② 回退 Config 模式：搜 XConfig.cmake / x-config.cmake
      ↓ 找到 → 执行 → 完成
      ↓ 没找到 → REQUIRED 则报错，否则 X_FOUND=FALSE
```

**强制只走某一种**：

```cmake
find_package(X MODULE REQUIRED)    # 强制 Module 模式
find_package(X CONFIG REQUIRED)    # 强制 Config 模式（避免递归常用这个）
```

---

## 3. Module 模式：`FindX.cmake` 的查找路径

CMake 搜索顺序：

```
1. ${CMAKE_MODULE_PATH} 列出的所有目录（按顺序）    ← 项目自定义入口
2. CMake 安装目录的 Modules/                       ← CMake 内置 150+ 个 Find 模块
   例：/usr/share/cmake-3.22/Modules/
```

### 怎么扩展？

```cmake
# 把项目自带的 modules 目录注册进去
list(APPEND CMAKE_MODULE_PATH "${PROJECT_SOURCE_DIR}/cmake/modules")
# 或老式写法：
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${PROJECT_SOURCE_DIR}/cmake/modules)
```

> ⚠️ `**set/list` 只是注册路径，不执行任何 .cmake 文件！** 真正执行需要 `find_package(X)` 或 `include(X)` 触发。

### CMake 自带的 Find 模块举例

```bash
ls /usr/share/cmake-*/Modules/Find*.cmake | head
# FindBoost.cmake、FindOpenSSL.cmake、FindThreads.cmake、
# FindZLIB.cmake、FindGTest.cmake、FindPython3.cmake、FindProtobuf.cmake ...
```

---

## 4. Config 模式：`XConfig.cmake` 的查找路径

CMake 搜索顺序（按优先级从高到低）：

```
1. X_DIR 变量指定的目录                            ← 精确指路
2. ${X_ROOT} / 环境变量 $X_ROOT
3. ${CMAKE_PREFIX_PATH} 列出的所有路径              ← 最常用
4. 系统标准位置：
   ${prefix}/lib/cmake/<x>/
   ${prefix}/lib64/cmake/<x>/
   ${prefix}/share/<x>/cmake/
   ${prefix}/share/cmake/<x>/
   其中 ${prefix} 包括：/usr、/usr/local、/opt 等
5. 环境变量 PATH 的 ../ 上级目录里的 cmake 子目录
```

### 库作者把 `XConfig.cmake` 装哪？

```
<install-prefix>/lib/cmake/<X>/
├── XConfig.cmake           ← 核心入口
├── XConfigVersion.cmake    ← 版本检查
├── XTargets.cmake          ← IMPORTED target 定义
└── XTargets-release.cmake     按 build type 分的 target 信息
```

例：`/usr/local/lib/cmake/fastdds/fastdds-config.cmake`

### 怎么让 CMake 找到非标准位置的 Config？

```bash
# 方式 A：CMAKE_PREFIX_PATH（推荐，可同时找多个库）
cmake -B build -DCMAKE_PREFIX_PATH=/opt/mylibs

# 方式 B：环境变量
export CMAKE_PREFIX_PATH=/opt/mylibs:$CMAKE_PREFIX_PATH
cmake -B build

# 方式 C：X_DIR 精确指路（只对一个包生效）
cmake -B build -Dfastdds_DIR=/opt/mylibs/lib/cmake/fastdds
```

---

## 5. 两种路径变量对照（最容易混淆）


| 变量                  | 服务于谁                        | 设它能让 CMake 找到什么                     |
| ------------------- | --------------------------- | ----------------------------------- |
| `CMAKE_MODULE_PATH` | **Module 模式**               | `FindX.cmake` 文件                    |
| `CMAKE_PREFIX_PATH` | **Config 模式** + 其它 `find_`* | `XConfig.cmake` 文件、`.so`/`.a` 库、头文件 |


**简记**：

- `MODULE_PATH` 找 **cmake 脚本**
- `PREFIX_PATH` 找 **已安装的库**（含它的 Config.cmake）

---

## 6. 完整调用顺序与触发关系

```
你写：     find_package(X REQUIRED)
              ↓
CMake：    ① 先尝试 Module 模式
              ↓ 在 ${CMAKE_MODULE_PATH} + CMake内置 Modules/ 里找 FindX.cmake
              │
              ├─ 找到 → 执行该文件
              │         （FindX.cmake 内部可能又调 find_package(X CONFIG)
              │          来"先试现代 Config 再 fallback"）
              │
              └─ 没找到 → ② 回退 Config 模式
                            ↓ 在 ${CMAKE_PREFIX_PATH} + 系统标准路径里
                            ↓ 找 XConfig.cmake
                            │
                            ├─ 找到 → 执行
                            └─ 没找到 → REQUIRED ? FATAL_ERROR : X_FOUND=FALSE
```

---

## 7. 速查图（必背）

```
   ┌────────────────────────────────────────────────────────────────┐
   │                       find_package(X)                          │
   └──────────────────┬─────────────────────────────────────────────┘
                      │
        ┌─────────────┴────────────┐
        │                          │
        ▼ ① Module 模式            ▼ ② Config 模式
   找 FindX.cmake               找 XConfig.cmake
        │                          │
   搜索路径:                    搜索路径:
   1. CMAKE_MODULE_PATH         1. X_DIR 变量
   2. <CMake>/Modules/          2. CMAKE_PREFIX_PATH
                                3. /usr/lib/cmake/X/
                                4. /usr/local/lib/cmake/X/
                                5. /usr/share/X/cmake/
                                ...
        │                          │
        ▼                          ▼
   由"使用方"提供                  由"被找的库"提供
   （CMake 内置 / 项目自己写）     （现代 C++ 库自带）
```

---

## 8. 实战决策表


| 情况                                        | 处理方式                                                       |
| ----------------------------------------- | ---------------------------------------------------------- |
| 找 OpenSSL / Boost / Threads               | CMake 自带 FindXXX.cmake，**直接调** `find_package`              |
| 找 fastcdr / foonathan_memory / Qt6        | 库自带 Config，**直接调** `find_package`（可能需 `CMAKE_PREFIX_PATH`） |
| 找 Asio / TinyXML2（老/header-only/无 Config） | 项目自己写 `FindAsio.cmake`，**加 `CMAKE_MODULE_PATH`** 后调用       |
| 想给自己的库**对外提供** find 能力                    | **推荐写 Config**（用 `install(EXPORT)` 自动生成），不推荐让用户写 FindXXX   |
| 库装在非标准位置（`/opt`、`$HOME`）                  | `-DCMAKE_PREFIX_PATH=/opt/...` 或 `-DX_DIR=...`             |
| 调试"为什么找不到"                                | `cmake --debug-find` 或 `set(CMAKE_FIND_DEBUG_MODE ON)`     |


---

## 9. 调试技巧（找不到时神器）

```bash
# 全程打印 find_* 的搜索过程（CMake ≥ 3.17）
cmake --debug-find -B build ...

# 只调试某个包
cmake --debug-find-pkg=OpenSSL -B build ...
```

```cmake
# 在 CMakeLists 里临时开启
set(CMAKE_FIND_DEBUG_MODE ON)
find_package(X REQUIRED)
set(CMAKE_FIND_DEBUG_MODE OFF)
```

输出会告诉你 CMake **挨个查了哪些路径、为啥失败**，非常有用。

---

## 10. 易踩坑提醒


| 坑                                               | 真相                                                                         |
| ----------------------------------------------- | -------------------------------------------------------------------------- |
| 以为 `set(CMAKE_MODULE_PATH ...)` 会执行 .cmake 文件   | ❌ 它只注册路径，**不触发执行**，要靠 `find_package`/`include` 触发                          |
| `find_package(X)` 自己的参数带 `::`                   | ❌ 包名永远不带 `::`，`X::Y` 是 IMPORTED target 名                                   |
| 在 FindX.cmake 内调 `find_package(X)` 时不加 `CONFIG` | ❌ 会无限递归。**必须** `find_package(X CONFIG QUIET)`                              |
| Config 模式找不到时怪 CMAKE_MODULE_PATH 设错了            | ❌ Config 模式不看 MODULE_PATH，看 **PREFIX_PATH**                                |
| 装库时 Config 文件没附带                                | ❌ 现代库构建脚本要写 `install(EXPORT ...)` + `configure_package_config_file()` 才会生成 |


---

## 11. 一句话总结

> `**find_package(X)` 默认先走 Module 模式（沿着 `CMAKE_MODULE_PATH` 找 `FindX.cmake`），找不到再回退 Config 模式（沿着 `CMAKE_PREFIX_PATH` + 系统标准路径找 `XConfig.cmake`）。** 老的、header-only、系统已装的库走 Module；现代 C++ 库走 Config。两条路径互不相干：**MODULE_PATH 找 cmake 脚本，PREFIX_PATH 找已安装的库**。

---

## 12. Fast DDS 中的实际用法对照

```cmake
# 第 221 行：为下面的 FindXXX.cmake 准备路径
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${PROJECT_SOURCE_DIR}/cmake/modules)

# 第 241 行：实际走 Config 模式
eprosima_find_package(fastcdr 2 REQUIRED)

# 第 242 行：Module 模式 + 内部 Config fallback
eprosima_find_thirdparty(Asio asio VERSION 1.13.0)

# 第 243 行：同上
eprosima_find_thirdparty(TinyXML2 tinyxml2)

# 第 245 行：纯 Config 模式（foonathan_memory 自带 Config）
find_package(foonathan_memory REQUIRED)

# 第 247 行：Module 模式（FindThirdpartyBoost.cmake 在 cmake/modules/ 下）
find_package(ThirdpartyBoost REQUIRED)

# 第 267 行：Module 模式（用 CMake 自带的 FindOpenSSL.cmake）
find_package(OpenSSL REQUIRED)
```

**每个调用都对应一条路径策略，两种模式在同一个项目里混用是常态。**

---

## 13. 相关延伸阅读

- 官方文档：`cmake --help-command find_package`
- 在线：[CMake find_package 文档](https://cmake.org/cmake/help/latest/command/find_package.html)
- Fast DDS 中的实例：
  - `cmake/modules/FindAsio.cmake` —— 多策略 fallback 查找器
  - `cmake/modules/FindTinyXML2.cmake` —— 系统包 vs 子模块
  - `cmake/modules/Findandroid-ifaddrs.cmake` —— 最简 FindXXX 模板

