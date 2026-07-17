;; Explicit compressed compile-only inputs for embedded stdlib payload shard B.
(include-str-lzss payload-cpu "../stdlib/cpu.tl")

(include-str-lzss payload-comptime "../stdlib/comptime.tl")

(include-str-lzss payload-core-macros "../stdlib/core_macros.tl")

(include-str-lzss payload-env "../stdlib/env.tl")

(include-str-lzss payload-eq "../stdlib/eq.tl")

(include-str-lzss payload-ffi "../stdlib/ffi.tl")

(include-str-lzss payload-fs "../stdlib/fs.tl")