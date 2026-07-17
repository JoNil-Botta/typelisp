;; Explicit compressed compile-only inputs for embedded stdlib payload shard A.
(include-str-lzss payload-arena "../stdlib/arena.tl")

(include-str-lzss payload-atomic "../stdlib/atomic.tl")

(include-str-lzss payload-args "../stdlib/args.tl")

(include-str-lzss payload-array "../stdlib/array.tl")

(include-str-lzss payload-byte-buf "../stdlib/byte_buf.tl")

(include-str-lzss payload-byte-buf-core "../stdlib/byte_buf_core.tl")

(include-str-lzss payload-clone "../stdlib/clone.tl")