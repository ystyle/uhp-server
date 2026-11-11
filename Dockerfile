# uhp-server 运行镜像
#
# 构建策略（与其他仓颉项目一致）：宿主/CI 产出二进制 → 镜像只打包，不在容器里装工具链。
# 二进制把 Cangjie 运行时静态链入，只依赖 glibc / libstdc++，所以运行镜像用 archlinux（较新 glibc）最稳。
#
#   bash scripts/build.sh
#   docker build -t uhp-server:0.1.0 .
#   docker run --rm -p 8488:8488 -v "$PWD/config/uhp-server.toml:/app/uhp-server.toml:ro" uhp-server:0.1.0
FROM archlinux:latest

RUN pacman -Syu --noconfirm --needed gcc-libs tzdata ca-certificates curl && rm -rf /var/cache/pacman/pkg

RUN useradd -u 1000 -m app

WORKDIR /app

# 从本仓构建产物拷入（CI 里可用 --build-arg UHP_SERVER_BIN=... 指定别的路径）
ARG UHP_SERVER_BIN=target/release/bin/uhp_server
COPY ${UHP_SERVER_BIN} /app/uhp_server
RUN chmod 0755 /app/uhp_server

# 配置默认放 /app/uhp-server.toml（compose 里挂卷覆盖）
COPY config/uhp-server.example.toml /app/uhp-server.toml

USER app
EXPOSE 8488
ENTRYPOINT ["/app/uhp_server"]
CMD ["--config", "/app/uhp-server.toml"]
