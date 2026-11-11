#!/bin/sh
# 容器入口：只做一件事——把 SIGTERM 转给 uhp_server。
#
# 为什么需要它：容器里 PID 1 的内核语义是「没有显式处理器的信号一律忽略」。
# 让 uhp_server 直接当 PID 1，docker stop 发的 SIGTERM 会被无视，每次都要等满 10s 宽限
# 再被 SIGKILL（实测停止耗时 10.2s、退出码 137）。shell 当 PID 1 并显式转信号后是 0.2s。
#
# 注意：这里不做优雅收尾——仓颉没有信号注册接口，进程收到 SIGTERM 就是直接结束；
# 会话回收靠配置里的 session_ttl_seconds，ACP agent 子进程靠 stdin EOF 自行退出。
set -u

/app/uhp_server "$@" &
child=$!

forward() {
    kill -TERM "$child" 2>/dev/null || true
}
trap forward TERM INT

rc=0
wait "$child" || rc=$?
exit "$rc"
