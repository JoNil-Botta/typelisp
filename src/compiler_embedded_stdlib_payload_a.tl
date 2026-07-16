;; Explicit compressed compile-only inputs for embedded stdlib payload shard A.
(include-str-comptime-lzss payload-arena "../stdlib/arena.tl")

(include-str-comptime-lzss payload-atomic "../stdlib/atomic.tl")

(include-str-comptime-lzss payload-args "../stdlib/args.tl")

(include-str-comptime-lzss payload-array "../stdlib/array.tl")

(include-str-comptime-lzss payload-byte-buf "../stdlib/byte_buf.tl")

(include-str-comptime-lzss payload-byte-buf-core "../stdlib/byte_buf_core.tl")

(include-str-comptime-lzss payload-clone "../stdlib/clone.tl")