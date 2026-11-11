// Package holder 是主机上的会话保持进程：持有 PTY，记住最近的输出，客户端断开后 shell 继续跑，
// 重新接入时把断开期间的输出补回去。
//
// 帧格式与 Mac 上的 uterm-holder 相同（uTermHolder/HolderWire.swift）：
// [u32 小端：kind + payload 的长度][u8 kind][payload]，整数一律小端。
//
// 协议冻结：保持进程要活过 App 的多次升级，运行中的旧进程会遇到新 App。只能加新的帧类型，
// 不能改已有帧的含义；双方都忽略不认识的帧，不断连。
package holder

import (
	"encoding/binary"
	"errors"
	"io"
)

const (
	ProtocolVersion uint32 = 1
	// 单帧上限。最大的帧是检查点。超过视为对端出错，断开。
	maxFrameBytes = 64 << 20
	// 回放时每帧输出的字节数。
	outputChunkBytes = 256 << 10
)

type Kind uint8

const (
	// 客户端 → 保持进程
	KindHello         Kind = 1
	KindAttach        Kind = 2
	KindInput         Kind = 3
	KindResize        Kind = 4
	KindCheckpoint    Kind = 5
	KindSetAttributes Kind = 6
	KindTerminate     Kind = 7
	// 给前台进程组发 SIGWINCH。尺寸没变时 TIOCSWINSZ 不会发，TUI 不知道要重画。
	KindRedraw Kind = 8
	// 9（probe）、10（childRequest）只有 Mac 上的 uterm-ssh 会话用，这里忽略。

	// 保持进程 → 客户端
	KindHelloReply       Kind = 101
	KindReplayCheckpoint Kind = 102
	KindOutput           Kind = 103
	KindReplayEnd        Kind = 104
	KindExited           Kind = 105
	// 另一个客户端接入了这个会话，这条连接到此为止。
	KindReplaced Kind = 106
)

type Frame struct {
	Kind    Kind
	Payload []byte
}

var errFrameTooLarge = errors.New("frame too large")

// AppendFrame 把一帧编码后接在 dst 后面。
func AppendFrame(dst []byte, kind Kind, payload []byte) []byte {
	dst = binary.LittleEndian.AppendUint32(dst, uint32(len(payload)+1))
	dst = append(dst, byte(kind))
	return append(dst, payload...)
}

// ReadFrame 读一帧。不认识的 kind 照样读出来，由调用方忽略。
func ReadFrame(r io.Reader) (Frame, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return Frame{}, err
	}
	length := binary.LittleEndian.Uint32(header[:4])
	if length < 1 || length > maxFrameBytes {
		return Frame{}, errFrameTooLarge
	}
	payload := make([]byte, length-1)
	if _, err := io.ReadFull(r, payload); err != nil {
		return Frame{}, err
	}
	return Frame{Kind: Kind(header[4]), Payload: payload}, nil
}

// HelloReply 是会话的基本情况。客户端列会话、接入前都看它。
type HelloReply struct {
	Version   uint32
	ShellPID  int32
	CreatedAt uint64
	Cols      uint16
	Rows      uint16
	// shell 已退出、等客户端回来看最后一屏时非 nil。
	ExitStatus *int32
	Attributes []byte
}

const helloReplyFixedBytes = 25

func (h HelloReply) Encode() []byte {
	out := make([]byte, 0, helloReplyFixedBytes+len(h.Attributes))
	out = binary.LittleEndian.AppendUint32(out, h.Version)
	out = binary.LittleEndian.AppendUint32(out, uint32(h.ShellPID))
	out = binary.LittleEndian.AppendUint64(out, h.CreatedAt)
	out = binary.LittleEndian.AppendUint16(out, h.Cols)
	out = binary.LittleEndian.AppendUint16(out, h.Rows)
	var exited byte
	var status int32
	if h.ExitStatus != nil {
		exited, status = 1, *h.ExitStatus
	}
	out = append(out, exited)
	out = binary.LittleEndian.AppendUint32(out, uint32(status))
	return append(out, h.Attributes...)
}

func DecodeHelloReply(payload []byte) (HelloReply, bool) {
	if len(payload) < helloReplyFixedBytes {
		return HelloReply{}, false
	}
	reply := HelloReply{
		Version:    binary.LittleEndian.Uint32(payload[0:]),
		ShellPID:   int32(binary.LittleEndian.Uint32(payload[4:])),
		CreatedAt:  binary.LittleEndian.Uint64(payload[8:]),
		Cols:       binary.LittleEndian.Uint16(payload[16:]),
		Rows:       binary.LittleEndian.Uint16(payload[18:]),
		Attributes: payload[helloReplyFixedBytes:],
	}
	if payload[20] != 0 {
		status := int32(binary.LittleEndian.Uint32(payload[21:]))
		reply.ExitStatus = &status
	}
	return reply, true
}

// Checkpoint 是客户端上传的检查点：Blob 是终端状态（对保持进程不透明），Offset 是它对应的输出流位置。
// 接回时：喂 Blob，再喂 Offset 之后的字节。
type Checkpoint struct {
	Offset uint64
	Cols   uint16
	Rows   uint16
	// 仅保持进程 → 客户端：Offset 之后的字节有一部分已被缓冲丢弃（客户端不在期间输出太多）。
	HasGap bool
	Blob   []byte
}

const checkpointFixedBytes = 13

func (c Checkpoint) Encode() []byte {
	out := make([]byte, 0, checkpointFixedBytes+len(c.Blob))
	out = binary.LittleEndian.AppendUint64(out, c.Offset)
	out = binary.LittleEndian.AppendUint16(out, c.Cols)
	out = binary.LittleEndian.AppendUint16(out, c.Rows)
	var gap byte
	if c.HasGap {
		gap = 1
	}
	out = append(out, gap)
	return append(out, c.Blob...)
}

func DecodeCheckpoint(payload []byte) (Checkpoint, bool) {
	if len(payload) < checkpointFixedBytes {
		return Checkpoint{}, false
	}
	return Checkpoint{
		Offset: binary.LittleEndian.Uint64(payload[0:]),
		Cols:   binary.LittleEndian.Uint16(payload[8:]),
		Rows:   binary.LittleEndian.Uint16(payload[10:]),
		HasGap: payload[12] != 0,
		Blob:   payload[checkpointFixedBytes:],
	}, true
}

// attach 帧的负载（Mac 上的 uterm-holder 没有，这里新加）：
//   - 空负载：从保持进程存着的检查点接回。客户端手里什么都没有时用（App 被杀过、换了设备）。
//   - [u8 1][u64 offset]：客户端自己的终端状态还在，只要 offset 之后的字节；回的 replayCheckpoint 不带 Blob。
const attachFromOffset byte = 1

func EncodeAttachFromOffset(offset uint64) []byte {
	return binary.LittleEndian.AppendUint64([]byte{attachFromOffset}, offset)
}

func decodeAttachOffset(payload []byte) (uint64, bool) {
	if len(payload) < 9 || payload[0] != attachFromOffset {
		return 0, false
	}
	return binary.LittleEndian.Uint64(payload[1:]), true
}

func EncodeGridSize(cols, rows uint16) []byte {
	return binary.LittleEndian.AppendUint16(binary.LittleEndian.AppendUint16(nil, cols), rows)
}

func decodeGridSize(payload []byte) (cols, rows uint16, ok bool) {
	if len(payload) < 4 {
		return 0, 0, false
	}
	return binary.LittleEndian.Uint16(payload[0:]), binary.LittleEndian.Uint16(payload[2:]), true
}
