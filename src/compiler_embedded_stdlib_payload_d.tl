;; Explicit compressed compile-only inputs for embedded stdlib payload shard D.
(include-str-comptime-lzss payload-math "../stdlib/math.tl")

(include-str-comptime-lzss payload-msvc "../stdlib/msvc.tl")

(include-str-comptime-lzss payload-process "../stdlib/process.tl")

(include-str-comptime-lzss
  payload-process-borrowed
  "../stdlib/process_borrowed.tl")

(include-str-comptime-lzss payload-profile "../stdlib/profile.tl")

(include-str-comptime-lzss payload-queue "../stdlib/queue.tl")

(include-str-comptime-lzss payload-random "../stdlib/random.tl")