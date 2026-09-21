#!/usr/bin/env python3
"""scripts/utermctl 的离线自测：起一个假的 Unix socket 服务端，把每个子命令都跑一遍。

校验三件事：请求编码（字段名 / action rawValue 与 ControlProtocol.swift 一致）、
输出格式化、错误码 → 退出码映射。不需要 uTerm 在跑，也不碰任何真实主机。

    python3 scripts/utermctl-selftest.py        # 也是 `make check-cli`
"""
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
    "sftp-mkdir": {}, "sftp-rm": {}, "sftp-rmdir": {}, "sftp-mv": {}, "sftp-chmod": {},
    "forward-list": {"rules": [{"id": "r-1", "serverID": HOST["id"],
                                "serverName": "prod-web", "name": "pg", "kind": "local",
                                "listenHost": "127.0.0.1", "listenPort": 15432,
                                "destHost": "10.0.0.9", "destPort": 5432,
                                "autostart": True, "status": "active",
                                "bytesIn": 100, "bytesOut": 200}]},
    "forward-start": {}, "forward-stop": {},
    "terminals": {"terminals": [{"id": "7A2B", "serverID": HOST["id"],
                                 "serverName": "prod-web", "windowKind": "workspace",
                                 "title": "~ — deploy@prod-web",
                                 "isKeyWindowFocused": True,
                                 "connectedAt": "2026-09-09T01:30:00Z"}]},
    "terminal-read": {"screen": {"terminal": "7A2B", "lines": ["$ uptime", "up 12 days"],
                                 "truncated": False}},
    "terminal-send": {}, "terminal-open": {"terminals": []},
    "disconnect": {},
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
    """分片传输用的假服务端。与 `FakeServer` 的两点不同：

    1. **每条连接一个线程** —— 串行 accept 的话「并行度」根本量不出来（恒为 1）。
    2. 维护一份内存文件表，按 `offset` / `mode` 真的拼装内容，于是「分片覆盖完整、
       不重叠、拼回去逐字节相同」是能断言的，而不是只看请求字段。

    每次处理故意 sleep 一小会儿，好让并发窗口张开；峰值并发记在 `max_active`。
    """

    def __init__(self, path, delay=0.03):
        self.path = path
        self.delay = delay
        self.files = {}          # 远端路径 → bytearray
        self.requests = []       # 收到的原始请求（断言字段在不在）
        self.puts = []           # [(path, offset, mode, bytes)]
        self.gets = []           # [(path, offset, bytes)]
        self.runs = []           # 收到的 run 命令
        self.attempts = {}       # sftp-put 的 offset → 到达次数（看重试）
        self.fail_once = set()   # 这些 offset 的第一次 put 注入失败
        self.fail_offsets = set()  # 这些 offset 的 put 一律失败（测「取消其余分片」）
        self.fail_always = None  # 非 None 时所有 put 都回这个 code
        # 响应丢失的注入：`drop_once` 的 offset **先写进去再把连接关掉不回响应**
        # （= 服务端做成了但客户端不知道），`drop_always` 是收下就关、什么也不做
        # （= 服务端槽位满时的表现，客户端看到 `empty_response`）。
        self.drop_once = set()
        self.drop_always = False
        self.get_attempts = {}     # sftp-get 的 offset → 到达次数
        self.get_fail_offsets = set()   # 这些 offset 的 get 一律失败
        self.get_empty_once = set()     # 这些 offset 的第一次 get 回空载荷
        self.get_empty_always = set()   # 这些 offset 的 get 一律回空载荷
        self.get_half_once = set()      # 这些 offset 的第一次 get 只给一半
        self.lock = threading.Lock()
        self.active = 0
        self.max_active = 0
        self.sha_override = None  # None=真算；"missing"=远端没工具；其余=假的十六进制
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(32)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def reset(self):
        with self.lock:
            self.files.clear()
            del self.requests[:]
            del self.puts[:]
            del self.gets[:]
            del self.runs[:]
            self.attempts.clear()
            self.fail_once = set()
            self.fail_offsets = set()
            self.fail_always = None
            self.drop_once = set()
            self.drop_always = False
            self.get_attempts.clear()
            self.get_fail_offsets = set()
            self.get_empty_once = set()
            self.get_empty_always = set()
            self.get_half_once = set()
            self.max_active = 0
            self.sha_override = None

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        try:
            body = recv_request(conn)
            if not body:
                return
            request = json.loads(body.decode("utf-8"))
            with self.lock:
                self.requests.append(request)
                self.active += 1
                self.max_active = max(self.max_active, self.active)
            try:
                time.sleep(self.delay)
                response = self._respond(request)
            finally:
                with self.lock:
                    self.active -= 1
            # DROP = 收下请求但**不写响应**直接关连接：`ControlServer` 在
            # `maxActiveClients` 满时就是这么干的，客户端看到的是 `empty_response`。
            if response is DROP:
                return
            conn.sendall(json.dumps(response).encode("utf-8"))
        except OSError:
            pass
        finally:
            conn.close()

    @staticmethod
    def _fail(request, code, message):
        return {"id": request.get("id"), "ok": False, "code": code, "message": message}

    @staticmethod
    def _ok(request, **payload):
        response = {"id": request.get("id"), "ok": True, "code": "ok", "message": "ok"}
        response.update(payload)
        return response

    def _respond(self, request):
        action = request.get("action")
        if action == "sftp-stat":
            return self._stat(request)
        if action == "sftp-put":
            return self._put(request)
        if action == "sftp-get":
            return self._get(request)
        if action == "run":
            return self._run(request)
        return self._fail(request, "invalid_request", "未知动作 " + str(action))

    def _stat(self, request):
        path = request.get("path")
        with self.lock:
            body = self.files.get(path)
        if body is None:
            return self._fail(request, "file_not_found", "没有 " + str(path))
        return self._ok(request, stat={"path": path, "size": len(body), "kind": "file",
                                       "permissions": 33188,
                                       "modifiedAt": "2026-09-10T00:00:00Z"})

    def _put(self, request):
        path = request.get("path")
        mode = request.get("mode") or "create"
        offset = int(request.get("offset") or 0)
        data = base64.b64decode(request.get("contentBase64") or "")
        if len(data) > 8 * 1024 * 1024:
            return self._fail(request, "request_too_large", "分片超过单请求上限")
        with self.lock:
            self.attempts[offset] = self.attempts.get(offset, 0) + 1
            if self.drop_always:
                return DROP                      # 收下就关，什么也没做
            if self.fail_always is not None:
                return self._fail(request, self.fail_always, "注入的失败")
            if offset in self.fail_offsets:
                return self._fail(request, "operation_failed", "注入的持续失败")
            if offset in self.fail_once:
                self.fail_once.discard(offset)
                return self._fail(request, "operation_failed", "注入的一次性失败")
            existing = self.files.get(path)
            if mode == "create":
                if existing is not None:
                    return self._fail(request, "file_exists", "远端已存在 " + str(path))
                body = self.files.setdefault(path, bytearray())
            elif mode == "overwrite":
                body = bytearray()
                self.files[path] = body
            elif mode == "write":
                body = self.files.setdefault(path, bytearray())
            else:
                return self._fail(request, "invalid_request", "未知 mode " + str(mode))
            if len(body) < offset:
                body.extend(b"\x00" * (offset - len(body)))
            body[offset:offset + len(data)] = data
            self.puts.append((path, offset, mode, len(data)))
            if offset in self.drop_once:
                # 写成了，响应却丢了 —— 客户端不知道该不该重发 create。
                self.drop_once.discard(offset)
                return DROP
        return self._ok(request, file={"path": path, "bytes": len(data),
                                       "isUTF8": False, "truncated": False})

    def _get(self, request):
        path = request.get("path")
        with self.lock:
            body = self.files.get(path)
            if body is None:
                return self._fail(request, "file_not_found", "没有 " + str(path))
            offset, length = request.get("offset"), request.get("length")
            if offset is None and length is None:
                if len(body) > 8 * 1024 * 1024:
                    return self._fail(request, "file_too_large", "整取超过 8 MiB")
                start, data = 0, bytes(body)
            else:
                start = int(offset or 0)
                self.get_attempts[start] = self.get_attempts.get(start, 0) + 1
                if start in self.get_fail_offsets:
                    return self._fail(request, "operation_failed", "注入的 get 失败")
                data = bytes(body[start:start + int(length or 0)])
                # 空载荷 = 「远端到 EOF 了」的样子。客户端**不能**把它当 EOF：区间是按
                # stat 的大小切的，这里少给只能是出岔子了，该片要重试。
                if start in self.get_empty_always:
                    data = b""
                elif start in self.get_empty_once:
                    self.get_empty_once.discard(start)
                    data = b""
                elif start in self.get_half_once:
                    self.get_half_once.discard(start)
                    data = data[: max(1, len(data) // 2)]
            self.gets.append((path, start, len(data)))
        return self._ok(request, file={
            "path": path, "bytes": len(data), "isUTF8": False, "truncated": False,
            "base64": base64.b64encode(data).decode("ascii")})

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


def run_cli(server, argv, expect_exit=0, socket_path=None, label=None, sleep_trace=None):
    env = dict(os.environ)
    env["UTERM_CONTROL_SOCKET"] = socket_path if socket_path else server.path
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

    run_cli(server, ["run-many", "-H", "a", "-H", "b", "--", "uptime"])
    equal(last(server)["hosts"], ["a", "b"], "run-many 用 hosts 数组")
    check("host" not in last(server), "run-many 不带单数 host")

    run_cli(server, ["quick-commands"])
    run_cli(server, ["quick-run", "磁盘水位", "-H", "prod-web"])
    equal(last(server)["name"], "磁盘水位", "quick-run 带 name")
    equal(last(server)["hosts"], ["prod-web"], "quick-run 覆盖目标")

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

    target = os.path.join(root, "hostname.txt")
    run_cli(server, ["sftp", "get", "-H", "prod-web", "/etc/hostname", target])
    equal(last(server)["action"], "sftp-get", "sftp-get")
    check(open(target, "rb").read() == b"prod-web\n", "get 在客户端落盘")
    run_cli(server, ["sftp", "get", "-H", "prod-web", "/etc/hostname", target],
            expect_exit=2, label="get 已存在不覆盖")
    run_cli(server, ["sftp", "get", "-H", "prod-web", "/etc/hostname", target, "--force"],
            label="get --force 覆盖")

    source = os.path.join(root, "upload.txt")
    open(source, "wb").write(b"hello")
    run_cli(server, ["sftp", "put", "-H", "prod-web", source, "/tmp/hello"])
    equal(last(server)["contentBase64"], base64.b64encode(b"hello").decode(),
          "put 在客户端读文件成 base64")
    equal(last(server)["path"], "/tmp/hello", "put 的 path 是远端路径")

    # 超过单请求上限的文件不再本地拒绝，而是自动切成多片（详见「分片传输」一节）。
    big = os.path.join(root, "big.bin")
    with open(big, "wb") as handle:
        handle.write(b"\0" * (8 * 1024 * 1024 + 1))
    run_cli(server, ["sftp", "put", "-H", "prod-web", big, "/tmp/big", "--no-verify"],
            label="put 超 8 MiB 自动分片")
    slices = [r for r in server.requests if r.get("action") == "sftp-put"][-2:]
    equal([r.get("mode") for r in slices], ["create", "write"],
          "超限 put 切成两片：首片 create，其余 write")
    equal([r.get("offset") for r in slices], [0, 8 * 1024 * 1024],
          "两片的 offset 首尾相接")

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
        ("command_timeout", 6), ("handler_timeout", 6),
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



# 自测用的小分片：真实缺省是 8 MiB，照那个跑一趟要搬几十 MB，没必要。
CHUNK = 256 * 1024


def make_local(root, name, size):
    path = os.path.join(root, name)
    with open(path, "wb") as handle:
        handle.write(os.urandom(size))
    return path


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def covers(slices, start, total, label):
    """[(offset, length)] 必须严丝合缝地铺满 [start, total)：不空洞、不重叠。"""
    cursor = start
    for offset, length in sorted(slices):
        if offset != cursor:
            check(False, "%s（在 %d 处断了，实得 offset %d）" % (label, cursor, offset))
            return
        cursor += length
    equal(cursor, total, label)


def transfer_of(proc):
    return json.loads(proc.stdout)["transfer"]


# 与客户端里的常量一一对应（分片状态 sidecar / get 的半成品）。
SIDECAR_SUFFIX = ".utermctl-transfer.json"
PART_SUFFIX = ".part"


def sidecar_of(local):
    return local + SIDECAR_SUFFIX


def part_of(local):
    return local + PART_SUFFIX


def wipe(local):
    """清掉一次失败传输留下的状态，好让下一段从干净的地方开始。"""
    for path in (sidecar_of(local), sidecar_of(local) + ".tmp", part_of(local)):
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


def slices_of(total, chunk):
    return [(off, min(chunk, total - off)) for off in range(0, total, chunk)]


def hole_filled(payload, done, chunk):
    """按「只有 done 里的片写进去了」造一份带空洞的远端内容 —— 失败后的真实样子。"""
    body = bytearray(len(payload))
    for off, length in slices_of(len(payload), chunk):
        if off in done:
            body[off:off + length] = payload[off:off + length]
    return bytes(body)


def exercise_transfers(server, root):
    print("分片传输：小文件仍是单请求")
    server.reset()
    small = make_local(root, "t-small.bin", 4096)
    proc = run_cli(server, ["sftp", "put", "-H", "h", small, "/r/small"])
    equal([item[2] for item in server.puts], ["create"], "小文件单请求，mode=create")
    equal([item[1] for item in server.puts], [0], "小文件 offset=0")
    check(bytes(server.files["/r/small"]) == read_bytes(small), "小文件内容一致")
    equal(transfer_of(proc)["chunks"], 1, "transfer.chunks=1")
    equal(transfer_of(proc)["verified"], False, "单请求默认不校验")
    equal(server.runs, [], "单请求不发 run 去算 sha256")
    check(not os.path.exists(sidecar_of(small)), "单请求传输不留分片状态文件")

    proc = run_cli(server, ["sftp", "put", "-H", "h", small, "/r/small"],
                   expect_exit=1, label="put 到已存在的远端路径 → file_exists")
    equal(server.requests[-1].get("mode"), "create", "没有 --force 时仍然发 create")
    check("单请求传输，没有分片状态可续" in proc.stderr, "单请求失败不谎称能 --resume")
    equal(transfer_of(proc)["resumable"], False, "单请求失败 resumable=false")
    run_cli(server, ["sftp", "put", "-H", "h", small, "/r/small", "--force"],
            label="put --force")
    equal(server.requests[-1].get("mode"), "overwrite", "--force → mode=overwrite")

    print("分片传输：大文件 put")
    server.reset()
    big = make_local(root, "t-big.bin", 8 * CHUNK + 777)
    payload = read_bytes(big)
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big",
                            "--chunk-bytes", str(CHUNK)])
    modes = [item[2] for item in server.puts]
    equal(modes[0], "create", "首片是 create（没有 --force 时不覆盖）")
    equal(set(modes[1:]), {"write"}, "其余片一律 write")
    covers([(item[1], item[3]) for item in server.puts], 0, len(payload),
           "分片覆盖完整、不重叠")
    check(bytes(server.files["/r/big"]) == payload, "服务端拼回的内容逐字节相同")
    stats = transfer_of(proc)
    equal(stats["chunks"], 9, "9 片")
    equal(stats["bytes"], 8 * CHUNK + 777, "transfer.bytes = 文件大小")
    equal(stats["parallel"], 4, "默认并行 4")
    equal(stats["verified"], True, "分片传输默认校验且一致")
    check(0 < server.max_active <= 4, "峰值并发 %d 不超过 --parallel 4" % server.max_active)
    check(server.max_active >= 2, "确实并行了（峰值并发 %d ≥ 2）" % server.max_active)
    check(not os.path.exists(sidecar_of(big)), "成功后分片状态文件删掉了")

    server.reset()
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                     str(CHUNK), "--parallel", "1", "--no-verify"],
            label="put --parallel 1")
    equal(server.max_active, 1, "--parallel 1 时全程串行")
    equal(server.runs, [], "--no-verify 不发 run")

    server.reset()
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                     str(CHUNK), "--parallel", "6", "--no-verify"],
            label="put --parallel 6（上限）")
    check(0 < server.max_active <= 6, "峰值并发 %d ≤ 6" % server.max_active)

    print("分片传输：重试")
    server.reset()
    server.fail_once = set([CHUNK, 3 * CHUNK])
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                     str(CHUNK), "--no-verify"], label="分片失败后重试成功")
    equal(server.attempts[CHUNK], 2, "失败的那片重发了一次")
    check(bytes(server.files["/r/big"]) == payload, "重试后内容仍然完整")

    # 首片之后的某一片一直失败：其余在途的片要被取消掉，而不是让 `future.result()`
    # 在取消过的 future 上抛 CancelledError。
    server.reset()
    wipe(big)
    server.fail_offsets = set([5 * CHUNK])
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                            str(CHUNK)], expect_exit=1,
                   label="非首片一直失败 → 取消其余分片")
    equal(server.attempts[5 * CHUNK], 3, "失败的那片试满 3 次")
    equal(json.loads(proc.stdout)["code"], "operation_failed", "取消路径也保留服务端的 code")
    check(json.loads(proc.stdout)["transfer"]["bytes"] > 0, "失败响应里带已传的账")

    print("分片传输：失败后的恢复语义（sidecar）")
    # 上一段那次失败留下的正是「带空洞的稀疏文件」—— 按大小续传会跳过空洞，所以
    # 状态得记在 sidecar 里。
    stats = json.loads(proc.stdout)["transfer"]
    equal(stats["incomplete"], True, "失败的 transfer 标了 incomplete")
    equal(stats["resumable"], True, "失败的 transfer 标了 resumable")
    equal(stats["statePath"], sidecar_of(big), "transfer.statePath 指向 sidecar")
    check("--resume" in proc.stderr and "不完整" in proc.stderr,
          "stderr 说清「文件不完整、--resume 可续」")
    state = load_json(sidecar_of(big))
    equal(state["version"], 1, "sidecar version")
    equal(state["direction"], "put", "sidecar direction")
    equal(state["remotePath"], "/r/big", "sidecar remotePath")
    equal(state["chunkBytes"], CHUNK, "sidecar chunkBytes")
    equal(state["totalBytes"], len(payload), "sidecar totalBytes")
    equal(state["identity"]["size"], len(payload), "sidecar identity 记了本地大小")
    check(0 in state["done"], "首片记进了 done")
    check(5 * CHUNK not in state["done"], "失败的那片没记进 done")
    check(len(bytes(server.files["/r/big"])) >= 5 * CHUNK,
          "远端确实是带空洞的稀疏文件（长度 %d）" % len(server.files["/r/big"]))

    missing = sorted(set(off for off, _ in slices_of(len(payload), CHUNK))
                     - set(state["done"]))
    server.reset()
    server.files["/r/big"] = bytearray(hole_filled(payload, state["done"], CHUNK))
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--resume"],
                   label="--resume 只补没成的片")
    equal(sorted(item[1] for item in server.puts), missing,
          "只重传了没完成的片（%d 片）" % len(missing))
    equal(set(item[2] for item in server.puts), {"write"},
          "补片一律 write（首片早就成了）")
    check(bytes(server.files["/r/big"]) == payload, "补完之后远端内容逐字节相同")
    equal(transfer_of(proc)["verified"], True, "补完之后 sha256 校验通过")
    equal(transfer_of(proc)["resumedFrom"], len(payload) - sum(
        length for off, length in slices_of(len(payload), CHUNK) if off in missing),
        "resumedFrom = 之前已经传成的字节数")
    check(not os.path.exists(sidecar_of(big)), "补完之后 sidecar 删掉了")

    # sidecar 记的分片大小说了算：`--resume` 不给 --chunk-bytes 也不会切错。
    server.reset()
    wipe(big)
    server.fail_offsets = set([2 * CHUNK])
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big2", "--chunk-bytes",
                     str(CHUNK), "--no-verify"], expect_exit=1,
            label="再造一次半截传输")
    equal(load_json(sidecar_of(big))["chunkBytes"], CHUNK, "sidecar 记着 256 KiB 的分片")
    server.fail_offsets = set()
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big2", "--resume",
                            "--no-verify"], label="--resume 用 sidecar 里的分片大小")
    check(all(item[3] <= CHUNK for item in server.puts if item[0] == "/r/big2"),
          "补片仍按 sidecar 的 256 KiB 切，没退回默认 8 MiB")
    check(bytes(server.files["/r/big2"]) == payload, "补完内容一致")

    # 身份对不上（本地文件变了）：宁可拒绝，也不能拼出一个悄悄错掉的文件。
    server.reset()
    wipe(big)
    server.fail_offsets = set([3 * CHUNK])
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big3", "--chunk-bytes",
                     str(CHUNK), "--no-verify"], expect_exit=1, label="再造一次半截传输")
    changed = read_bytes(big) + b"tail"
    with open(big, "wb") as handle:
        handle.write(changed)
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big3", "--resume"],
                   expect_exit=2, label="本地文件变了 → --resume 拒绝")
    check("已经变了" in proc.stderr, "拒绝理由说的是身份对不上")
    with open(big, "wb") as handle:                 # 复原
        handle.write(payload)
    wipe(big)

    # sidecar 记的是另一个远端路径 → 也拒绝（一个本地路径同时只跟踪一趟传输）。
    server.reset()
    server.fail_offsets = set([3 * CHUNK])
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/bigA", "--chunk-bytes",
                     str(CHUNK), "--no-verify"], expect_exit=1, label="再造一次半截传输")
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/bigB", "--resume"],
                   expect_exit=2, label="sidecar 记的是别的远端路径 → 拒绝")
    check("不是一回事" in proc.stderr, "拒绝理由说的是路径对不上")
    wipe(big)

    print("分片传输：没有 sidecar 时的续传")
    server.reset()
    server.files["/r/resume"] = bytearray(payload[: 3 * CHUNK])
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/resume", "--resume",
                            "--chunk-bytes", str(CHUNK)], expect_exit=2,
                   label="没有 sidecar 又是并行 → 拒绝按大小续传")
    check("稀疏文件" in proc.stderr and "--parallel 1" in proc.stderr,
          "拒绝理由讲清了空洞与顺序模式")

    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/resume", "--resume",
                            "--parallel", "1", "--chunk-bytes", str(CHUNK)],
                   label="--parallel 1 才按远端大小续传")
    equal(server.puts[0][1], 3 * CHUNK, "resume 从远端已有的大小起")
    equal(set(item[2] for item in server.puts), {"write"}, "续传全部用 write，不截断")
    covers([(item[1], item[3]) for item in server.puts], 3 * CHUNK, len(payload),
           "续传的分片铺满剩下那段")
    check(bytes(server.files["/r/resume"]) == payload, "续传后内容完整")
    equal(transfer_of(proc)["resumedFrom"], 3 * CHUNK, "transfer.resumedFrom")
    wipe(big)

    server.reset()
    server.files["/r/full"] = bytearray(payload)
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/full", "--resume",
                     "--parallel", "1"],
            expect_exit=2, label="远端不比本地小 → --resume 无从续起")

    server.reset()
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/absent", "--resume",
                     "--parallel", "1", "--chunk-bytes", str(CHUNK), "--no-verify"],
            label="--resume 但远端还没有这个文件")
    equal(server.puts[0][2], "create", "远端不存在时 --resume 退化成从头传")
    wipe(big)

    print("分片传输：首片 create 的重试幂等")
    server.reset()
    server.drop_once = set([0])          # 首片写成了，响应丢了
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/idem",
                            "--chunk-bytes", str(CHUNK)],
                   label="首片响应丢失 → 先 stat 再改 write 重发")
    equal(server.attempts[0], 2, "首片一共发了 2 次")
    equal([item[2] for item in server.puts if item[1] == 0], ["create", "write"],
          "第二次改成 write，不再撞 file_exists")
    check(any(r.get("action") == "sftp-stat" for r in server.requests),
          "重发之前先 stat 了一次")
    check(bytes(server.files["/r/idem"]) == payload, "最终远端内容正确")
    equal(transfer_of(proc)["verified"], True, "重发后校验仍通过")

    server.reset()
    server.files["/r/theirs"] = bytearray(payload + payload)   # 别人的、更大的文件
    server.drop_always = True
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/theirs",
                            "--chunk-bytes", str(CHUNK)], expect_exit=1,
                   label="响应丢失但远端本来就有更大的文件 → file_exists")
    equal(json.loads(proc.stdout)["code"], "file_exists", "不是我们写的就报 file_exists")
    equal(server.attempts[0], 1, "认出是别人的文件后不再重发")
    check("--force" in json.loads(proc.stdout)["message"], "提示要覆盖得加 --force")

    print("分片传输：退避与重试次数")
    trace = os.path.join(root, "sleep.trace")
    for label, setup, code in (
            ("server_busy", lambda: setattr(server, "fail_always", "server_busy"),
             "server_busy"),
            ("empty_response", lambda: setattr(server, "drop_always", True),
             "empty_response")):
        server.reset()
        if os.path.exists(trace):
            os.unlink(trace)
        setup()
        proc = run_cli(server, ["sftp", "put", "-H", "h", small, "/r/busy"],
                       expect_exit=2, sleep_trace=trace,
                       label="%s → 更耐心地重试" % label)
        equal(json.loads(proc.stdout)["code"], code, "%s 保留原码" % label)
        equal(server.attempts[0], 6, "%s 一共试 6 次（1 + 5 次重试）" % label)
        equal(read_lines(trace), ["0.500", "1.000", "2.000", "4.000", "4.000"],
              "%s 的退避序列是 0.5/1/2/4/4 秒" % label)

    server.reset()
    if os.path.exists(trace):
        os.unlink(trace)
    server.fail_always = "operation_failed"
    proc = run_cli(server, ["sftp", "put", "-H", "h", small, "/r/plain"],
                   expect_exit=1, sleep_trace=trace, label="一般可重试码仍是 2 次")
    equal(server.attempts[0], 3, "可重试的码总共试 3 次（1 + 2 次重试）")
    equal(read_lines(trace), ["0.500", "1.000"], "一般码的退避序列是 0.5/1 秒")
    equal(json.loads(proc.stdout)["code"], "operation_failed", "失败保留服务端的 code")

    server.reset()
    server.fail_always = "file_exists"
    run_cli(server, ["sftp", "put", "-H", "h", small, "/r/x"],
            expect_exit=1, label="file_exists → 退出码 1")
    equal(server.attempts[0], 1, "file_exists 是终局，不重试")

    server.reset()
    server.fail_always = "host_not_found"
    run_cli(server, ["sftp", "put", "-H", "h", small, "/r/x"],
            expect_exit=4, label="host_not_found → 退出码 4")
    equal(server.attempts[0], 1, "*_not_found 也不重试")

    print("分片传输：get")
    server.reset()
    server.files["/r/down"] = bytearray(payload)
    target = os.path.join(root, "t-down.bin")
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", target,
                            "--chunk-bytes", str(CHUNK)])
    check(read_bytes(target) == payload, "并行下载拼回的本地文件逐字节相同")
    covers([(item[1], item[2]) for item in server.gets], 0, len(payload),
           "get 的区间覆盖完整、不重叠")
    check(all(r.get("length") is not None for r in server.requests
              if r.get("action") == "sftp-get"), "分片 get 都带 length")
    stats = transfer_of(proc)
    equal(stats["verified"], True, "get 分片后也校验 sha256")
    equal(stats["bytes"], len(payload) - stats["resumedFrom"],
          "received == size - resumedFrom")
    check(0 < server.max_active <= 4, "get 峰值并发 %d ≤ 4" % server.max_active)
    check(not os.path.exists(part_of(target)), "成功后 .part 已经改名成目标")
    check(not os.path.exists(sidecar_of(target)), "成功后 sidecar 删掉了")
    os.unlink(target)

    server.reset()
    server.files["/r/tiny"] = bytearray(b"prod-web\n")
    tiny = os.path.join(root, "t-tiny.txt")
    run_cli(server, ["sftp", "get", "-H", "h", "/r/tiny", tiny])
    equal(read_bytes(tiny), b"prod-web\n", "小文件 get 照旧落盘")
    gets = [r for r in server.requests if r.get("action") == "sftp-get"]
    equal(len(gets), 1, "小文件 get 只发一条请求")
    check("offset" not in gets[0] and "length" not in gets[0],
          "小文件 get 不带 offset / length（请求形状与旧版一致）")

    run_cli(server, ["sftp", "get", "-H", "h", "/r/tiny", tiny],
            expect_exit=2, label="本地已存在且没给 --force")
    run_cli(server, ["sftp", "get", "-H", "h", "/r/tiny", tiny, "--force"],
            label="get --force 覆盖")

    print("分片传输：get 失败后不留满尺寸的假象")
    server.reset()
    server.files["/r/down"] = bytearray(payload)
    broken = os.path.join(root, "t-broken.bin")
    server.get_fail_offsets = set([3 * CHUNK])
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", broken,
                            "--chunk-bytes", str(CHUNK)], expect_exit=1,
                   label="get 中间片一直失败")
    check(not os.path.exists(broken), "失败时目标名根本没生成")
    check(os.path.exists(part_of(broken)), "半成品留在 .part 里")
    stats = json.loads(proc.stdout)["transfer"]
    equal(stats["partPath"], part_of(broken), "transfer.partPath 指向半成品")
    equal(stats["incomplete"], True, "get 失败标了 incomplete")
    equal(stats["resumable"], True, "get 失败标了 resumable")
    check("不完整" in proc.stderr and "--resume" in proc.stderr,
          "stderr 说清「不完整、--resume 可续」")
    state = load_json(sidecar_of(broken))
    equal(state["direction"], "get", "sidecar direction=get")
    check(3 * CHUNK not in state["done"], "失败的那片没记进 done")

    server.reset()
    server.files["/r/down"] = bytearray(payload)
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", broken, "--resume"],
                   label="get --resume 只补没取到的片")
    equal(sorted(item[1] for item in server.gets),
          sorted(set(off for off, _ in slices_of(len(payload), CHUNK))
                 - set(state["done"])),
          "只重取了没完成的片")
    check(read_bytes(broken) == payload, "补完之后目标文件逐字节相同")
    check(not os.path.exists(part_of(broken)), "补完之后 .part 已经改名成目标")
    check(not os.path.exists(sidecar_of(broken)), "补完之后 sidecar 删掉了")
    os.unlink(broken)

    print("分片传输：短载荷不是 EOF")
    server.reset()
    server.files["/r/down"] = bytearray(payload)
    server.get_empty_once = set([2 * CHUNK])
    server.get_half_once = set([CHUNK])
    short = os.path.join(root, "t-short.bin")
    run_cli(server, ["sftp", "get", "-H", "h", "/r/down", short,
                     "--chunk-bytes", str(CHUNK)],
            label="非末片收到空载荷 → 重试而不是当 EOF")
    check(server.get_attempts[2 * CHUNK] >= 2, "空载荷的那片重试了")
    check(read_bytes(short) == payload, "重试后本地文件仍然逐字节相同（没被当成 EOF 截断）")
    os.unlink(short)

    server.reset()
    server.files["/r/down"] = bytearray(payload)
    server.get_empty_always = set([2 * CHUNK])
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", short,
                            "--chunk-bytes", str(CHUNK)], expect_exit=1,
                   label="非末片一直空载荷 → 该片失败")
    equal(json.loads(proc.stdout)["code"], "remote_short_read",
          "空载荷报 remote_short_read，不是悄悄成功")
    equal(server.get_attempts[2 * CHUNK], 3, "空载荷的那片试满 3 次")
    check(not os.path.exists(short), "失败时目标名没生成")
    wipe(short)

    print("分片传输：get 没有 sidecar 时的续传")
    server.reset()
    server.files["/r/down"] = bytearray(payload)
    partial = os.path.join(root, "t-partial.bin")
    with open(partial, "wb") as handle:
        handle.write(payload[: 2 * CHUNK])
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", partial, "--resume",
                            "--chunk-bytes", str(CHUNK)], expect_exit=2,
                   label="没有 sidecar 又是并行 → 拒绝按大小续传")
    check("稀疏文件" in proc.stderr, "拒绝理由讲清了空洞")

    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", partial, "--resume",
                            "--parallel", "1", "--chunk-bytes", str(CHUNK)],
                   label="--parallel 1 才按本地大小续传")
    equal(min(item[1] for item in server.gets), 2 * CHUNK, "get --resume 从本地已有大小起")
    check(read_bytes(partial) == payload, "续传后的本地文件完整")
    equal(transfer_of(proc)["resumedFrom"], 2 * CHUNK, "get 的 resumedFrom")
    check(not os.path.exists(part_of(partial)), "旧版留在目标名上的半截文件也收尾了")

    server.reset()
    server.files["/r/down"] = bytearray(payload[: 1024])
    run_cli(server, ["sftp", "get", "-H", "h", "/r/down", partial, "--resume",
                     "--parallel", "1"],
            expect_exit=2, label="本地比远端还大 → 无从续起")
    os.unlink(partial)

    print("分片传输：本地 I/O 出错也是结构化失败")
    server.reset()
    server.files["/r/down"] = bytearray(payload)
    blocked = os.path.join(root, "t-blocked.bin")
    os.mkdir(part_of(blocked))               # 半成品的位置被一个目录占着
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", blocked,
                            "--chunk-bytes", str(CHUNK)], expect_exit=2,
                   label="get 的 .part 位置是个目录")
    equal(json.loads(proc.stdout)["code"], "local_write_failed", "报 local_write_failed")
    check("Traceback" not in proc.stderr, "没有 traceback 漏到 stderr")
    os.rmdir(part_of(blocked))

    server.reset()
    unreadable = make_local(root, "t-unreadable.bin", 4 * CHUNK)
    os.chmod(unreadable, 0)
    proc = run_cli(server, ["sftp", "put", "-H", "h", unreadable, "/r/unreadable",
                            "--chunk-bytes", str(CHUNK)], expect_exit=2,
                   label="put 读不了本地文件")
    equal(json.loads(proc.stdout)["code"], "local_read_failed", "报 local_read_failed")
    check("Traceback" not in proc.stderr, "没有 traceback 漏到 stderr")
    os.chmod(unreadable, 0o644)

    print("分片传输：校验")
    server.reset()
    quoted = "/r/有空格 的路径"
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, quoted,
                            "--chunk-bytes", str(CHUNK)])
    equal(len(server.runs), 1, "校验只发一条 run")
    command = server.runs[0]
    check("sha256sum -- " in command and "shasum -a 256 -- " in command,
          "远端命令是 sha256sum 兜底 shasum")
    check(shlex.quote(quoted) in command, "远端路径经过 shlex.quote")
    equal(transfer_of(proc)["sha256"], hashlib.sha256(payload).hexdigest(),
          "transfer.sha256 是本地算的")

    server.reset()
    server.sha_override = "missing"
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/nohash",
                            "--chunk-bytes", str(CHUNK)],
                   label="远端没有 sha256sum / shasum")
    equal(transfer_of(proc)["verified"], False, "没工具就 verified=false")
    check("跳过校验" in (transfer_of(proc)["verifyNote"] or ""), "verifyNote 说明原因")
    check("跳过校验" in proc.stderr, "stderr 上提示了跳过校验")

    server.reset()
    server.sha_override = "0" * 64
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/bad",
                            "--chunk-bytes", str(CHUNK)],
                   expect_exit=1, label="sha256 不一致 → 退出码 1")
    equal(json.loads(proc.stdout)["code"], "checksum_mismatch", "code=checksum_mismatch")
    check("整份重传" in json.loads(proc.stdout)["message"], "提示整份重传")
    check(not os.path.exists(sidecar_of(big)),
          "内容对不上时 sidecar 也删掉（补片补不回内容）")

    server.reset()
    server.files["/r/down"] = bytearray(payload)
    server.sha_override = "0" * 64
    mismatch = os.path.join(root, "t-mismatch.bin")
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", mismatch,
                            "--chunk-bytes", str(CHUNK)],
                   expect_exit=1, label="get 校验不过 → 不占用目标名")
    check(not os.path.exists(mismatch), "校验不过时目标名不生成")
    check(os.path.exists(part_of(mismatch)), "内容留在 .part 里给人看")
    os.unlink(part_of(mismatch))

    print("分片传输：参数校验与输出")
    server.reset()
    for bad in (["--parallel", "0"], ["--parallel", "7"], ["--chunk-mib", "9"],
                ["--chunk-bytes", "0"], ["--force", "--resume"]):
        run_cli(server, ["sftp", "put", "-H", "h", small, "/r/x"] + bad,
                expect_exit=2, label="参数校验 " + " ".join(bad))
    run_cli(server, ["sftp", "get", "-H", "h", "/r/x", os.path.join(root, "z"),
                     "--parallel", "7"], expect_exit=2, label="get 也校验 --parallel")
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/x", os.path.join(root, "z"),
                            "--force", "--resume"], expect_exit=2,
                   label="get 也拦 --force --resume")
    check("--force" in proc.stderr and "--resume" in proc.stderr,
          "argparse 说清了这两个选项互斥")

    server.reset()
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/table",
                            "--chunk-bytes", str(CHUNK), "--format", "table"])
    check("chunks" in proc.stdout and "verified" in proc.stdout, "table 是两列字段表")
    check("上传完成" in proc.stderr, "非 tty 时结束仍打一行汇总到 stderr")

    server.reset()
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/quiet",
                            "--chunk-bytes", str(CHUNK), "--quiet", "--no-verify"])
    check("\r" not in proc.stderr, "--quiet 不刷进度行")
    check("上传完成" in proc.stderr, "--quiet 仍打汇总")


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
    client.exchange = lambda path, request: {"ok": True}

    # 1. 读得到且关着：本地直接拦下，不起进程。
    client.PREFERENCE_CANDIDATES = [readable_off]
    client.subprocess.Popen = fake_popen(FakeLauncher(0))
    started, message = client.start_background_and_wait()
    check(not started and "没有允许 CLI 按需启动" in (message or ""), "设置读得到且关着 → 本地拒绝")
    equal(len(launched), 0, "本地拒绝时不唤起 uTerm")

    # 残留 socket + 按需启动关着：错误码不变，但消息要带上「为什么没自己起」，
    # 否则 Agent 只看到「等它起来」，不知道有个开关能让客户端自己起。
    def refuse(path, request):
        raise ConnectionRefusedError()
    dead = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    dead.bind(ready_socket)
    dead.close()
    client.exchange = refuse
    response = client.send_request({"id": "stale", "action": "ping"})
    equal(response["code"], client.CODE_SOCKET_STALE, "残留 socket + 按需启动关着 → 仍是 uterm_socket_stale")
    check("允许 CLI 按需启动" in response["message"], "残留 socket 的消息带上按需启动没成功的原因")
    os.unlink(ready_socket)
    client.exchange = lambda path, request: {"ok": True}

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


if __name__ == "__main__":
    sys.exit(main())
