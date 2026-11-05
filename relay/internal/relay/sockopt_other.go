//go:build !linux

package relay

import (
	"net"
	"time"
)

func configureSocket(conn net.Conn) {
	if tcp, ok := conn.(*net.TCPConn); ok {
		tcp.SetKeepAliveConfig(net.KeepAliveConfig{Enable: true, Idle: 10 * time.Second, Interval: 5 * time.Second, Count: 3})
	}
}
