#!/usr/bin/env python3
"""scripts/utermctl 的离线自测：起一个假的 Unix socket 服务端，把每个子命令都跑一遍。

校验三件事：请求编码（字段名 / action rawValue 与 ControlProtocol.swift 一致）、
输出格式化、错误码 → 退出码映射。不需要 uTerm 在跑，也不碰任何真实主机。

    python3 scripts/utermctl-selftest.py        # 也是 `make check-cli`
"""
import array
import base64
import hashlib
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.join(HERE, "utermctl")

FAILURES = []


def check(condition, label):
    if condition:
        print("  ok   " + label)
    else:
        print("  FAIL " + label)
        FAILURES.append(label)


def equal(actual, expected, label):
    check(actual == expected, "%s（实得 %r，应为 %r）" % (label, actual, expected)
          if actual != expected else label)


HOST = {
    "id": "6F1D0A7E-0000-4000-8000-000000000001",
    "name": "prod-web", "host": "10.0.0.1", "port": 22, "username": "deploy",
    "authMethod": "privateKey", "group": "生产", "jumpHost": "bastion",
    "sftpOnly": False, "pinned": True, "lastConnectedAt": "2026-09-09T02:00:00Z",
    "cliConnected": True, "activeForwards": 2,
}

RESULT = {
    "host": "prod-web", "hostID": HOST["id"], "output": "up 12 days\n",
    "exitCode": 0, "truncated": False, "durationMs": 137, "timedOut": False,
}

DEFAULT_PAYLOADS = {
    "ping": {"app": {"name": "uTerm", "version": "1.0.1", "build": "330",
                     "socket": "/tmp/x.sock", "controlEnabled": True,
                     "mutationsEnabled": False, "openHosts": ["prod-web"]}},
    "hosts": {"hosts": [HOST]},
    "host-key": {"hostKey": {"host": "prod-web", "algorithm": "ssh-ed25519",
                             "fingerprint": "SHA256:abc", "status": "known",
                             "firstTrustedAt": "2026-01-01T00:00:00Z"}},
    "trust": {"hostKey": {"host": "prod-web", "fingerprint": "SHA256:abc",
                          "status": "known"}},
    "run": {"result": RESULT},
    "run-many": {"results": [RESULT, dict(RESULT, host="prod-db", exitCode=1)]},
    "quick-commands": {"quickCommands": [{"id": "qc-1", "name": "磁盘水位",
                                          "command": "df -h", "serverIDs": [HOST["id"]],
                                          "serverNames": ["prod-web"],
                                          "lastRunAt": "2026-09-08T10:00:00Z"}]},
    "quick-run": {"results": [RESULT]},
    "sftp-ls": {"entries": [{"name": "app.log", "isDirectory": False, "isSymlink": False,
                             "size": 4096, "modifiedAt": "2026-09-09T01:00:00Z",
                             "permissions": 33188, "ownerName": "deploy",
                             "groupName": "staff"}]},
    "sftp-stat": {"stat": {"path": "/var/log/app.log", "size": 4096,
                           "modifiedAt": "2026-09-09T01:00:00Z",
                           "permissions": 33188, "kind": "file"}},
    "sftp-cat": {"file": {"path": "/etc/hostname", "bytes": 9, "isUTF8": True,
                          "text": "prod-web\n", "truncated": False}},
    "sftp-get": {"file": {"path": "/etc/hostname", "bytes": 9, "isUTF8": True,
                          "base64": base64.b64encode(b"prod-web\n").decode(),
                          "truncated": False}},
    "sftp-put": {},
    "macs": {"mac": {"macs": [{"id": "MAC-1", "name": "studio", "onLocalNetwork": True,
                               "connected": False}]}},
    "mac-ls": {"entries": [{"name": "Package.swift", "isDirectory": False, "isSymlink": False,
                            "size": 120, "modifiedAt": "2026-09-09T01:00:00Z",
                            "permissions": 33188, "ownerName": "me", "groupName": "staff"}]},
    "mac-read": {"mac": {"name": "studio", "path": "/Users/me/a.swift", "text": "let a = 1\n",
                         "count": 1, "totalLines": 9, "sha256": "ab" * 32}},
    "mac-grep": {"mac": {"name": "studio", "path": "/Users/me/app", "count": 3,
                         "matches": [{"path": "Sources/a.swift", "line": 4, "text": "func alpha() {}",
                                      "before": ["// 上一行"], "after": ["// 下一行"]}]}},
    "mac-find": {"mac": {"name": "studio", "found": [{"path": "Sources/a.swift", "isDirectory": False,
                                                      "size": 12, "modifiedAt": "2026-09-09T01:00:00Z",
                                                      "permissions": 33188}]}},
    "mac-tree": {"mac": {"name": "studio", "text": "/Users/me/app/\n└── Sources/", "count": 1}},
    "mac-run": {"result": RESULT},
    "mac-write": {"mac": {"name": "studio", "path": "/Users/me/n.md", "sha256": "cd" * 32, "bytes": 5}},
    "mac-edit": {"mac": {"name": "studio", "count": 1, "sha256": "ef" * 32}},
    "mac-patch": {"mac": {"name": "studio", "text": "patching file a.txt\n"}},
    "mac-mkdir": {}, "mac-rm": {}, "mac-mv": {}, "mac-cp": {}, "mac-chmod": {}, "mac-ln": {},
    "mac-xattr": {"mac": {"name": "studio", "names": ["com.apple.quarantine"]}},
    "mac-wait-change": {"mac": {"name": "studio", "names": ["/Users/me/app/build/out"], "timedOut": False}},
    "mac-shares": {"mac": {"name": "laptop", "role": "controller",
                           "roots": [{"path": "/Users/me/app", "writable": False},
                                     {"path": "/Users/me/notes", "writable": True}]}},
    "sftp-mkdir": {}, "sftp-rm": {}, "sftp-rmdir": {}, "sftp-mv": {}, "sftp-chmod": {},
    "forward-list": {"rules": [{"id": "r-1", "serverID": HOST["id"],
                                "serverName": "prod-web", "name": "pg", "kind": "local",
                                "listenHost": "127.0.0.1", "listenPort": 15432,
                                "destHost": "10.0.0.9", "destPort": 5432,
                                "autostart": True, "status": "active",
                                "bytesIn": 100, "bytesOut": 200}]},
    "forward-start": {}, "forward-stop": {}, "forward-add": {}, "forward-remove": {},
    "terminals": {"terminals": [{"id": "7A2B", "serverID": HOST["id"],
                                 "serverName": "prod-web", "windowKind": "workspace",
                                 "title": "~ — deploy@prod-web",
                                 "isKeyWindowFocused": True,
                                 "connectedAt": "2026-09-09T01:30:00Z"}]},
    "terminal-read": {"screen": {"terminal": "7A2B", "lines": ["$ uptime", "up 12 days"],
                                 "truncated": False}},
    "terminal-send": {}, "terminal-open": {"terminals": []},
    "terminal-wait": {"run": {"terminal": "7A2B0000-0000-0000-0000-000000000000",
                              "command": "sudo whoami", "state": "finished", "exitCode": 0,
                              "output": "[sudo] password for deploy:\nroot", "truncated": False,
                              "requestedAt": "2026-10-22T01:00:00Z"}},
    "disconnect": {},
    "relay-import": {"relay": {"name": "home", "endpoint": "relay.example.com:47310",
                               "relayID": "be7ee457a6407b1a", "managedHost": "prod-web",
                               "internetEnabled": True, "registered": False}},
    "relay-check": {"relay": {"name": "home", "endpoint": "relay.example.com:47310",
                              "relayID": "be7ee457a6407b1a", "latestVersion": "1.1.0",
                              "updateAvailable": False,
                              "check": {"tcp": "ok", "auth": "ok", "udp": "failed", "rttMs": 42,
                                        "serverVersion": "1.1.0", "onlineHosts": 1,
                                        "problems": ["UDP 47310 没有回应"]}},
                    "message": "TCP 通 · 认证 通 · UDP 不通"},
}


def recv_request(conn, deadline=30.0):
    """读一条请求，直到对端 `shutdown(SHUT_WR)`。

    **不能用阻塞 recv**：macOS 上 AF_UNIX 的 `shutdown(SHUT_WR)` 唤不醒一个**已经**
    睡在 `recv()` 里的对端 —— 请求最后一段数据与 shutdown 挨得足够近时，服务端读完
    数据、进 recv 睡下，随后那次 shutdown 的唤醒就丢了，两头对着等到天荒地老
    （实测这个自测约 1/8 的概率卡死；抓到的现场是客户端 `sent 1195` + `shutdown`
    都完成了，服务端却仍停在 recv）。真的 `ControlServer.readRequest` 不吃这一发，
    因为它是 `poll(POLLIN)` + 带 deadline 的 `recv(MSG_DONTWAIT)` 循环。这里用短
    超时轮询是同一个意思：每次重新进 poll 都会重新看一眼「对端还能不能发」。
    """
    conn.settimeout(0.5)
    limit = time.time() + deadline
    chunks = []
    while time.time() < limit:
        try:
            data = conn.recv(65536)
        except socket.timeout:
            continue
        if not data:
            break
        chunks.append(data)
    return b"".join(chunks)


class FakeServer(object):
    """一次连接 = 一条请求 + 一条响应，与 ControlServer 的形状一致。"""

    def __init__(self, path):
        self.path = path
        self.requests = []
        self.override = None
        # 下一次响应前先写几个 `\n` 心跳（与 ControlServer 处理期间的心跳同形）。
        self.heartbeats = 0
        # 下一次响应前先干等这么多秒、一个字节都不写（模拟 uTerm 卡死）。
        self.stall = 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(8)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            try:
                body = recv_request(conn)
                if not body:
                    continue
                request = json.loads(body.decode("utf-8"))
                self.requests.append(request)
                heartbeats, self.heartbeats = self.heartbeats, 0
                stall, self.stall = self.stall, 0
                for _ in range(heartbeats):
                    conn.sendall(b"\n")
                    time.sleep(0.05)
                if stall:
                    time.sleep(stall)
                conn.sendall(json.dumps(self._respond(request)).encode("utf-8"))
            except OSError:
                pass
            finally:
                conn.close()

    def _respond(self, request):
        if self.override is not None:
            response = dict(self.override)
            self.override = None
            response.setdefault("id", request.get("id"))
            return response
        payload = DEFAULT_PAYLOADS.get(request.get("action"))
        if payload is None:
            return {"id": request.get("id"), "ok": False, "code": "invalid_request",
                    "message": "未知动作 " + str(request.get("action"))}
        response = {"id": request.get("id"), "ok": True, "code": "ok", "message": "ok"}
        response.update(payload)
        return response

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class RejectingServer(object):
    """收满 1 KB 就回一条 `request_too_large` 并把连接拆掉 —— 复现服务端在客户端
    还没写完请求时就拒收的场景（真实触发点是 `sftp put` 的请求体超过
    `ControlProtocol.maxRequestBytes`）。拆连接的顺序与 `ControlServer.finish`
    一致：先写响应，再 `shutdown(SHUT_RDWR)` + `close`。"""

    def __init__(self, path):
        self.path = path
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(8)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            try:
                conn.recv(1024)
                conn.sendall(json.dumps({
                    "ok": False, "code": "request_too_large",
                    "message": "IPC request body is too large",
                }).encode("utf-8"))
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            finally:
                conn.close()

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


DROP = object()     # `_respond` 的哨兵：不回响应，直接关连接


class TransferServer(object):
    """新传输协议（fd 随请求交过来）的假服务端。

    与 `FakeServer` 的不同：
    1. **每条连接一个线程**，好让并发传输互不阻塞；
    2. 用 `recvmsg` 收 `SCM_RIGHTS` 的 fd，按 `SEGMENT` 一段段真的读写那个 fd，维护一份
       内存文件表 —— 于是「内容逐字节相同」「续传只补缺的区间」都能断言；
    3. 每写完一段就回一行 `{"event":"progress",…}`，与真服务端同形。

    故障注入：
    - `fail_after`：这次传输搬满这么多字节后回 `fail_code`（一次性，测自动续传）；
    - `fail_always`：非 None 时所有传输先搬 `fail_after` 字节再回这个 code（测失败留账）；
    - `busy_once`：下一次传输先回 `server_busy`（测退避）；
    - `sha_override`：None=真算；"missing"=远端没工具；其余=假的十六进制。
    """

    SEGMENT = 64 * 1024

    def __init__(self, path):
        self.path = path
        self.files = {}          # 远端路径 → bytearray
        self.requests = []       # 收到的原始请求
        self.fds_seen = []       # 每条传输请求收到的 fd 个数
        self.runs = []
        self.lock = threading.Lock()
        self.fail_after = None
        self.fail_code = "connect_failed"
        self.fail_always = None
        self.busy_once = False
        self.sha_override = None
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(32)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def reset(self):
        with self.lock:
            self.files.clear()
            del self.requests[:]
            del self.fds_seen[:]
            del self.runs[:]
            self.fail_after = None
            self.fail_code = "connect_failed"
            self.fail_always = None
            self.busy_once = False
            self.sha_override = None

    def transfers(self, action):
        return [r for r in self.requests if r.get("action") == action]

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        fds = []
        try:
            body, fds = recv_request_with_fds(conn)
            if not body:
                return
            request = json.loads(body.decode("utf-8"))
            with self.lock:
                self.requests.append(request)
            action = request.get("action")
            if action in ("sftp-get", "sftp-put"):
                with self.lock:
                    self.fds_seen.append(len(fds))
                response = self._transfer(conn, request, fds)
            elif action == "sftp-stat":
                response = self._stat(request)
            elif action == "run":
                response = self._run(request)
            else:
                response = self._fail(request, "invalid_request", "未知动作 " + str(action))
            conn.sendall(json.dumps(response).encode("utf-8") + b"\n")
        except OSError:
            pass
        finally:
            for fd in fds:
                try:
                    os.close(fd)
                except OSError:
                    pass
            conn.close()

    @staticmethod
    def _fail(request, code, message):
        return {"id": request.get("id"), "ok": False, "code": code, "message": message}

    @staticmethod
    def _ok(request, **payload):
        response = {"id": request.get("id"), "ok": True, "code": "ok", "message": "ok"}
        response.update(payload)
        return response

    def _stat(self, request):
        path = request.get("path")
        with self.lock:
            body = self.files.get(path)
        if body is None:
            return self._fail(request, "file_not_found", "没有 " + str(path))
        return self._ok(request, stat={"path": path, "size": len(body), "kind": "file",
                                       "permissions": 33188,
                                       "modifiedAt": "2026-09-10T00:00:00Z"})

    def _transfer(self, conn, request, fds):
        if not fds:
            return self._fail(request, "invalid_request", "没有随请求交来 fd")
        fd = fds[0]
        path = request.get("path")
        is_get = request.get("action") == "sftp-get"
        with self.lock:
            if self.busy_once:
                self.busy_once = False
                return self._fail(request, "server_busy", "注入的忙")
            budget = self.fail_after
            fail_code = self.fail_code
            if self.fail_always is not None:
                budget, fail_code = (self.fail_after or 0), self.fail_always
            else:
                self.fail_after = None
            if is_get:
                source = self.files.get(path)
                if source is None:
                    return self._fail(request, "file_not_found", "没有 " + str(path))
                source = bytes(source)
                size = len(source)
            else:
                size = os.fstat(fd).st_size
                ranges = request.get("ranges")
                if ranges is None:
                    if path in self.files and not request.get("force"):
                        return self._fail(request, "file_exists", "远端已存在 " + str(path))
                    self.files[path] = bytearray(size)
                target = self.files.setdefault(path, bytearray(size))
                if len(target) < size:
                    target.extend(b"\x00" * (size - len(target)))
        if is_get:
            os.ftruncate(fd, size)
        wanted = request.get("ranges")
        wanted = ([(0, size)] if wanted is None
                  else [(int(r["offset"]), int(r["length"])) for r in wanted])
        moved = 0
        for offset, length in wanted:
            cursor = offset
            while cursor < offset + length:
                if budget is not None and moved >= budget:
                    return self._fail(request, fail_code, "注入的中途失败")
                step = min(self.SEGMENT, offset + length - cursor)
                if is_get:
                    os.pwrite(fd, source[cursor:cursor + step], cursor)
                else:
                    data = os.pread(fd, step, cursor)
                    with self.lock:
                        self.files[path][cursor:cursor + step] = data
                moved += step
                event = {"event": "progress", "bytes": moved, "totalBytes": size,
                         "done": [{"offset": cursor, "length": step}]}
                conn.sendall(json.dumps(event).encode("utf-8") + b"\n")
                cursor += step
        return self._ok(request, transfer={"path": path, "bytes": moved, "totalBytes": size,
                                           "seconds": 0.01,
                                           "channels": request.get("parallel") or 8})

    def _run(self, request):
        command = request.get("command") or ""
        with self.lock:
            self.runs.append(command)
            override = self.sha_override
        if override == "missing":
            return self._ok(request, result=dict(
                RESULT, output="sh: sha256sum: command not found\n"
                               "sh: shasum: command not found\n", exitCode=127))
        if override:
            return self._ok(request, result=dict(RESULT, output=override + "  -\n"))
        tokens = shlex.split(command.split("||")[0])
        target = tokens[tokens.index("--") + 1]
        with self.lock:
            body = self.files.get(target)
        if body is None:
            return self._ok(request, result=dict(RESULT, output="", exitCode=1))
        digest = hashlib.sha256(bytes(body)).hexdigest()
        return self._ok(request, result=dict(RESULT, output=digest + "  " + target + "\n"))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def recv_request_with_fds(conn, deadline=30.0):
    """同 `recv_request`，但用 `recvmsg` 一并收 `SCM_RIGHTS` 的 fd。"""
    conn.settimeout(0.5)
    limit = time.time() + deadline
    chunks = []
    fds = []
    while time.time() < limit:
        try:
            data, ancillary, _, _ = conn.recvmsg(65536, socket.CMSG_SPACE(4 * 4))
        except socket.timeout:
            continue
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                fds.extend(array.array("i", payload[: len(payload) - len(payload) % 4]))
        if not data:
            break
        chunks.append(data)
    return b"".join(chunks), fds


def run_cli(server, argv, expect_exit=0, socket_path=None, label=None, sleep_trace=None,
            idle_timeout=None, session=None):
    env = dict(os.environ)
    env["UTERM_CONTROL_SOCKET"] = socket_path if socket_path else server.path
    # 自测本身可能就跑在 uTerm 的终端里：终端编号只在点名要测的那几条里带。
    env.pop("UTERM_SESSION_ID", None)
    if session is not None:
        env["UTERM_SESSION_ID"] = session
    if idle_timeout is not None:
        env["UTERMCTL_IDLE_TIMEOUT"] = str(idle_timeout)
    if sleep_trace:
        # 客户端只往里记退避秒数、不真的睡 —— 好断言重试次数与退避序列。
        env["UTERMCTL_SLEEP_TRACE"] = sleep_trace
    proc = subprocess.run([sys.executable, CLIENT] + argv, env=env,
                          capture_output=True, text=True)
    name = label or " ".join(argv)
    check(proc.returncode == expect_exit,
          "%s 退出码 %d（应为 %d）%s" % (name, proc.returncode, expect_exit,
                                        proc.stderr.strip()))
    # 任何一条命令都不该把 traceback 漏给调用方（它读的是 JSON + 退出码）。
    # 只在真出现时才记一条失败，免得每次调用都刷一行 ok。
    if "Traceback (most recent call last)" in proc.stderr:
        check(False, "%s 吐了 traceback" % name)
    return proc


def last(server):
    return server.requests[-1]


def main():
    root = tempfile.mkdtemp(prefix="utermctl-")
    server = FakeServer(os.path.join(root, "s.sock"))
    rejecting = RejectingServer(os.path.join(root, "reject.sock"))
    transfers = TransferServer(os.path.join(root, "transfer.sock"))
    try:
        exercise(server, root, rejecting)
        exercise_transfers(transfers, root)
        exercise_on_demand_launch(root)
        exercise_socket_path_too_long()
        print("")
        if FAILURES:
            print("%d 项失败：" % len(FAILURES))
            for item in FAILURES:
                print("  - " + item)
            return 1
        print("utermctl 自测全部通过")
        return 0
    finally:
        server.close()
        rejecting.close()
        transfers.close()
        shutil.rmtree(root, ignore_errors=True)


def exercise(server, root, rejecting):
    print("请求编码")
    run_cli(server, ["ping"])
    equal(last(server)["action"], "ping", "ping action")
    check("id" in last(server), "每条请求都带 id")

    run_cli(server, ["hosts", "--format", "table"])
    equal(last(server)["action"], "hosts", "hosts action")

    run_cli(server, ["host-key", "-H", "prod-web"])
    equal(last(server)["host"], "prod-web", "host-key 带 host")

    run_cli(server, ["trust", "-H", "prod-web", "--fingerprint", "SHA256:abc"])
    equal(last(server)["fingerprint"], "SHA256:abc", "trust 带 fingerprint")

    run_cli(server, ["run", "-H", "prod-web", "--", "ls", "-la", "/var/log"])
    equal(last(server)["command"], "ls -la /var/log", "run 把 argv 拼成 command")
    equal(last(server)["action"], "run", "run action")

    run_cli(server, ["run", "-H", "prod-web", "--", "echo", "a b"])
    equal(last(server)["command"], "echo 'a b'", "run 用 shlex.join 保护空格")

    # `--` 是命令自己的参数分隔符，不能被客户端滤掉（滤掉就成了另一条命令）。
    run_cli(server, ["run", "-H", "prod-web", "--", "grep", "--", "--include", "f"])
    equal(last(server)["command"], "grep -- --include f", "命令里的 -- 原样保留")
    run_cli(server, ["run", "-H", "prod-web", "--", "git", "log", "--", "path/to/file"])
    equal(last(server)["command"], "git log -- path/to/file", "git log -- <路径> 不被吃掉")

    run_cli(server, ["run", "-H", "prod-web", "-c", "uptime", "--timeout", "30",
                     "--max-lines", "50", "--max-bytes", "9000"])
    equal(last(server)["command"], "uptime", "run -c")
    equal(last(server)["timeoutSeconds"], 30, "timeoutSeconds")
    equal(last(server)["maxLines"], 50, "maxLines")
    equal(last(server)["maxBytes"], 9000, "maxBytes")

    run_cli(server, ["run", "-H", "prod-web", "-c", "make", "--max-duration", "7200"])
    equal(last(server)["maxDurationSeconds"], 7200, "maxDurationSeconds")
    check("timeoutSeconds" not in last(server), "没给 --timeout 就不带，用服务端默认")

    print("配对过的 Mac（macs / mac …）")
    proc = run_cli(server, ["macs", "--format", "table"])
    equal(last(server)["action"], "macs", "macs action")
    check("studio" in proc.stdout and "MAC-1" in proc.stdout, "macs 表格里有名字与 id")

    run_cli(server, ["mac", "ls", "-M", "studio"])
    equal(last(server)["action"], "mac-ls", "mac ls action")
    equal(last(server)["mac"], {"target": "studio"}, "目标 Mac 放在 mac.target")
    equal(last(server)["path"], "~", "mac ls 默认主目录")
    check("host" not in last(server), "mac 命令不带 host")

    proc = run_cli(server, ["mac", "read", "-M", "studio", "~/a.swift", "--lines", "120:180",
                            "--format", "table"])
    equal(last(server)["mac"]["startLine"], 120, "read --lines 的起点")
    equal(last(server)["mac"]["endLine"], 180, "read --lines 的终点")
    check(proc.stdout.startswith("let a = 1"), "read 的 table 输出是文本本身")
    run_cli(server, ["mac", "read", "-M", "studio", "~/a.swift", "--head", "20"])
    equal((last(server)["mac"]["startLine"], last(server)["mac"]["endLine"]), (1, 20), "read --head")
    run_cli(server, ["mac", "read", "-M", "studio", "~/a.swift", "--tail", "5"])
    equal(last(server)["mac"]["tail"], 5, "read --tail")
    run_cli(server, ["mac", "read", "-M", "studio", "~/a.swift", "--head", "5", "--tail", "5"],
            expect_exit=2, label="read 的 --head 与 --tail 只能给一种")

    proc = run_cli(server, ["mac", "grep", "-M", "studio", "func \\w+", "~/app", "-i", "-F",
                            "--include", "*.swift", "--include", "*.m", "-C", "1", "--hidden",
                            "--format", "table"])
    request = last(server)
    equal(request["mac"]["pattern"], "func \\w+", "grep 的模式原样传")
    equal(request["mac"]["include"], ["*.swift", "*.m"], "grep --include 可重复")
    equal(sorted(request["mac"]["options"]), ["fixed", "hidden", "ignoreCase"], "grep 的开关")
    equal(request["mac"]["context"], 1, "grep -C")
    check("Sources/a.swift:4: func alpha() {}" in proc.stdout, "grep 输出 路径:行号: 内容")
    check("Sources/a.swift-3- // 上一行" in proc.stdout, "grep 带上文")

    run_cli(server, ["mac", "find", "-M", "studio", "~/app", "--name", "*.swift", "--type", "f",
                     "--newer", "3600", "--hash"])
    request = last(server)
    equal(request["mac"]["pattern"], "*.swift", "find --name")
    equal(sorted(request["mac"]["options"]), ["files", "hash"], "find 的开关")
    equal(request["mac"]["seconds"], 3600.0, "find --newer")

    run_cli(server, ["mac", "run", "-M", "studio", "--cwd", "~/app", "--timeout", "30", "--",
                     "swift", "build"])
    request = last(server)
    equal(request["command"], "swift build", "mac run 把 argv 拼成 command")
    equal(request["path"], "~/app", "mac run --cwd 走 path")
    equal(request["timeoutSeconds"], 30, "mac run --timeout")

    run_cli(server, ["mac", "write", "-M", "studio", "~/n.md", "--text", "hello", "--if-match", "abc"])
    request = last(server)
    equal(request["text"], "hello", "write --text")
    equal(request["mac"]["ifMatch"], "abc", "write --if-match")
    check("force" not in request, "write 默认不带 force（只肯新建）")
    source = os.path.join(root, "write-source.txt")
    with open(source, "w") as handle:
        handle.write("from file\n")
    run_cli(server, ["mac", "write", "-M", "studio", "~/n.md", "--file", source, "--force"])
    equal(last(server)["text"], "from file\n", "write --file 读本地文件")
    equal(last(server)["force"], True, "write --force")
    before = len(server.requests)
    run_cli(server, ["mac", "write", "-M", "studio", "~/n.md", "--text", "a", "--file", source],
            expect_exit=2, label="write 的 --text 与 --file 只能给一个")
    equal(len(server.requests), before, "参数不对时不发请求")

    run_cli(server, ["mac", "edit", "-M", "studio", "~/a.swift", "--old", "let a = 1",
                     "--new", "let a = 2", "--all"])
    request = last(server)
    equal((request["mac"]["oldText"], request["mac"]["newText"]), ("let a = 1", "let a = 2"), "edit")
    equal(request["mac"]["options"], ["all"], "edit --all")

    run_cli(server, ["mac", "patch", "-M", "studio", "~/app", "--file", source, "--dry-run", "-p", "0"])
    request = last(server)
    equal(request["text"], "from file\n", "patch --file")
    equal(request["mac"]["options"], ["dryRun"], "patch --dry-run")
    equal(request["mac"]["strip"], 0, "patch -p")

    run_cli(server, ["mac", "mkdir", "-M", "studio", "-p", "~/a/b"])
    equal(last(server)["mac"]["options"], ["parents"], "mkdir -p")
    run_cli(server, ["mac", "rm", "-M", "studio", "-r", "~/a"])
    equal(last(server)["mac"]["options"], ["recursive"], "rm -r")
    run_cli(server, ["mac", "mv", "-M", "studio", "~/a", "~/b", "--force"])
    equal((last(server)["path"], last(server)["newPath"], last(server)["force"]),
          ("~/a", "~/b", True), "mv")
    run_cli(server, ["mac", "ln", "-M", "studio", "target.txt", "~/link"])
    equal((last(server)["path"], last(server)["newPath"]), ("~/link", "target.txt"),
          "ln：链接放在 path，指向放在 newPath")
    run_cli(server, ["mac", "xattr", "-M", "studio", "~/a", "set", "com.x", "v"])
    request = last(server)
    equal((request["mac"]["attributeAction"], request["mac"]["attribute"], request["text"]),
          ("set", "com.x", "v"), "xattr set")
    run_cli(server, ["mac", "xattr", "-M", "studio", "~/a", "get"], expect_exit=2,
            label="xattr get 缺属性名")
    run_cli(server, ["mac", "wait-change", "-M", "studio", "~/app/build", "--wait", "120"])
    equal(last(server)["waitSeconds"], 120.0, "wait-change --wait")

    # 反过来访问正在控制这台 Mac 的设备：不写 --mac，带上「我在哪个终端里」。
    run_cli(server, ["mac", "ls", "/Users/me/app"])
    equal(last(server)["mac"], {}, "不写 --mac、也不在 uTerm 的终端里：mac 里什么都不带")
    run_cli(server, ["mac", "ls", "/Users/me/app"], session="SESSION-1")
    equal(last(server)["mac"], {"session": "SESSION-1"}, "终端编号放在 mac.session")
    run_cli(server, ["mac", "ls", "-M", "studio", "/Users/me/a"], session="SESSION-1")
    equal(last(server)["mac"], {"target": "studio", "session": "SESSION-1"}, "点了名也带终端编号")
    run_cli(server, ["macs"], session="SESSION-1")
    equal(last(server)["mac"], {"session": "SESSION-1"}, "macs 带终端编号，好标出当前的设备")
    run_cli(server, ["macs"])
    check("mac" not in last(server), "不在终端里时 macs 不带 mac 字段")
    proc = run_cli(server, ["mac", "shares", "--format", "table"], session="SESSION-1")
    equal(last(server)["action"], "mac-shares", "mac shares action")
    check("/Users/me/app" in proc.stdout and "只读" in proc.stdout and "读写" in proc.stdout,
          "shares 的表格列出目录与读写权限")

    server.override = {"ok": False, "code": "permission_denied",
                       "message": "那台 Mac 上没有打开「允许打开本机终端」"}
    proc = run_cli(server, ["mac", "ls", "-M", "studio"], expect_exit=1,
                   label="那台 Mac 关着开关 → permission_denied")
    equal(json.loads(proc.stdout)["code"], "permission_denied", "失败响应原样是 JSON")

    print("心跳与静默超时")
    # 心跳的每一个 `\n` 都会重置客户端的 socket 超时：累计时长超过 idle 预算也不该断。
    server.heartbeats = 12
    proc = run_cli(server, ["ping"], idle_timeout=0.3, label="12 次心跳（共 0.6 s）后回响应")
    equal(json.loads(proc.stdout)["ok"], True, "带前导心跳的响应照常解析")
    # 一个字节都不写，超过 idle 预算 → client_timeout，退出码归「超时」一档。
    server.stall = 1.0
    proc = run_cli(server, ["ping"], expect_exit=6, idle_timeout=0.3, label="uTerm 静默")
    equal(json.loads(proc.stdout)["code"], "client_timeout", "静默超时的错误码")
    time.sleep(1.0)  # 等假服务端把那条迟到的响应写完，别串到下一条用例

    run_cli(server, ["run-many", "-H", "a", "-H", "b", "--", "uptime"])
    equal(last(server)["hosts"], ["a", "b"], "run-many 用 hosts 数组")
    check("host" not in last(server), "run-many 不带单数 host")

    run_cli(server, ["quick-commands"])
    run_cli(server, ["quick-run", "磁盘水位", "-H", "prod-web"])
    equal(last(server)["name"], "磁盘水位", "quick-run 带 name")
    equal(last(server)["hosts"], ["prod-web"], "quick-run 覆盖目标")

    print("终端窗口里跑命令")
    run_cli(server, ["terminal", "open", "-H", "mac-01"])
    equal(last(server)["action"], "terminal-open", "terminal open action")
    check("command" not in last(server), "terminal open 不给命令 = 只开窗口")
    run_cli(server, ["terminal", "open", "-H", "mac-01", "--", "sudo", "./bootstrap.zsh", "--only-root-entry"])
    equal(last(server)["command"], "sudo ./bootstrap.zsh --only-root-entry", "terminal open 带 -- 之后的命令")
    run_cli(server, ["terminal", "open", "-H", "mac-01", "-c", "cd ~/x && sudo make install"])
    equal(last(server)["command"], "cd ~/x && sudo make install", "terminal open -c")
    run_cli(server, ["terminal", "wait", "-t", "7A2B", "--wait", "0"])
    equal(last(server)["action"], "terminal-wait", "terminal wait action")
    equal(last(server)["terminal"], "7A2B", "terminal wait 带会话 id")
    equal(last(server)["waitSeconds"], 0.0, "--wait 0 照样发出去")
    proc = run_cli(server, ["terminal", "wait", "-t", "7A2B", "--format", "table"])
    check("root" in proc.stdout and "exit=0" in proc.stdout, "terminal wait 的人类可读输出：输出 + 状态行")

    print("SFTP")
    run_cli(server, ["sftp", "ls", "-H", "prod-web", "/var/log", "--format", "table"])
    equal(last(server)["action"], "sftp-ls", "sftp ls → sftp-ls")
    equal(last(server)["path"], "/var/log", "sftp ls 带 path")

    run_cli(server, ["sftp", "stat", "-H", "prod-web", "/var/log/app.log"])
    equal(last(server)["action"], "sftp-stat", "sftp-stat")

    proc = run_cli(server, ["sftp", "cat", "-H", "prod-web", "/etc/hostname",
                            "--format", "table"])
    equal(last(server)["action"], "sftp-cat", "sftp-cat")
    check("prod-web" in proc.stdout, "cat 直接打印文本")

    # get / put 的传输语义（交 fd、进度、续传、校验）在 exercise_transfers 里对着会读写
    # fd 的假服务端测；这里只看动作名映射与本地前置检查。
    target = os.path.join(root, "hostname.txt")
    run_cli(server, ["sftp", "get", "-H", "prod-web", "/etc/hostname", target])
    equal(last(server)["action"], "sftp-get", "sftp-get")
    run_cli(server, ["sftp", "get", "-H", "prod-web", "/etc/hostname", target],
            expect_exit=2, label="get 已存在不覆盖")

    source = os.path.join(root, "upload.txt")
    open(source, "wb").write(b"hello")
    run_cli(server, ["sftp", "put", "-H", "prod-web", source, "/tmp/hello"])
    equal(last(server)["action"], "sftp-put", "sftp-put")
    equal(last(server)["path"], "/tmp/hello", "put 的 path 是远端路径")
    check("contentBase64" not in last(server), "put 不再把文件内容塞进请求")

    run_cli(server, ["sftp", "mkdir", "-H", "prod-web", "/tmp/d"])
    equal(last(server)["action"], "sftp-mkdir", "sftp-mkdir")
    run_cli(server, ["sftp", "rm", "-H", "prod-web", "/tmp/f"])
    equal(last(server)["action"], "sftp-rm", "sftp-rm")
    run_cli(server, ["sftp", "rmdir", "-H", "prod-web", "/tmp/d"])
    equal(last(server)["action"], "sftp-rmdir", "sftp-rmdir")
    run_cli(server, ["sftp", "mv", "-H", "prod-web", "/tmp/a", "/tmp/b"])
    equal(last(server)["action"], "sftp-mv", "sftp-mv")
    equal(last(server)["newPath"], "/tmp/b", "sftp-mv 用 newPath")
    run_cli(server, ["sftp", "chmod", "-H", "prod-web", "/tmp/a", "644"])
    equal(last(server)["mode"], "644", "sftp-chmod 用 mode 字符串")

    print("转发与终端")
    run_cli(server, ["forward", "list", "--format", "table"])
    equal(last(server)["action"], "forward-list", "forward-list")
    run_cli(server, ["forward", "start", "-r", "pg"])
    equal(last(server)["rule"], "pg", "forward-start 用 rule")
    run_cli(server, ["forward", "stop", "-r", "pg"])
    equal(last(server)["action"], "forward-stop", "forward-stop")
    run_cli(server, ["forward", "stop", "-r", "pg", "-H", "prod-web"])
    equal(last(server)["host"], "prod-web", "forward-stop 可按主机收窄")
    run_cli(server, ["forward", "add", "-H", "prod-web", "-n", "k3s", "--kind", "remote",
                     "--listen", "192.168.31.122:18443", "--dest", "127.0.0.1:18443"])
    equal(last(server)["action"], "forward-add", "forward-add")
    equal(last(server)["name"], "k3s", "forward-add 用 name")
    equal(last(server)["forward"], {"kind": "remote", "listenHost": "192.168.31.122",
                                    "listenPort": 18443, "destHost": "127.0.0.1",
                                    "destPort": 18443}, "forward-add 的规则内容")
    run_cli(server, ["forward", "add", "-H", "prod-web", "-n", "pg", "--kind", "local",
                     "--listen", "15432", "--dest", "[fd00::9]:5432"])
    equal(last(server)["forward"], {"kind": "local", "listenPort": 15432,
                                    "destHost": "fd00::9", "destPort": 5432},
          "监听只给端口、目标 IPv6 加方括号")
    run_cli(server, ["forward", "add", "-H", "prod-web", "-n", "s", "--kind", "dynamic",
                     "--listen", "1080"])
    equal(last(server)["forward"], {"kind": "dynamic", "listenPort": 1080}, "dynamic 无目标")
    before = len(server.requests)
    for bad in (["--kind", "local", "--listen", "15432"],
                ["--kind", "dynamic", "--listen", "1080", "--dest", "a:1"],
                ["--kind", "local", "--listen", "99999", "--dest", "a:1"],
                ["--kind", "local", "--listen", "1", "--dest", "5432"],
                ["--kind", "local", "--listen", "::1:80", "--dest", "a:1"]):
        run_cli(server, ["forward", "add", "-H", "prod-web", "-n", "x"] + bad, expect_exit=2)
    equal(len(server.requests), before, "参数不对的 add 不发请求")
    run_cli(server, ["forward", "remove", "-r", "k3s"])
    equal(last(server)["action"], "forward-remove", "forward-remove")

    run_cli(server, ["terminals", "--format", "table"])
    equal(last(server)["action"], "terminals", "terminals")
    proc = run_cli(server, ["terminal", "read", "-t", "7A2B", "--lines", "40",
                            "--format", "table"])
    equal(last(server)["action"], "terminal-read", "terminal-read")
    equal(last(server)["lines"], 40, "terminal-read 用 lines")
    check("up 12 days" in proc.stdout, "读屏按行打印")
    run_cli(server, ["terminal", "send", "-t", "7A2B", "uptime", "--enter"])
    equal(last(server)["text"], "uptime", "terminal-send 用 text")
    equal(last(server)["enter"], True, "terminal-send --enter")
    run_cli(server, ["terminal", "open", "-H", "prod-web"])
    equal(last(server)["action"], "terminal-open", "terminal-open")
    run_cli(server, ["disconnect", "-H", "prod-web"])
    equal(last(server)["action"], "disconnect", "disconnect")
    run_cli(server, ["relay", "import", "-H", "prod-web"])
    equal(last(server)["action"], "relay-import", "relay import")
    equal(last(server)["host"], "prod-web", "relay import 带 host")
    check("force" not in last(server) and "path" not in last(server), "relay import 缺省不带 force / path")
    run_cli(server, ["relay", "import", "-H", "prod-web", "--path", "/root/c.json", "--replace"])
    equal(last(server)["force"], True, "relay import --replace → force")
    equal(last(server)["path"], "/root/c.json", "relay import --path")
    run_cli(server, ["relay", "check"])
    equal(last(server)["action"], "relay-check", "relay check")

    print("格式化")
    proc = run_cli(server, ["hosts", "--format", "table"])
    check("prod-web" in proc.stdout and "activeForwards" in proc.stdout, "hosts 表有表头与行")
    proc = run_cli(server, ["--format", "csv", "hosts"])
    check(proc.stdout.splitlines()[0].startswith("name,host,port"), "--format 可写在子命令前")
    proc = run_cli(server, ["hosts"])
    check(json.loads(proc.stdout)["hosts"][0]["id"] == HOST["id"], "默认 json 原样输出")
    proc = run_cli(server, ["run-many", "-H", "a", "-H", "b", "--format", "table",
                            "--", "uptime"])
    check("── prod-web" in proc.stdout and "up 12 days" in proc.stdout,
          "run-many 逐主机分段打印")
    proc = run_cli(server, ["sftp", "ls", "-H", "h", "/var/log", "--format", "table"])
    check("app.log" in proc.stdout and "100644" not in proc.stdout, "entries 表把权限转八进制")
    check("0644" in proc.stdout, "entries 表的 mode 列")
    proc = run_cli(server, ["quick-commands", "--format", "table"])
    check("磁盘水位" in proc.stdout, "quickCommands 表")
    proc = run_cli(server, ["forward", "list", "--format", "table"])
    check("15432" in proc.stdout, "rules 表")
    proc = run_cli(server, ["relay", "check", "--format", "table"])
    check("UDP 不通" in proc.stdout and "check.rttMs" in proc.stdout and "42" in proc.stdout,
          "relay check 表：摘要 + 字段")
    proc = run_cli(server, ["terminals", "--format", "table"])
    check("workspace" in proc.stdout, "terminals 表")
    # stat 表：类型单列，mode 与 ls 一样是 & 0o7777 的八进制（33188 → 0644）。
    proc = run_cli(server, ["sftp", "stat", "-H", "h", "/var/log/app.log",
                            "--format", "table"])
    check("kind" in proc.stdout and "file" in proc.stdout, "stat 表有 kind 列")
    check("0644" in proc.stdout and "33188" not in proc.stdout, "stat 表的 mode 列转八进制")
    # 布尔 false 画成「否」，不能是空白 —— 空白与「字段缺失」的 "-" 分不开。
    proc = run_cli(server, ["hosts", "--format", "table"])
    header, _, row = proc.stdout.splitlines()[:3]
    columns = header.split()
    check("sftpOnly" in columns, "hosts 表有 sftpOnly 列")
    equal(row.split()[columns.index("sftpOnly")], "否", "false 渲染成「否」")
    equal(row.split()[columns.index("cliConnected")], "是", "true 渲染成「是」")

    print("退出码")
    cases = [
        ("control_disabled", 3), ("mutations_disabled", 3), ("host_sftp_only", 3),
        ("host_not_found", 4), ("host_ambiguous", 4), ("rule_not_found", 4),
        ("terminal_ambiguous", 4), ("file_not_found", 4),
        ("connect_failed", 5), ("auth_failed", 5), ("host_key_unknown", 5),
        ("host_key_changed", 5), ("forward_failed", 5),
        ("command_timeout", 6), ("handler_timeout", 6), ("client_timeout", 6),
        ("operation_failed", 1), ("not_implemented", 1), ("invalid_request", 1),
    ]
    for code, expected in cases:
        server.override = {"ok": False, "code": code, "message": code}
        run_cli(server, ["ping"], expect_exit=expected, label="code " + code)

    print("run-many 的成败语义")
    partial = {"ok": False, "code": "run_partial_failure",
               "message": "2 台中 1 台失败",
               "results": [RESULT, dict(RESULT, host="prod-db", exitCode=None,
                                        errorCode="connect_failed",
                                        errorMessage="连不上")]}
    server.override = dict(partial)
    proc = run_cli(server, ["run-many", "-H", "a", "-H", "b", "--format", "table",
                            "--", "uptime"], expect_exit=7, label="run_partial_failure → 7")
    check("── prod-db" in proc.stdout and "connect_failed" in proc.stdout,
          "部分失败仍逐主机渲染 results")
    check("up 12 days" in proc.stdout, "部分失败里成功那台的输出也要打出来")

    server.override = dict(partial)
    proc = run_cli(server, ["run-many", "-H", "a", "-H", "b", "--", "uptime"],
                   expect_exit=7, label="run_partial_failure json")
    check(json.loads(proc.stdout)["code"] == "run_partial_failure",
          "json 格式失败响应原样输出")

    server.override = {"ok": False, "code": "run_failed", "message": "2 台全部失败",
                       "hostKey": {"host": "prod-web", "fingerprint": "SHA256:zzz",
                                   "status": "unknown"},
                       "results": [dict(RESULT, exitCode=None,
                                        errorCode="host_key_unknown",
                                        errorMessage="密钥未信任")]}
    proc = run_cli(server, ["run-many", "-H", "a", "-H", "b", "--", "uptime"],
                   expect_exit=5, label="run_failed → 5")
    check(json.loads(proc.stdout)["hostKey"]["fingerprint"] == "SHA256:zzz",
          "全失败时顶层 hostKey 可读")

    print("服务端中途拒收")
    big = os.path.join(root, "toobig.bin")
    with open(big, "wb") as handle:
        handle.write(b"\0" * (4 * 1024 * 1024))
    proc = run_cli(server, ["sftp", "put", "-H", "prod-web", big, "/tmp/big"],
                   expect_exit=1, socket_path=rejecting.path,
                   label="请求体被中途拒收")
    check(json.loads(proc.stdout)["code"] == "request_too_large",
          "写请求时 EPIPE 要先读服务端已写回的响应，而不是报 socket_error")

    server.override = {"ok": False, "code": "host_key_unknown", "message": "未知主机密钥",
                       "hostKey": {"host": "h", "fingerprint": "SHA256:zzz",
                                   "status": "unknown"}}
    proc = run_cli(server, ["run", "-H", "h", "--", "uptime"], expect_exit=5)
    check(json.loads(proc.stdout)["hostKey"]["fingerprint"] == "SHA256:zzz",
          "失败响应原样打 JSON（fingerprint 可读）")

    missing = os.path.join(root, "nope.sock")
    proc = run_cli(server, ["ping"], expect_exit=2, socket_path=missing,
                   label="socket 不存在")
    check(json.loads(proc.stdout)["code"] == "uterm_not_running", "本地判定 uterm_not_running")

    # 真的「残留 socket」：bind 过、进程没了、文件还在 —— connect 得到 ECONNREFUSED。
    stale = os.path.join(root, "stale.sock")
    dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    dead.bind(stale)
    dead.close()
    proc = run_cli(server, ["ping"], expect_exit=2, socket_path=stale,
                   label="socket 残留")
    check(json.loads(proc.stdout)["code"] == "uterm_socket_stale", "本地判定 uterm_socket_stale")



def make_local(root, name, size):
    path = os.path.join(root, name)
    with open(path, "wb") as handle:
        handle.write(os.urandom(size))
    return path


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def transfer_of(proc):
    return json.loads(proc.stdout)["transfer"]


# 与客户端里的常量一一对应（续传状态 sidecar / get 的半成品）。
SIDECAR_SUFFIX = ".utermctl-transfer.json"
PART_SUFFIX = ".part"


def sidecar_of(local):
    return local + SIDECAR_SUFFIX


def part_of(local):
    return local + PART_SUFFIX


def wipe(*locals_):
    """清掉一次失败传输留下的状态，好让下一段从干净的地方开始。"""
    for local in locals_:
        for path in (local, sidecar_of(local), sidecar_of(local) + ".tmp", part_of(local)):
            if os.path.exists(path):
                os.unlink(path)


def load_json(path):
    with open(path, "r") as handle:
        return json.load(handle)


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, "r") as handle:
        return [line.strip() for line in handle if line.strip()]


def exercise_transfers(server, root):
    one_mib = 1024 * 1024
    print("传输：put 交 fd，不带文件内容")
    small = make_local(root, "t-small.bin", one_mib + 123)
    payload = read_bytes(small)
    server.reset()
    proc = run_cli(server, ["sftp", "put", "-H", "h", small, "/r/small"])
    put = server.transfers("sftp-put")[0]
    equal(server.fds_seen, [1], "随请求交了 1 个 fd")
    check("contentBase64" not in put and "offset" not in put, "请求体里没有文件内容与分片字段")
    equal(put.get("parallel"), 8, "默认并行 8")
    check("ranges" not in put, "整份上传不带 ranges")
    check(bytes(server.files["/r/small"]) == payload, "服务端经 fd 读到的内容逐字节相同")
    stats = transfer_of(proc)
    equal(stats["bytes"], len(payload), "transfer.bytes = 文件大小")
    equal(stats["parallel"], 8, "transfer.parallel")
    equal(stats["verified"], False, "小于 8 MiB 默认不校验")
    equal(server.runs, [], "小文件不发 run")
    check(not os.path.exists(sidecar_of(small)), "成功后续传状态文件删掉了")

    run_cli(server, ["sftp", "put", "-H", "h", small, "/r/small"], expect_exit=1,
            label="远端已存在 → file_exists")
    run_cli(server, ["sftp", "put", "-H", "h", small, "/r/small", "--force", "--parallel", "3"],
            label="--force 覆盖")
    last_put = server.transfers("sftp-put")[-1]
    equal(last_put.get("force"), True, "--force 透传")
    equal(last_put.get("parallel"), 3, "--parallel 透传")

    print("传输：大文件 put 校验 sha256")
    big = make_local(root, "t-big.bin", 9 * one_mib)
    server.reset()
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--quiet"])
    check(bytes(server.files["/r/big"]) == read_bytes(big), "大文件逐字节相同")
    equal(transfer_of(proc)["verified"], True, "≥ 8 MiB 默认校验且一致")
    equal(len(server.runs), 1, "校验发了一条 run")
    check("上传完成" in proc.stderr, "非 tty 时结束仍打一行汇总到 stderr")

    print("传输：get")
    server.reset()
    server.files["/r/g"] = bytearray(os.urandom(3 * one_mib + 7))
    target = os.path.join(root, "g.bin")
    wipe(target)
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target])
    equal(server.fds_seen, [1], "get 也交 fd")
    check(read_bytes(target) == bytes(server.files["/r/g"]), "下载内容逐字节相同")
    check(not os.path.exists(part_of(target)), "成功后 .part 改名成目标")
    check(not os.path.exists(sidecar_of(target)), "成功后续传状态文件删掉了")
    equal(transfer_of(proc)["bytes"], 3 * one_mib + 7, "transfer.bytes")
    run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target], expect_exit=2,
            label="本地已存在且没给 --force → 本地拒绝")

    print("传输：中途断了自动续上，只补缺的区间")
    server.reset()
    server.files["/r/g"] = bytearray(os.urandom(2 * one_mib))
    server.fail_after = one_mib
    wipe(target)
    trace = os.path.join(root, "sleep-trace")
    if os.path.exists(trace):
        os.unlink(trace)
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target], sleep_trace=trace,
                   label="get 中途失败后自动续传")
    gets = server.transfers("sftp-get")
    equal(len(gets), 2, "一次失败 + 一次续传")
    check("ranges" not in gets[0], "第一次整份")
    equal(gets[1].get("ranges"), [{"offset": one_mib, "length": one_mib}],
          "续传只请求缺的那一半")
    check(read_bytes(target) == bytes(server.files["/r/g"]), "续传拼回来的内容逐字节相同")
    equal(read_lines(trace), ["0.500"], "一次普通重试退避 0.5 秒")

    server.reset()
    server.files["/r/up"] = bytearray()
    del server.files["/r/up"]
    server.fail_after = one_mib
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/up", "--quiet"], sleep_trace=trace,
            label="put 中途失败后自动续传")
    puts = server.transfers("sftp-put")
    equal(len(puts), 2, "put 也是一次失败 + 一次续传")
    check("ranges" in puts[1] and "force" not in puts[1],
          "续传只补区间、不再带覆盖语义")
    check(bytes(server.files["/r/up"]) == read_bytes(big), "put 续传后内容逐字节相同")

    print("传输：一直失败 → 留下续传状态，--resume 接着传")
    server.reset()
    server.files["/r/g"] = bytearray(os.urandom(2 * one_mib))
    server.fail_after = one_mib // 2
    server.fail_always = "connect_failed"
    wipe(target)
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target], expect_exit=5,
                   sleep_trace=trace, label="get 一直失败")
    stats = transfer_of(proc)
    equal(stats["incomplete"], True, "失败时标记 incomplete")
    equal(stats["resumable"], True, "失败时可以 --resume")
    check(os.path.exists(part_of(target)) and not os.path.exists(target),
          "半成品在 .part，目标名没生成")
    saved = load_json(sidecar_of(target))
    equal(saved["version"], 2, "sidecar v2")
    # 首次 + 2 次自动续传，每次都在失败前多搬 512 KiB：记账是累计的。
    equal(saved["done"], [[0, 3 * one_mib // 2]], "续传状态记下了每次尝试累计完成的区间")
    server.fail_always = None
    server.fail_after = None
    del server.requests[:]
    run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target, "--resume"], label="--resume")
    equal(server.transfers("sftp-get")[0].get("ranges"),
          [{"offset": 3 * one_mib // 2, "length": one_mib // 2}],
          "--resume 只请求没完成的区间")
    check(read_bytes(target) == bytes(server.files["/r/g"]), "续传后内容逐字节相同")
    check(not os.path.exists(sidecar_of(target)), "续传成功后状态文件删掉了")

    print("传输：续传前核对身份")
    server.reset()
    server.files["/r/g"] = bytearray(os.urandom(one_mib))
    server.fail_after = 1
    server.fail_always = "connect_failed"
    wipe(target)
    run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target], expect_exit=5,
            sleep_trace=trace, label="先失败一次留下状态")
    server.fail_always = None
    server.files["/r/g"] = bytearray(os.urandom(one_mib + 1))
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target, "--resume"],
                   expect_exit=2, label="远端变了 → 拒绝续传")
    check("已经变了" in proc.stderr, "说清楚远端变了")
    wipe(target)
    run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target, "--resume"], expect_exit=2,
            label="没有续传状态 → 拒绝 --resume")

    print("传输：服务端忙 → 退避重试")
    server.reset()
    server.files["/r/g"] = bytearray(os.urandom(one_mib))
    server.busy_once = True
    if os.path.exists(trace):
        os.unlink(trace)
    wipe(target)
    run_cli(server, ["sftp", "get", "-H", "h", "/r/g", target], sleep_trace=trace,
            label="server_busy 后重试成功")
    equal(read_lines(trace), ["0.500"], "server_busy 退避 0.5 秒后重试")
    check("ranges" not in server.transfers("sftp-get")[1],
          "还没完成任何区间时，重试仍整份请求（覆盖语义不丢）")

    print("传输：校验")
    server.reset()
    server.files["/r/big"] = bytearray(os.urandom(9 * one_mib))
    server.sha_override = "0" * 64
    wipe(target)
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/big", target, "--quiet"],
                   expect_exit=1, label="sha256 不一致")
    equal(json.loads(proc.stdout)["code"], "checksum_mismatch", "code: checksum_mismatch")
    check(os.path.exists(part_of(target)) and not os.path.exists(target),
          "校验失败不占用目标名")
    server.sha_override = "missing"
    wipe(target)
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/big", target, "--quiet"],
                   label="远端没有哈希工具")
    check("跳过校验" in (transfer_of(proc)["verifyNote"] or ""), "没工具只是跳过校验")
    wipe(target)
    server.sha_override = None
    del server.runs[:]
    run_cli(server, ["sftp", "get", "-H", "h", "/r/big", target, "--no-verify", "--quiet"],
            label="--no-verify")
    equal(server.runs, [], "--no-verify 不发 run")

    print("传输：参数校验与输出")
    for bad in (["--parallel", "0"], ["--parallel", "17"], ["--force", "--resume"]):
        run_cli(server, ["sftp", "put", "-H", "h", small, "/r/x"] + bad, expect_exit=2,
                label="put " + " ".join(bad))
    wipe(target)
    server.files["/r/t"] = bytearray(b"abc")
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/t", target, "--format", "table"])
    check("parallel" in proc.stdout and "chunks" not in proc.stdout,
          "table 是字段表，没有旧的 chunks 列")
    wipe(target)


def load_client_module():
    """把 scripts/utermctl（无扩展名）当模块载入，好单测按需启动的决策逻辑。"""
    import importlib.machinery
    import importlib.util
    sys.dont_write_bytecode = True   # 别在 scripts/ 下留 __pycache__
    loader = importlib.machinery.SourceFileLoader("utermctl_under_test", CLIENT)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class FakeLauncher(object):
    """替身 `open -W`：exit_code 为 None 表示一直在等（uTerm 在跑），否则立刻以它退出。"""

    def __init__(self, exit_code, stderr=""):
        self.exit_code = exit_code
        self.terminated = False
        self.stderr = __import__("io").StringIO(stderr)

    def poll(self):
        if self.exit_code is not None:
            return self.exit_code
        return -15 if self.terminated else None

    def terminate(self):
        self.terminated = True

    def wait(self, timeout=None):
        return self.poll()

    def kill(self):
        self.terminated = True


def exercise_on_demand_launch(root):
    print("")
    print("按需启动（读不到 uTerm 设置时交给 app 自己把关）")
    client = load_client_module()
    prefs = os.path.join(root, "prefs")
    os.makedirs(prefs)

    def write_plist(name, values):
        import plistlib
        path = os.path.join(prefs, name)
        with open(path, "wb") as stream:
            plistlib.dump(values, stream)
        return path

    readable_on = write_plist("on.plist", {client.ON_DEMAND_KEY: True, client.CONTROL_ENABLED_KEY: True})
    readable_off = write_plist("off.plist", {client.ON_DEMAND_KEY: False, client.CONTROL_ENABLED_KEY: True})
    missing_key = write_plist("empty.plist", {})
    unreadable = write_plist("denied.plist", {client.ON_DEMAND_KEY: True})
    os.chmod(unreadable, 0)
    denied_really = False
    try:
        open(unreadable, "rb").close()
    except PermissionError:
        denied_really = True

    client.PREFERENCE_CANDIDATES = [readable_on]
    equal(client.preference_value(client.ON_DEMAND_KEY), True, "读得到且为开 → True")
    client.PREFERENCE_CANDIDATES = [missing_key]
    equal(client.preference_value(client.ON_DEMAND_KEY), False, "读得到但没设过 → False（默认关）")
    client.PREFERENCE_CANDIDATES = [os.path.join(prefs, "nope.plist")]
    equal(client.preference_value(client.ON_DEMAND_KEY), False, "文件不存在 → False")
    if denied_really:
        client.PREFERENCE_CANDIDATES = [unreadable, os.path.join(prefs, "nope.plist")]
        equal(client.preference_value(client.ON_DEMAND_KEY), None, "读被拒（EPERM/EACCES）→ None，不当成关")
    else:
        print("  skip 以 root 运行，chmod 000 挡不住读")

    launched = []

    def fake_popen(result):
        def popen(argv, **kwargs):
            launched.append(argv)
            return result
        return popen

    client.time.sleep = lambda seconds: None
    ready_socket = os.path.join(prefs, "ready.sock")
    client.socket_paths = lambda: [ready_socket]
    client.exchange = lambda path, request, *rest: {"ok": True}

    # 1. 读得到且关着：本地直接拦下，不起进程。
    client.PREFERENCE_CANDIDATES = [readable_off]
    client.subprocess.Popen = fake_popen(FakeLauncher(0))
    started, message = client.start_background_and_wait()
    check(not started and "没有允许 CLI 按需启动" in (message or ""), "设置读得到且关着 → 本地拒绝")
    equal(len(launched), 0, "本地拒绝时不唤起 uTerm")

    # 残留 socket + 按需启动关着：错误码不变，但消息要带上「为什么没自己起」，
    # 否则 Agent 只看到「等它起来」，不知道有个开关能让客户端自己起。
    def refuse(path, request, *rest):
        raise ConnectionRefusedError()
    dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    dead.bind(ready_socket)
    dead.close()
    client.exchange = refuse
    response = client.send_request({"id": "stale", "action": "ping"})
    equal(response["code"], client.CODE_SOCKET_STALE, "残留 socket + 按需启动关着 → 仍是 uterm_socket_stale")
    check("允许 CLI 按需启动" in response["message"], "残留 socket 的消息带上按需启动没成功的原因")
    os.unlink(ready_socket)
    client.exchange = lambda path, request, *rest: {"ok": True}

    if denied_really:
        client.PREFERENCE_CANDIDATES = [unreadable]
        # 2. 读不到 → 照样请求启动，带上 --launch-source cli；uTerm 按设置拒绝后立刻退出。
        client.subprocess.Popen = fake_popen(FakeLauncher(0))
        started, message = client.start_background_and_wait()
        check(not started and "拒绝了按需启动" in (message or ""), "读不到设置 + uTerm 退出 → 报「拒绝了按需启动」")
        check(launched and launched[-1][:2] == ["/usr/bin/open", "-gjW"], "用 open -W 等 uTerm 退出")
        check(launched and launched[-1][-3:] == ["--background", "--launch-source", "cli"],
              "唤起参数带 --launch-source cli（app 靠它把关）")

        # 3. 读不到 → uTerm 起来了、接口就绪：成功，并结束等待中的 open。
        waiting = FakeLauncher(None)
        client.subprocess.Popen = fake_popen(waiting)
        open(ready_socket, "w").close()
        started, message = client.start_background_and_wait()
        check(started and message is None, "读不到设置 + 接口就绪 → 成功")
        check(waiting.terminated, "就绪后结束掉等待中的 open -W")
        os.remove(ready_socket)

        # 4. open 本身失败（找不到 app）：报唤起失败，而不是「拒绝」。
        client.subprocess.Popen = fake_popen(FakeLauncher(1, "Unable to find application"))
        started, message = client.start_background_and_wait()
        check(not started and "无法唤起" in (message or "") and "Unable to find" in (message or ""),
              "open 失败 → 报无法唤起并带上原因")

    os.chmod(unreadable, 0o600)


def exercise_socket_path_too_long():
    """用户名超过 10 个字符：默认 socket 路径放不进 sun_path（2026-11-16 的反馈）。"""
    print("")
    print("socket 路径超过 sun_path 上限")
    client = load_client_module()
    os.environ.pop(client.ENV_SOCKET, None)

    def candidates(user):
        return [p.replace("~", "/Users/" + user, 1) for p in client.SOCKET_CANDIDATES]

    request = {"id": "long", "action": "ping"}
    not_ready = client.LAUNCH_NOT_READY_MESSAGE

    equal(len(candidates("exampleuser")[0].encode()), 104, "exampleuser 的默认路径正好 104 字节")
    check(client.socket_path_too_long_response(request, candidates("abcdefghij"), not_ready) is None,
          "用户名 10 个字符：默认路径放得下，不是这个原因")

    response = client.socket_path_too_long_response(request, candidates("exampleuser"), not_ready)
    equal((response or {}).get("code"), client.CODE_SOCKET_PATH_TOO_LONG, "11 个字符 + 接口没就绪 → socket_path_too_long")
    check("更新" in (response or {}).get("message", ""), "消息让用户更新 uTerm")
    check("UTERM_CONTROL_SOCKET" not in (response or {}).get("message", ""), "消息不再给 UTERM_CONTROL_SOCKET 的办法")
    equal(client.exit_code_for(response or {}), client.EXIT_LOCAL, "socket_path_too_long 归本地这一档")

    refused = "uTerm 拒绝了按需启动：需要在 uTerm 设置 ▸ 命令行与技能 里同时打开……"
    check(client.socket_path_too_long_response(request, candidates("exampleuser"), refused) is None,
          "被开关拒绝时照旧报开关的原因")

    huge = "u" * 41
    response = client.socket_path_too_long_response(request, candidates(huge), refused)
    equal((response or {}).get("code"), client.CODE_SOCKET_PATH_TOO_LONG, "41 个字符：短路径也放不下，不管开关")
    check(client.socket_path_too_long_response(request, candidates("u" * 40), refused) is None,
          "40 个字符：短路径放得下，被拒绝时报开关")

    os.environ[client.ENV_SOCKET] = "/tmp/x.sock"
    try:
        check(client.socket_path_too_long_response(request, candidates("exampleuser"), not_ready) is None,
              "显式指定 UTERM_CONTROL_SOCKET 时不判")
    finally:
        os.environ.pop(client.ENV_SOCKET, None)


if __name__ == "__main__":
    sys.exit(main())
