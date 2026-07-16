;; Explicit compressed compile-only inputs for embedded stdlib payload shard C.
(include-str-comptime-lzss payload-format "../stdlib/format.tl")

(include-str-comptime-lzss payload-hash "../stdlib/hash.tl")

(include-str-comptime-lzss payload-hashmap "../stdlib/hashmap.tl")

(include-str-comptime-lzss payload-io-core "../stdlib/io_core.tl")

(include-str-comptime-lzss payload-io "../stdlib/io.tl")

(include-str-comptime-lzss payload-iterator "../stdlib/iterator.tl")

(include-str-comptime-lzss payload-json "../stdlib/json.tl")