//go:build linux

package relay

import (
	"net"
	"syscall"
	"time"
)

const tcpUserTimeoutOption = 18 // TCP_USER_TIMEOUT

func configureSocket(conn net.Conn) {
	tcp, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	tcp.SetKeepAliveConfig(net.KeepAliveConfig{Enable: true, Idle: 10 * time.Second, Interval: 5 * time.Second, Count: 3})
	raw, err := tcp.SyscallConn()
	if err != nil {
		return
	}
	raw.Control(func(fd uintptr) {
		syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, tcpUserTimeoutOption, 25_000)
	})
}
