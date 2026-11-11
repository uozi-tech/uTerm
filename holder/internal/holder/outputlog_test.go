package holder

import (
	"bytes"
	"math/rand"
	"testing"
)

// 和「整条流都留着」的参考实现对照：留着的那一段逐字节相同，范围外的读不到。
func TestOutputLogMatchesReferenceStream(t *testing.T) {
	random := rand.New(rand.NewSource(1))
	for _, capacity := range []int{1, 7, 64 << 10, 100_000, 1 << 20} {
		log := NewOutputLog(capacity)
		var stream []byte
		for round := 0; round < 400; round++ {
			chunk := make([]byte, random.Intn(3*capacity/2+2))
			random.Read(chunk)
			log.Append(chunk)
			stream = append(stream, chunk...)

			if log.EndOffset() != uint64(len(stream)) {
				t.Fatalf("capacity %d: end %d, want %d", capacity, log.EndOffset(), len(stream))
			}
			start := log.StartOffset()
			if kept := uint64(len(stream)) - start; kept > uint64(capacity) {
				t.Fatalf("capacity %d: keeps %d bytes", capacity, kept)
			}
			offset := start + uint64(random.Int63n(int64(uint64(len(stream))-start)+1))
			got, ok := log.Read(offset, capacity+10)
			if !ok || !bytes.Equal(got, stream[offset:]) {
				t.Fatalf("capacity %d round %d: read from %d differs (ok=%v, %d bytes, want %d)",
					capacity, round, offset, ok, len(got), len(stream)-int(offset))
			}
			if start > 0 {
				if _, ok := log.Read(start-1, 1); ok {
					t.Fatalf("capacity %d: read before start succeeded", capacity)
				}
			}
			if _, ok := log.Read(log.EndOffset()+1, 1); ok {
				t.Fatalf("capacity %d: read past end succeeded", capacity)
			}
		}
	}
}

func TestOutputLogReadHonoursMaxBytes(t *testing.T) {
	log := NewOutputLog(1024)
	log.Append(bytes.Repeat([]byte("abcdefgh"), 500))
	got, ok := log.Read(log.StartOffset()+3, 10)
	if !ok || len(got) != 10 {
		t.Fatalf("got %d bytes, ok=%v", len(got), ok)
	}
	end, ok := log.Read(log.EndOffset(), 10)
	if !ok || len(end) != 0 {
		t.Fatalf("read at end: %d bytes, ok=%v", len(end), ok)
	}
}
