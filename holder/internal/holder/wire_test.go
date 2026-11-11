package holder

import (
	"bytes"
	"io"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	var stream []byte
	stream = AppendFrame(stream, KindInput, []byte("ls\n"))
	stream = AppendFrame(stream, KindAttach, nil)
	// 不认识的类型也要能读出来，由上层忽略。
	stream = AppendFrame(stream, Kind(250), []byte{1, 2, 3})
	reader := bytes.NewReader(stream)

	for _, want := range []Frame{{KindInput, []byte("ls\n")}, {KindAttach, []byte{}}, {Kind(250), []byte{1, 2, 3}}} {
		got, err := ReadFrame(reader)
		if err != nil || got.Kind != want.Kind || !bytes.Equal(got.Payload, want.Payload) {
			t.Fatalf("got %+v (%v), want %+v", got, err, want)
		}
	}
	if _, err := ReadFrame(reader); err != io.EOF {
		t.Fatalf("want EOF, got %v", err)
	}
}

func TestFrameRejectsBadLength(t *testing.T) {
	if _, err := ReadFrame(bytes.NewReader([]byte{0, 0, 0, 0, 1})); err == nil {
		t.Fatal("zero length accepted")
	}
	if _, err := ReadFrame(bytes.NewReader([]byte{0xff, 0xff, 0xff, 0xff, 1})); err != errFrameTooLarge {
		t.Fatalf("oversized frame: %v", err)
	}
	if _, err := ReadFrame(bytes.NewReader([]byte{5, 0, 0, 0, 3, 'a'})); err != io.ErrUnexpectedEOF {
		t.Fatalf("truncated frame: %v", err)
	}
}

// 字节布局要和 Mac 上的 HolderWire.swift 一致：App 两头用同一份解码。
func TestHelloReplyLayout(t *testing.T) {
	status := int32(256)
	encoded := HelloReply{
		Version: 1, ShellPID: 0x01020304, CreatedAt: 0x1122334455667788, Cols: 80, Rows: 24,
		ExitStatus: &status, Attributes: []byte("attr"),
	}.Encode()
	want := []byte{
		1, 0, 0, 0,
		4, 3, 2, 1,
		0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
		80, 0, 24, 0,
		1,
		0, 1, 0, 0,
		'a', 't', 't', 'r',
	}
	if !bytes.Equal(encoded, want) {
		t.Fatalf("layout differs:\n got %v\nwant %v", encoded, want)
	}
	decoded, ok := DecodeHelloReply(encoded)
	if !ok || decoded.ShellPID != 0x01020304 || *decoded.ExitStatus != 256 || string(decoded.Attributes) != "attr" {
		t.Fatalf("decoded %+v ok=%v", decoded, ok)
	}
	running, ok := DecodeHelloReply(HelloReply{Version: 1}.Encode())
	if !ok || running.ExitStatus != nil {
		t.Fatalf("running session decoded as exited: %+v", running)
	}
	if _, ok := DecodeHelloReply(encoded[:20]); ok {
		t.Fatal("short hello reply accepted")
	}
}

func TestCheckpointLayout(t *testing.T) {
	encoded := Checkpoint{Offset: 0x0102030405060708, Cols: 120, Rows: 40, HasGap: true, Blob: []byte("blob")}.Encode()
	want := []byte{8, 7, 6, 5, 4, 3, 2, 1, 120, 0, 40, 0, 1, 'b', 'l', 'o', 'b'}
	if !bytes.Equal(encoded, want) {
		t.Fatalf("layout differs:\n got %v\nwant %v", encoded, want)
	}
	decoded, ok := DecodeCheckpoint(encoded)
	if !ok || decoded.Offset != 0x0102030405060708 || !decoded.HasGap || string(decoded.Blob) != "blob" {
		t.Fatalf("decoded %+v ok=%v", decoded, ok)
	}
	if _, ok := DecodeCheckpoint(encoded[:12]); ok {
		t.Fatal("short checkpoint accepted")
	}
}

func TestAttachOffsetPayload(t *testing.T) {
	offset, ok := decodeAttachOffset(EncodeAttachFromOffset(1 << 40))
	if !ok || offset != 1<<40 {
		t.Fatalf("offset %d ok=%v", offset, ok)
	}
	if _, ok := decodeAttachOffset(nil); ok {
		t.Fatal("empty payload decoded as an offset")
	}
	if _, ok := decodeAttachOffset([]byte{2, 0, 0, 0, 0, 0, 0, 0, 0}); ok {
		t.Fatal("unknown attach mode accepted")
	}
}
