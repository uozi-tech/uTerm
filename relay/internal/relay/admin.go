package relay

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// AdminSocketPath is how the commands reach the running relay.
func AdminSocketPath(dataDir string) string { return filepath.Join(dataDir, "admin.sock") }

// ServeAdmin answers one line per connection: `status`, `rotate`, `forget <hostID>`.
func (s *Server) ServeAdmin(path string) (func(), error) {
	os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	os.Chmod(path, 0o600)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go s.handleAdmin(conn)
		}
	}()
	return func() { listener.Close() }, nil
}

func (s *Server) handleAdmin(conn net.Conn) {
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return
	}
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return
	}
	switch fields[0] {
	case "status":
		json.NewEncoder(conn).Encode(s.Status())
	case "rotate":
		if err := s.store.Rotate(); err != nil {
			fmt.Fprintf(conn, "error: %v\n", err)
			return
		}
		fmt.Fprintln(conn, "ok")
		s.DropAll()
	case "forget":
		if len(fields) != 2 {
			fmt.Fprintln(conn, "error: forget needs a host id")
			return
		}
		if err := s.store.Forget(fields[1]); err != nil {
			fmt.Fprintf(conn, "error: %v\n", err)
			return
		}
		s.DropHost(fields[1])
		fmt.Fprintln(conn, "ok")
	default:
		fmt.Fprintln(conn, "error: unknown command")
	}
}

// AdminCommand sends one command to a running relay and returns its answer.
func AdminCommand(path, command string) (string, error) {
	conn, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		return "", fmt.Errorf("the relay is not running here: %w", err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := fmt.Fprintln(conn, command); err != nil {
		return "", err
	}
	answer, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(answer), nil
}
