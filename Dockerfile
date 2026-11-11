# uhp-server 运行镜像
#
# 构建策略（与其他仓颉项目一致）：宿主/CI 产出二进制 → 镜像只打包，不在容器里装工具链。
# 二进制把 Cangjie 运行时静态链入，只依赖 glibc / libstdc++，所以运行镜像用 archlinux（较新 glibc）最稳。
#
#   bash scripts/make-dist.sh          # 编译 + 收集 dist/
#   docker build -t uhp-server:0.1.0 .
#   docker run --rm -p 8488:8488 -v "$PWD/config/uhp-server.toml:/app/uhp-server.toml:ro" uhp-server:0.1.0
FROM archlinux:latest

RUN pacman -Syu --noconfirm --needed gcc-libs tzdata ca-certificates curl \
    && rm -rf /var/cache/pacman/pkg

RUN useradd -u 1000 -m app

WORKDIR /app

# 产物来自 scripts/make-dist.sh（CI 里也可用 --build-arg 指定别的路径）。
# 注意 chmod：从 CI artifact 解出的文件会丢执行位。
ARG UHP_SERVER_BIN=dist/uhp_server
COPY ${UHP_SERVER_BIN} /app/uhp_server
RUN chmod 0755 /app/uhp_server

# harness 插件进程（isolate = true 的 harness 要用）。与主程序同目录，
# 宿主默认按「可执行文件所在目录/uhp_server.plugin」找它。
ARG UHP_PLUGIN_BIN=dist/uhp_server.plugin
COPY ${UHP_PLUGIN_BIN} /app/uhp_server.plugin
RUN chmod 0755 /app/uhp_server.plugin

# 入口脚本：容器里 PID 1 会忽略没处理器的信号，必须由它把 SIGTERM 转给 uhp_server
# （否则 docker stop 每次等满 10s 宽限后被 SIGKILL）。见 docker/entrypoint.sh。
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh

# 配置默认放 /app/uhp-server.toml（compose 里挂卷覆盖）
COPY config/uhp-server.example.toml /app/uhp-server.toml

USER app
ENV HOME=/app

EXPOSE 8488

# 优雅关闭：SIGTERM → 进程退出。仓颉没有信号注册接口，退出时靠 ACP agent 的 stdin EOF 自行退出；
# 会话回收靠 session_ttl_seconds（配置里开）。
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8488/v1/uhp || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["--config", "/app/uhp-server.toml"]
