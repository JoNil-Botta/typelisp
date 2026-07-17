;; Explicit compressed compile-only inputs for embedded stdlib payload shard D.
(include-str-lzss payload-math "../stdlib/math.tl")

(include-str-lzss payload-msvc "../stdlib/msvc.tl")

(include-str-lzss payload-process "../stdlib/process.tl")

(include-str-lzss payload-process-borrowed "../stdlib/process_borrowed.tl")

(include-str-lzss payload-profile "../stdlib/profile.tl")

(include-str-lzss payload-queue "../stdlib/queue.tl")

(include-str-lzss payload-random "../stdlib/random.tl")