package holder

import (
	"net"
	"os"
	"syscall"
	"unsafe"
)

// macOS 上只为了在开发机上跑测试；发布的是 Linux 版。
func openPTY() (master *os.File, slavePath string, err error) {
	fd, err := syscall.Open("/dev/ptmx", syscall.O_RDWR|syscall.O_NOCTTY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, "", err
	}
	if err := ioctl(fd, syscall.TIOCPTYGRANT, nil); err != nil {
		syscall.Close(fd)
		return nil, "", err
	}
	if err := ioctl(fd, syscall.TIOCPTYUNLK, nil); err != nil {
		syscall.Close(fd)
		return nil, "", err
	}
	var name [128]byte
	if err := ioctl(fd, syscall.TIOCPTYGNAME, unsafe.Pointer(&name[0])); err != nil {
		syscall.Close(fd)
		return nil, "", err
	}
	length := 0
	for length < len(name) && name[length] != 0 {
		length++
	}
	if err := syscall.SetNonblock(fd, true); err != nil {
		syscall.Close(fd)
		return nil, "", err
	}
	return os.NewFile(uintptr(fd), "/dev/ptmx"), string(name[:length]), nil
}

// 这里只靠目录权限 0700。
func peerIsSameUser(*net.UnixConn) bool { return true }
