import Darwin
import Dispatch

// uterm-holder：每个终端会话一个进程，持有伪终端主端。uTerm 退出、崩溃、被替换，它和里面的 shell 都不受影响。
// 用法：uterm-holder <socket 目录> <socket 文件名> <列> <行> <工作目录> <可执行文件> [argv…]
// 由内嵌 XPC 服务拉起，见 `HolderServer`。环境变量 `UTERM_SSH_CONTROL_FD` 指出要留给子进程的控制通道。
let arguments = CommandLine.arguments
guard arguments.count >= 8, let cols = UInt16(arguments[3]), let rows = UInt16(arguments[4]) else {
    fputs("usage: uterm-holder <dir> <name> <cols> <rows> <cwd> <executable> <argv0> [args…]\n", stderr)
    exit(64)
}
let server = HolderServer(directory: arguments[1], socketName: arguments[2], cols: cols, rows: rows,
                          workingDirectory: arguments[5], executable: arguments[6], argv: Array(arguments[7...]),
                          childControlFD: getenv("UTERM_SSH_CONTROL_FD").flatMap { Int32(String(cString: $0)) })
server.start()
dispatchMain()
