package holder

import (
	"os"
	"syscall"
	"unsafe"
)

type winsize struct {
	rows, cols, xPixel, yPixel uint16
}

func ioctl(fd int, request uintptr, argument unsafe.Pointer) error {
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, uintptr(argument)); errno != 0 {
		return errno
	}
	return nil
}

// 在 os.File 的 fd 上做一次 ioctl。不用 File.Fd()：它会把 fd 改回阻塞模式。
func fileIoctl(file *os.File, request uintptr, argument unsafe.Pointer) error {
	raw, err := file.SyscallConn()
	if err != nil {
		return err
	}
	var result error
	if err := raw.Control(func(fd uintptr) { result = ioctl(int(fd), request, argument) }); err != nil {
		return err
	}
	return result
}

func setWindowSize(file *os.File, cols, rows uint16) error {
	size := winsize{rows: rows, cols: cols}
	return fileIoctl(file, syscall.TIOCSWINSZ, unsafe.Pointer(&size))
}

// 前台进程组。取不到返回 0。
func foregroundProcessGroup(master *os.File) int {
	var group int32
	if err := fileIoctl(master, syscall.TIOCGPGRP, unsafe.Pointer(&group)); err != nil {
		return 0
	}
	return int(group)
}
