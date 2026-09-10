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
                data = bytes(body[start:start + int(length or 0)])
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


def run_cli(server, argv, expect_exit=0, socket_path=None, label=None):
    env = dict(os.environ)
    env["UTERM_CONTROL_SOCKET"] = socket_path if socket_path else server.path
    proc = subprocess.run([sys.executable, CLIENT] + argv, env=env,
                          capture_output=True, text=True)
    name = label or " ".join(argv)
    check(proc.returncode == expect_exit,
          "%s 退出码 %d（应为 %d）%s" % (name, proc.returncode, expect_exit,
                                        proc.stderr.strip()))
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

    run_cli(server, ["sftp", "put", "-H", "h", small, "/r/small"],
            expect_exit=1, label="put 到已存在的远端路径 → file_exists")
    equal(server.requests[-1].get("mode"), "create", "没有 --force 时仍然发 create")
    run_cli(server, ["sftp", "put", "-H", "h", small, "/r/small", "--force"],
            label="put --force")
    equal(server.requests[-1].get("mode"), "overwrite", "--force → mode=overwrite")

    print("分片传输：大文件 put")
    server.reset()
    big = make_local(root, "t-big.bin", 8 * CHUNK + 777)
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big",
                            "--chunk-bytes", str(CHUNK)])
    modes = [item[2] for item in server.puts]
    equal(modes[0], "create", "首片是 create（没有 --force 时不覆盖）")
    equal(set(modes[1:]), {"write"}, "其余片一律 write")
    covers([(item[1], item[3]) for item in server.puts], 0, len(read_bytes(big)),
           "分片覆盖完整、不重叠")
    check(bytes(server.files["/r/big"]) == read_bytes(big), "服务端拼回的内容逐字节相同")
    stats = transfer_of(proc)
    equal(stats["chunks"], 9, "9 片")
    equal(stats["bytes"], 8 * CHUNK + 777, "transfer.bytes = 文件大小")
    equal(stats["parallel"], 4, "默认并行 4")
    equal(stats["verified"], True, "分片传输默认校验且一致")
    check(0 < server.max_active <= 4, "峰值并发 %d 不超过 --parallel 4" % server.max_active)
    check(server.max_active >= 2, "确实并行了（峰值并发 %d ≥ 2）" % server.max_active)

    server.reset()
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                     str(CHUNK), "--parallel", "1", "--no-verify"],
            label="put --parallel 1")
    equal(server.max_active, 1, "--parallel 1 时全程串行")
    equal(server.runs, [], "--no-verify 不发 run")

    print("分片传输：重试")
    server.reset()
    server.fail_once = set([CHUNK, 3 * CHUNK])
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                     str(CHUNK), "--no-verify"], label="分片失败后重试成功")
    equal(server.attempts[CHUNK], 2, "失败的那片重发了一次")
    check(bytes(server.files["/r/big"]) == read_bytes(big), "重试后内容仍然完整")

    # 首片之后的某一片一直失败：其余在途的片要被取消掉，而不是让 `future.result()`
    # 在取消过的 future 上抛 CancelledError。
    server.reset()
    server.fail_offsets = set([5 * CHUNK])
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                            str(CHUNK)], expect_exit=1,
                   label="非首片一直失败 → 取消其余分片")
    equal(server.attempts[5 * CHUNK], 3, "失败的那片试满 3 次")
    equal(json.loads(proc.stdout)["code"], "operation_failed", "取消路径也保留服务端的 code")
    check(json.loads(proc.stdout)["transfer"]["bytes"] > 0, "失败响应里带已传的账")

    server.reset()
    server.fail_always = "operation_failed"
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                            str(CHUNK)], expect_exit=1, label="分片一直失败 → 整体失败")
    equal(server.attempts[0], 3, "可重试的码总共试 3 次（1 + 2 次重试）")
    equal(json.loads(proc.stdout)["code"], "operation_failed", "失败保留服务端的 code")

    server.reset()
    server.fail_always = "file_exists"
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                            str(CHUNK)], expect_exit=1, label="file_exists → 退出码 1")
    equal(server.attempts[0], 1, "file_exists 是终局，不重试")

    server.reset()
    server.fail_always = "host_not_found"
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/big", "--chunk-bytes",
                     str(CHUNK)], expect_exit=4, label="host_not_found → 退出码 4")
    equal(server.attempts[0], 1, "*_not_found 也不重试")

    print("分片传输：resume")
    server.reset()
    payload = read_bytes(big)
    server.files["/r/resume"] = bytearray(payload[: 3 * CHUNK])
    proc = run_cli(server, ["sftp", "put", "-H", "h", big, "/r/resume", "--resume",
                            "--chunk-bytes", str(CHUNK)])
    equal(server.puts[0][1], 3 * CHUNK, "resume 从远端已有的大小起")
    equal(set(item[2] for item in server.puts), {"write"}, "续传全部用 write，不截断")
    covers([(item[1], item[3]) for item in server.puts], 3 * CHUNK, len(payload),
           "续传的分片铺满剩下那段")
    check(bytes(server.files["/r/resume"]) == payload, "续传后内容完整")
    equal(transfer_of(proc)["resumedFrom"], 3 * CHUNK, "transfer.resumedFrom")

    server.reset()
    server.files["/r/full"] = bytearray(payload)
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/full", "--resume"],
            expect_exit=2, label="远端不比本地小 → --resume 无从续起")

    server.reset()
    run_cli(server, ["sftp", "put", "-H", "h", big, "/r/absent", "--resume",
                     "--chunk-bytes", str(CHUNK), "--no-verify"],
            label="--resume 但远端还没有这个文件")
    equal(server.puts[0][2], "create", "远端不存在时 --resume 退化成从头传")

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
    equal(transfer_of(proc)["verified"], True, "get 分片后也校验 sha256")
    check(0 < server.max_active <= 4, "get 峰值并发 %d ≤ 4" % server.max_active)

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

    server.reset()
    server.files["/r/down"] = bytearray(payload)
    partial = os.path.join(root, "t-partial.bin")
    with open(partial, "wb") as handle:
        handle.write(payload[: 2 * CHUNK])
    proc = run_cli(server, ["sftp", "get", "-H", "h", "/r/down", partial, "--resume",
                            "--chunk-bytes", str(CHUNK)])
    equal(min(item[1] for item in server.gets), 2 * CHUNK, "get --resume 从本地已有大小起")
    check(read_bytes(partial) == payload, "续传后的本地文件完整")
    equal(transfer_of(proc)["resumedFrom"], 2 * CHUNK, "get 的 resumedFrom")

    server.reset()
    server.files["/r/down"] = bytearray(payload[: 1024])
    run_cli(server, ["sftp", "get", "-H", "h", "/r/down", partial, "--resume"],
            expect_exit=2, label="本地比远端还大 → 无从续起")

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
    check("--resume" in json.loads(proc.stdout)["message"], "提示 --resume 或重传")

    print("分片传输：参数校验与输出")
    server.reset()
    for bad in (["--parallel", "0"], ["--parallel", "9"], ["--chunk-mib", "9"],
                ["--chunk-bytes", "0"]):
        run_cli(server, ["sftp", "put", "-H", "h", small, "/r/x"] + bad,
                expect_exit=2, label="参数校验 " + " ".join(bad))
    run_cli(server, ["sftp", "get", "-H", "h", "/r/x", os.path.join(root, "z"),
                     "--parallel", "9"], expect_exit=2, label="get 也校验 --parallel")

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


if __name__ == "__main__":
    sys.exit(main())
