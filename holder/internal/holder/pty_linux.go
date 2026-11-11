package holder

import (
	"net"
	"os"
	"strconv"
	"syscall"
	"unsafe"
)

// 开一对 PTY。主端设成非阻塞再交给 os.File，读写走 runtime 的轮询器：Close 能打断卡着的读写。
func openPTY() (master *os.File, slavePath string, err error) {
	fd, err := syscall.Open("/dev/ptmx", syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, "", err
	}
	var unlock int32
	if err := ioctl(fd, syscall.TIOCSPTLCK, unsafe.Pointer(&unlock)); err != nil {
		syscall.Close(fd)
		return nil, "", err
	}
	var number uint32
	if err := ioctl(fd, syscall.TIOCGPTN, unsafe.Pointer(&number)); err != nil {
		syscall.Close(fd)
		return nil, "", err
	}
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, "", err
	}
	return os.NewFile(uintptr(fd), "/dev/ptmx"), "/dev/pts/" + strconv.Itoa(int(number)), nil
}

// 目录权限 0700 已经挡住别的用户，这里再核一次对端的 uid。
func peerIsSameUser(conn *net.UnixConn) bool {
	raw, err := conn.SyscallConn()
	if err != nil {
		return false
	}
	allowed := false
	_ = raw.Control(func(fd uintptr) {
		cred, err := syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
		allowed = err == nil && int(cred.Uid) == os.Getuid()
	})
	return allowed
}
