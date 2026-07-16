;; Explicit compressed compile-only inputs for embedded stdlib payload shard F.
(include-str-comptime-lzss payload-thread "../stdlib/thread.tl")

(include-str-comptime-lzss payload-time "../stdlib/time.tl")

(include-str-comptime-lzss payload-text-buf "../stdlib/text_buf.tl")

(include-str-comptime-lzss
  payload-text-buf-borrowed
  "../stdlib/text_buf_borrowed.tl")

(include-str-comptime-lzss
  payload-text-buf-family
  "../stdlib/text_buf_family.tl")

(include-str-comptime-lzss payload-vector "../stdlib/vector.tl")

(include-str-comptime-lzss payload-vector-slice "../stdlib/vector_slice.tl")