// 优雅退出的可测部分：触发 → 收尾在后台线程跑完 → 只跑一次。
//
// 真正的信号投递不在这里测（会给测试进程发 SIGTERM，把测试自己杀掉）；
// 信号到 flag 的那一跳由 installGracefulShutdown 注册的处理器负责，走的是同一个 trigger()。
package uhp_server

import std.sync.{AtomicInt64, Mutex}
import std.unittest.*
import std.unittest.testmacro.*

@Test
func graceful_shutdown_runs_cleanup_once(): Unit {
    let runs = AtomicInt64(0)
    let handle = installGracefulShutdown({ =>
        let _ = runs.fetchAdd(1)
    }, exitAfterCleanup: false)

    handle.trigger()
    @Expect(handle.waitFinished(3000), true)
    @Expect(runs.load(), 1)

    // 再触发一次：收尾不该重复执行（进程已经在退出流程里）
    handle.trigger()
    sleep(Duration.millisecond * 200)
    @Expect(runs.load(), 1)
}

@Test
func graceful_shutdown_cleanup_failure_does_not_hang(): Unit {
    // 收尾抛异常也要走完流程：否则进程卡在半关状态，容器里表现为等满宽限后被 SIGKILL
    let handle = installGracefulShutdown({ =>
        throw Exception("boom")
    }, exitAfterCleanup: false)
    handle.trigger()
    @Expect(handle.waitFinished(3000), true)
    @Expect(handle.isFinished(), true)
}
