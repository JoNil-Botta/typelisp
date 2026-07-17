;; Explicit compressed compile-only inputs for embedded stdlib payload shard E.
(include-str-lzss payload-result "../stdlib/result.tl")

(include-str-lzss payload-runtime "../stdlib/runtime.tl")

(include-str-lzss payload-serialize "../stdlib/serialize.tl")

(include-str-lzss payload-sort "../stdlib/sort.tl")

(include-str-lzss payload-sync "../stdlib/sync.tl")

(include-str-lzss payload-string "../stdlib/string.tl")

(include-str-lzss payload-test "../stdlib/test.tl")