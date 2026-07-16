;; Explicit compressed compile-only inputs for embedded stdlib payload shard B.
(include-str-comptime-lzss payload-cpu "../stdlib/cpu.tl")

(include-str-comptime-lzss payload-comptime "../stdlib/comptime.tl")

(include-str-comptime-lzss payload-core-macros "../stdlib/core_macros.tl")

(include-str-comptime-lzss payload-env "../stdlib/env.tl")

(include-str-comptime-lzss payload-eq "../stdlib/eq.tl")

(include-str-comptime-lzss payload-ffi "../stdlib/ffi.tl")

(include-str-comptime-lzss payload-fs "../stdlib/fs.tl")