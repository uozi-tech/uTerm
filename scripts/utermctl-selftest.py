#!/usr/bin/env python3
"""scripts/utermctl 的离线自测：起一个假的 Unix socket 服务端，把每个子命令都跑一遍。

校验三件事：请求编码（字段名 / action rawValue 与 ControlProtocol.swift 一致）、
输出格式化、错误码 → 退出码映射。不需要 uTerm 在跑，也不碰任何真实主机。

    python3 scripts/utermctl-selftest.py        # 也是 `make check-cli`
"""
import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

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
                           "modifiedAt": "2026-09-09T01:00:00Z"}},
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
                chunks = []
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    chunks.append(chunk)
                if not chunks:
                    continue
                request = json.loads(b"".join(chunks).decode("utf-8"))
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
    try:
        return exercise(server, root)
    finally:
        server.close()
        shutil.rmtree(root, ignore_errors=True)


def exercise(server, root):
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

    big = os.path.join(root, "big.bin")
    with open(big, "wb") as handle:
        handle.write(b"\0" * (8 * 1024 * 1024 + 1))
    run_cli(server, ["sftp", "put", "-H", "prod-web", big, "/tmp/big"],
            expect_exit=2, label="put 超 8 MiB 本地先拒")

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

    print("")
    if FAILURES:
        print("%d 项失败：" % len(FAILURES))
        for item in FAILURES:
            print("  - " + item)
        return 1
    print("utermctl 自测全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
