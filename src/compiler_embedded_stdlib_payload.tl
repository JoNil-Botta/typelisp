;; Explicit compressed compile-only inputs for the embedded stdlib payload.
(import stdlib.string)

(include-str-lzss payload-arena "../stdlib/arena.tl")

(include-str-lzss payload-atomic "../stdlib/atomic.tl")

(include-str-lzss payload-args "../stdlib/args.tl")

(include-str-lzss payload-byte-buf "../stdlib/byte_buf.tl")

(include-str-lzss payload-byte-buf-core "../stdlib/byte_buf_core.tl")

(include-str-lzss payload-clone "../stdlib/clone.tl")

(include-str-lzss payload-cpu "../stdlib/cpu.tl")

(include-str-lzss payload-comptime "../stdlib/comptime.tl")

(include-str-lzss payload-core-macros "../stdlib/core_macros.tl")

(include-str-lzss payload-env "../stdlib/env.tl")

(include-str-lzss payload-eq "../stdlib/eq.tl")

(include-str-lzss payload-ffi "../stdlib/ffi.tl")

(include-str-lzss payload-fs "../stdlib/fs.tl")

(include-str-lzss payload-format "../stdlib/format.tl")

(include-str-lzss payload-hash "../stdlib/hash.tl")

(include-str-lzss payload-hashmap "../stdlib/hashmap.tl")

(include-str-lzss
  payload-net-http-head-codec
  "../stdlib/net/http_head_codec.tl")

(include-str-lzss
  payload-net-http-trailer-policy
  "../stdlib/net/http_trailer_policy.tl")

(include-str-lzss payload-net-http-types "../stdlib/net/http_types.tl")

(include-str-lzss payload-net-ip "../stdlib/net/ip.tl")

(include-str-lzss payload-io-core "../stdlib/io_core.tl")

(include-str-lzss payload-io "../stdlib/io.tl")

(include-str-lzss payload-iterator "../stdlib/iterator.tl")

(include-str-lzss payload-json "../stdlib/json.tl")

(include-str-lzss payload-math "../stdlib/math.tl")

(include-str-lzss payload-msvc "../stdlib/msvc.tl")

(include-str-lzss payload-process "../stdlib/process.tl")

(include-str-lzss payload-process-borrowed "../stdlib/process_borrowed.tl")

(include-str-lzss payload-process-runtime "../stdlib/process_runtime.tl")

(include-str-lzss payload-profile "../stdlib/profile.tl")

(include-str-lzss payload-queue "../stdlib/queue.tl")

(include-str-lzss payload-random "../stdlib/random.tl")

(include-str-lzss payload-result "../stdlib/result.tl")

(include-str-lzss payload-runtime "../stdlib/runtime.tl")

(include-str-lzss payload-serialize "../stdlib/serialize.tl")

(include-str-lzss payload-sort "../stdlib/sort.tl")

(include-str-lzss payload-sync "../stdlib/sync.tl")

(include-str-lzss payload-string "../stdlib/string.tl")

(include-str-lzss payload-str-cat "../stdlib/str_cat.tl")

(include-str-lzss payload-str-cat-runtime "../stdlib/str_cat_runtime.tl")

(include-str-lzss payload-test "../stdlib/test.tl")

(include-str-lzss payload-thread "../stdlib/thread.tl")

(include-str-lzss payload-time "../stdlib/time.tl")

(include-str-lzss payload-text-buf "../stdlib/text_buf.tl")

(include-str-lzss payload-text-buf-borrowed "../stdlib/text_buf_borrowed.tl")

(include-str-lzss payload-text-buf-family "../stdlib/text_buf_family.tl")

(include-str-lzss payload-vector "../stdlib/vector.tl")

(include-str-lzss payload-io-caller-result "../stdlib/io_caller_result.tl")

(include-str-lzss payload-option "../stdlib/option.tl")

(include-str-lzss payload-set "../stdlib/set.tl")

(include-str-lzss
  payload-string-caller-result
  "../stdlib/string_caller_result.tl")

(defenum CompilerEmbeddedStdlibPayload
  (CompilerEmbeddedStdlibPayloadNone)
  (CompilerEmbeddedStdlibPayloadSome (__tl_dyn-array u8)))

;; Embedded compressed buffers are immutable process-lifetime storage. Decoding
;; allocates the uncompressed source independently, so copying every compressed
;; byte here only adds transient work. Stage0 keeps its historical shallow read;
;; the current compiler makes that same permanent-storage view explicit.
(defmacro (compiler-embedded-stdlib-payload-copy [payload : Expr]) : CompilerEmbeddedStdlibPayload
  (cfg
    stage0-seed-bootstrap
    `(CompilerEmbeddedStdlibPayloadSome ,payload)
    `(CompilerEmbeddedStdlibPayloadSome
      (unsafe
        (ptr-read (ptr-addr-of ,payload))))))

(define (compiler-embedded-stdlib-payload-lookup [suffix : String]) : CompilerEmbeddedStdlibPayload
  (cond
    [(string.eq suffix "arena.tl")
      (compiler-embedded-stdlib-payload-copy payload-arena)]
    [(string.eq suffix "atomic.tl")
      (compiler-embedded-stdlib-payload-copy payload-atomic)]
    [(string.eq suffix "args.tl")
      (compiler-embedded-stdlib-payload-copy payload-args)]
    [(string.eq suffix "byte_buf.tl")
      (compiler-embedded-stdlib-payload-copy payload-byte-buf)]
    [(string.eq suffix "byte_buf_core.tl")
      (compiler-embedded-stdlib-payload-copy payload-byte-buf-core)]
    [(string.eq suffix "clone.tl")
      (compiler-embedded-stdlib-payload-copy payload-clone)]
    [(string.eq suffix "cpu.tl")
      (compiler-embedded-stdlib-payload-copy payload-cpu)]
    [(string.eq suffix "comptime.tl")
      (compiler-embedded-stdlib-payload-copy payload-comptime)]
    [(string.eq suffix "core_macros.tl")
      (compiler-embedded-stdlib-payload-copy payload-core-macros)]
    [(string.eq suffix "env.tl")
      (compiler-embedded-stdlib-payload-copy payload-env)]
    [(string.eq suffix "eq.tl")
      (compiler-embedded-stdlib-payload-copy payload-eq)]
    [(string.eq suffix "ffi.tl")
      (compiler-embedded-stdlib-payload-copy payload-ffi)]
    [(string.eq suffix "fs.tl")
      (compiler-embedded-stdlib-payload-copy payload-fs)]
    [(string.eq suffix "format.tl")
      (compiler-embedded-stdlib-payload-copy payload-format)]
    [(string.eq suffix "hash.tl")
      (compiler-embedded-stdlib-payload-copy payload-hash)]
    [(string.eq suffix "hashmap.tl")
      (compiler-embedded-stdlib-payload-copy payload-hashmap)]
    [(string.eq suffix "net/http_head_codec.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-http-head-codec)]
    [(string.eq suffix "net/http_trailer_policy.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-http-trailer-policy)]
    [(string.eq suffix "net/http_types.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-http-types)]
    [(string.eq suffix "net/ip.tl")
      (compiler-embedded-stdlib-payload-copy payload-net-ip)]
    [(string.eq suffix "io_core.tl")
      (compiler-embedded-stdlib-payload-copy payload-io-core)]
    [(string.eq suffix "io.tl")
      (compiler-embedded-stdlib-payload-copy payload-io)]
    [(string.eq suffix "iterator.tl")
      (compiler-embedded-stdlib-payload-copy payload-iterator)]
    [(string.eq suffix "json.tl")
      (compiler-embedded-stdlib-payload-copy payload-json)]
    [(string.eq suffix "math.tl")
      (compiler-embedded-stdlib-payload-copy payload-math)]
    [(string.eq suffix "msvc.tl")
      (compiler-embedded-stdlib-payload-copy payload-msvc)]
    [(string.eq suffix "process.tl")
      (compiler-embedded-stdlib-payload-copy payload-process)]
    [(string.eq suffix "process_borrowed.tl")
      (compiler-embedded-stdlib-payload-copy payload-process-borrowed)]
    [(string.eq suffix "process_runtime.tl")
      (compiler-embedded-stdlib-payload-copy payload-process-runtime)]
    [(string.eq suffix "profile.tl")
      (compiler-embedded-stdlib-payload-copy payload-profile)]
    [(string.eq suffix "queue.tl")
      (compiler-embedded-stdlib-payload-copy payload-queue)]
    [(string.eq suffix "random.tl")
      (compiler-embedded-stdlib-payload-copy payload-random)]
    [(string.eq suffix "result.tl")
      (compiler-embedded-stdlib-payload-copy payload-result)]
    [(string.eq suffix "runtime.tl")
      (compiler-embedded-stdlib-payload-copy payload-runtime)]
    [(string.eq suffix "serialize.tl")
      (compiler-embedded-stdlib-payload-copy payload-serialize)]
    [(string.eq suffix "sort.tl")
      (compiler-embedded-stdlib-payload-copy payload-sort)]
    [(string.eq suffix "sync.tl")
      (compiler-embedded-stdlib-payload-copy payload-sync)]
    [(string.eq suffix "string.tl")
      (compiler-embedded-stdlib-payload-copy payload-string)]
    [(string.eq suffix "str_cat.tl")
      (compiler-embedded-stdlib-payload-copy payload-str-cat)]
    [(string.eq suffix "str_cat_runtime.tl")
      (compiler-embedded-stdlib-payload-copy payload-str-cat-runtime)]
    [(string.eq suffix "test.tl")
      (compiler-embedded-stdlib-payload-copy payload-test)]
    [(string.eq suffix "thread.tl")
      (compiler-embedded-stdlib-payload-copy payload-thread)]
    [(string.eq suffix "time.tl")
      (compiler-embedded-stdlib-payload-copy payload-time)]
    [(string.eq suffix "text_buf.tl")
      (compiler-embedded-stdlib-payload-copy payload-text-buf)]
    [(string.eq suffix "text_buf_borrowed.tl")
      (compiler-embedded-stdlib-payload-copy payload-text-buf-borrowed)]
    [(string.eq suffix "text_buf_family.tl")
      (compiler-embedded-stdlib-payload-copy payload-text-buf-family)]
    [(string.eq suffix "vector.tl")
      (compiler-embedded-stdlib-payload-copy payload-vector)]
    [(string.eq suffix "io_caller_result.tl")
      (compiler-embedded-stdlib-payload-copy payload-io-caller-result)]
    [(string.eq suffix "option.tl")
      (compiler-embedded-stdlib-payload-copy payload-option)]
    [(string.eq suffix "set.tl")
      (compiler-embedded-stdlib-payload-copy payload-set)]
    [(string.eq suffix "string_caller_result.tl")
      (compiler-embedded-stdlib-payload-copy payload-string-caller-result)]
    [else (CompilerEmbeddedStdlibPayloadNone)]))