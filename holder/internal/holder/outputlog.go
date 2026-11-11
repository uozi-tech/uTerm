package holder

// OutputLog 是会话输出的环形缓冲：最近 capacity 字节，以及它们在整条输出流里的位置。
//
// 存储按需翻倍，安静的 shell 不占满容量。写满后原地覆盖，再大的洪水也不增长。
type OutputLog struct {
	capacity int
	storage  []byte
	// 整条输出流到目前为止的长度。
	end uint64
}

const defaultLogCapacity = 16 << 20

func NewOutputLog(capacity int) *OutputLog {
	if capacity < 1 {
		capacity = 1
	}
	return &OutputLog{capacity: capacity, storage: make([]byte, min(64<<10, capacity))}
}

func (l *OutputLog) EndOffset() uint64 { return l.end }

// StartOffset 是还留着的最早字节的位置。
func (l *OutputLog) StartOffset() uint64 {
	return l.end - min(l.end, uint64(len(l.storage)))
}

func (l *OutputLog) Append(data []byte) {
	if len(data) == 0 {
		return
	}
	l.grow(min(uint64(l.capacity), l.end+uint64(len(data))))
	// 只有最后 len(storage) 字节留得下。
	kept := data
	if len(kept) > len(l.storage) {
		kept = kept[len(kept)-len(l.storage):]
	}
	start := int((l.end + uint64(len(data)-len(kept))) % uint64(len(l.storage)))
	first := copy(l.storage[start:], kept)
	copy(l.storage, kept[first:])
	l.end += uint64(len(data))
}

// 存储还没到容量时环从没绕过（每次写之前都先长够），字节就从 0 开始放着，整段拷过去位置不变。
func (l *OutputLog) grow(needed uint64) {
	if uint64(len(l.storage)) >= needed {
		return
	}
	size := len(l.storage)
	for uint64(size) < needed {
		size = min(size*2, l.capacity)
	}
	grown := make([]byte, size)
	copy(grown, l.storage[:l.end])
	l.storage = grown
}

// Read 取 offset 开始最多 maxBytes 字节。offset 不在缓冲范围内时 ok 为 false。
// 比较在前、相减在后：offset 来自对端，不能让它算出溢出。
func (l *OutputLog) Read(offset uint64, maxBytes int) (data []byte, ok bool) {
	if offset < l.StartOffset() || offset > l.end {
		return nil, false
	}
	count := int(min(uint64(maxBytes), l.end-offset))
	out := make([]byte, count)
	start := int(offset % uint64(len(l.storage)))
	first := copy(out, l.storage[start:start+min(count, len(l.storage)-start)])
	copy(out[first:], l.storage)
	return out, true
}
