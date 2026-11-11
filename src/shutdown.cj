// 优雅退出：SIGTERM / SIGINT → 停 HTTP 服务 → 回收 driver（子进程/连接）→ exit(0)。
//
// 为什么必须有显式信号处理器（两条独立的理由）：
//   ① 容器里 PID 1 的内核语义是「没有处理器的信号一律忽略」。直接让主程序当 PID 1，
//      docker stop 发的 SIGTERM 会被无视，只能等满 10s 宽限后被 SIGKILL
//      （实测 10.2s / exit 137）；
//   ② 即便是普通进程，默认行为也是「立即终止」：driver 拉起的 agent 子进程、
//      插件进程都来不及收尾。
//
// 信号处理器里只做无锁置位（信号上下文安全），真正的收尾放到后台线程：
// handler 内不能阻塞，否则信号线程卡住，进程看起来像挂了。
package uhp_server

import std.env.exit
import std.sync.{AtomicBool, Mutex}
@When[os == "Linux"]
import std.runtime.*

// 收尾句柄：installGracefulShutdown 返回它，便于宿主（和测试）主动触发或等待完成。
public class ShutdownHandle {
    private let fired = AtomicBool(false)
    private let finished = AtomicBool(false)
    private let cleanup: () -> Unit
    private let exitAfterCleanup: Bool
    // 信号处理器延迟到 start() 里建：闭包要读写 this 的成员，
    // 构造阶段（成员还没全部初始化）不允许访问
    private var handler: (Int32) -> Bool = { _ => true }

    public init(cleanup: () -> Unit, exitAfterCleanup: Bool) {
        this.cleanup = cleanup
        this.exitAfterCleanup = exitAfterCleanup
    }

    public func start(): Unit {
        // 必须返回 true：返回 false 会走默认动作（立即终止），收尾根本来不及跑
        let flag = this.fired
        this.handler = { _ =>
            flag.store(true)
            true
        }
        this.registerHandlers()
        let self = this
        spawn {
            self.watch()
        }
    }

    // 主动触发（测试用；也方便宿主在别处发起同一条收尾路径）
    public func trigger(): Unit {
        this.fired.store(true)
    }

    public func isFinished(): Bool {
        return this.finished.load()
    }

    // 等收尾跑完，返回是否在超时内完成
    public func waitFinished(timeoutMs: Int64): Bool {
        var waited: Int64 = 0
        while (waited < timeoutMs) {
            if (this.finished.load()) {
                return true
            }
            sleep(Duration.millisecond * 10)
            waited = waited + 10
        }
        return this.finished.load()
    }

    private func watch(): Unit {
        while (!this.fired.load()) {
            sleep(Duration.millisecond * 50)
        }
        try {
            this.cleanup()
        } catch (e: Exception) {
            // 收尾失败也要走完流程：这里抛出去会让进程卡在半关状态
            eprintln("[uhp-server] 收尾时出错：" + e.message)
        }
        this.finished.store(true)
        // 收尾已经把 HTTP 服务关了，main 里的 serve() 会返回、进程自然退出。
        // 这里不再主动 exit(0)：与 main 的自然退出抢会打出「runtime has been finished」的噪音。
    }

    @When[os == "Linux"]
    private func registerHandlers(): Unit {
        registerSignalHandler(Signal.SIGTERM, this.handler)
        registerSignalHandler(Signal.SIGINT, this.handler)
    }

    // 非 Linux：std.runtime 的信号 API 不可用，退化为「不注册」（宿主正常退出路径仍会收尾）
    @When[os != "Linux"]
    private func registerHandlers(): Unit {
        ()
    }
}

// 安装优雅退出。cleanup 在后台线程执行（非信号上下文），可以安全地关服务/回收资源。
// exitAfterCleanup = false 时不退出进程（测试用）。
public func installGracefulShutdown(cleanup: () -> Unit, exitAfterCleanup!: Bool = true): ShutdownHandle {
    let h = ShutdownHandle(cleanup, exitAfterCleanup)
    h.start()
    return h
}
