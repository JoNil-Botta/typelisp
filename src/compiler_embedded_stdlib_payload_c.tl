;; Explicit compressed compile-only inputs for embedded stdlib payload shard C.
(include-str-lzss payload-format "../stdlib/format.tl")

(include-str-lzss payload-hash "../stdlib/hash.tl")

(include-str-lzss payload-hashmap "../stdlib/hashmap.tl")

(include-str-lzss payload-io-core "../stdlib/io_core.tl")

(include-str-lzss payload-io "../stdlib/io.tl")

(include-str-lzss payload-iterator "../stdlib/iterator.tl")

(include-str-lzss payload-json "../stdlib/json.tl")