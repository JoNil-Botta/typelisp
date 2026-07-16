;; Explicit compressed compile-only inputs for embedded stdlib payload shard E.
(include-str-comptime-lzss payload-result "../stdlib/result.tl")

(include-str-comptime-lzss payload-runtime "../stdlib/runtime.tl")

(include-str-comptime-lzss payload-serialize "../stdlib/serialize.tl")

(include-str-comptime-lzss payload-sort "../stdlib/sort.tl")

(include-str-comptime-lzss payload-sync "../stdlib/sync.tl")

(include-str-comptime-lzss payload-string "../stdlib/string.tl")

(include-str-comptime-lzss payload-test "../stdlib/test.tl")