# Fast DDS Learning Dev Container

一套**完全隔离、即开即用**的 Fast DDS 学习开发环境，遵循 eProsima **Tier 1** 平台要求：

- **Ubuntu 24.04 LTS** （自带 gcc-13.2，符合 Tier 1）
- **CMake / Ninja / ccache**（高速构建）
- **colcon + vcstool**（官方推荐 workspace 管理工具）
- **Fast DDS 全部依赖**已预装（asio / tinyxml2 / openssl / libp11）
- **DDS Security 工具链**（softhsm2 / pkcs11 engine）
- **调试工具**（gdb / valgrind / strace / tcpdump）

---

## 1. 使用方式（两种二选一）

### 方式 A：Cursor / VSCode Dev Container（推荐）

1. 在 Cursor 里打开本项目根目录
2. `Ctrl+Shift+P` → "Dev Containers: Reopen in Container"
3. 等待镜像构建（首次约 5~10 分钟），完成后**你的 Cursor 就直接运行在容器里**了
4. 打开终端就是容器内的 bash，所有命令都在隔离环境里执行

### 方式 B：纯 docker compose（命令行）

```bash
cd .devcontainer

# 首次：构建并启动
docker compose up -d --build

# 进入容器
docker compose exec dev bash

# 此后：每次启动只要
docker compose up -d
docker compose exec dev bash

# 用完关闭（数据保留）
docker compose down

# 彻底清理（删除 ccache/workspace volume）
docker compose down -v
```

---

## 2. 容器内目录结构

```
/workspace/
├── Fast-DDS/                ← 你的源码（从宿主机挂载，read-write）
│   └── ...
│
└── ws/                      ← colcon workspace（docker volume 持久化）
    ├── src/                 ← 放 fastcdr / foonathan_memory 源码
    ├── build/               ← 编译产物
    ├── install/             ← 安装产物
    └── log/
```

---

## 3. 在容器内编译 Fast DDS（首次完整流程）

进入容器后执行：

```bash
# 1) 准备 colcon workspace
mkdir -p /workspace/ws/src
cd /workspace/ws

# 2) 创建 .repos 文件，列出 Fast DDS 的 eProsima 依赖
cat > fastdds.repos <<'EOF'
repositories:
  fastcdr:
    type: git
    url: https://github.com/eProsima/Fast-CDR.git
    version: master
  foonathan_memory_vendor:
    type: git
    url: https://github.com/eProsima/foonathan_memory_vendor.git
    version: master
EOF

# 3) 拉取依赖源码到 ws/src/
vcs import src < fastdds.repos

# 4) 把宿主机挂进来的 Fast-DDS 软链接到 src/
ln -s /workspace/Fast-DDS src/fastdds

# 5) 编译（ccache + ninja + Release）
colcon build \
    --cmake-args -DCMAKE_BUILD_TYPE=Release \
                 -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
                 -DBUILD_SHARED_LIBS=ON \
    --executor parallel \
    --parallel-workers $(nproc)

# 6) 加载环境（这一步让 find_package(fastdds) 能找到刚编译的库）
source install/setup.bash

# 7) 跑一个示例
cd /workspace/Fast-DDS/examples/cpp/hello_world
mkdir -p build && cd build
cmake .. && make -j$(nproc)
./HelloWorld publisher   # 终端 1
./HelloWorld subscriber  # 终端 2（另开 docker compose exec dev bash）
```

---

## 4. 持久化策略

| 数据 | 存储位置 | 容器销毁后 |
|---|---|---|
| Fast-DDS 源码 | 宿主机 `../`（bind mount） | ✅ 保留（本来就在宿主机） |
| colcon 编译产物 | docker volume `fastdds-ws` | ✅ 保留 |
| ccache 编译缓存 | docker volume `fastdds-ccache` | ✅ 保留 |
| Shell 历史 | docker volume `fastdds-history` | ✅ 保留 |
| 容器内 apt 装的工具 | 容器层 | ❌ 丢失（要重装就改 Dockerfile） |

> 想完全清理重来：`docker compose down -v` 删 volume；改 Dockerfile 后 `docker compose build --no-cache` 重建。

---

## 5. 常见问题

### Q1: 我的 UID 不是 1000，文件 mount 进来权限不对？

```bash
cd .devcontainer
cp .env.example .env
# 编辑 .env，把 USER_UID/USER_GID 改成 `id -u` / `id -g` 的输出
docker compose build --no-cache
```

### Q2: DDS 多播发现不工作？

容器已配置 `network_mode: host`，仅在 Linux 宿主机上有效。Mac/Windows 上 Docker Desktop 不支持 host 网络，需要改用 bridge + UDP 端口暴露（DDS 多播跨网会更复杂）。

### Q3: 想在容器里推 git 怎么办？

`docker-compose.yml` 已把宿主机的 `~/.ssh` 和 `~/.gitconfig` 只读挂载进容器，直接 `git push` 即可。

### Q4: 想用 GUI 工具（Fast DDS Monitor）？

需要额外暴露 X11 socket。可在 `docker-compose.yml` 加：

```yaml
environment:
  DISPLAY: ${DISPLAY}
volumes:
  - /tmp/.X11-unix:/tmp/.X11-unix:rw
```

并在宿主机执行 `xhost +local:docker`。
