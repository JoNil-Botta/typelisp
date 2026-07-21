;; Explicit compressed compile-only inputs for the embedded stdlib payload.
(import stdlib.string)

(include-str-lzss payload-arena "../stdlib/arena.tl")

(include-str-lzss payload-atomic "../stdlib/atomic.tl")

(include-str-lzss payload-args "../stdlib/args.tl")

(include-str-lzss payload-array "../stdlib/array.tl")

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

(include-str-lzss payload-vector-slice "../stdlib/vector_slice.tl")

(include-str-lzss payload-io-caller-result "../stdlib/io_caller_result.tl")

(include-str-lzss payload-option "../stdlib/option.tl")

(include-str-lzss payload-set "../stdlib/set.tl")

(include-str-lzss
  payload-string-caller-result
  "../stdlib/string_caller_result.tl")

(defenum CompilerEmbeddedStdlibPayload
  (CompilerEmbeddedStdlibPayloadNone)
  (CompilerEmbeddedStdlibPayloadSome (Array u8)))

(define (compiler-embedded-stdlib-payload-lookup [suffix : String]) : CompilerEmbeddedStdlibPayload
  (cond
    [(string.eq suffix "arena.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-arena)]
    [(string.eq suffix "atomic.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-atomic)]
    [(string.eq suffix "args.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-args)]
    [(string.eq suffix "array.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-array)]
    [(string.eq suffix "byte_buf.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-byte-buf)]
    [(string.eq suffix "byte_buf_core.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-byte-buf-core)]
    [(string.eq suffix "clone.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-clone)]
    [(string.eq suffix "cpu.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-cpu)]
    [(string.eq suffix "comptime.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-comptime)]
    [(string.eq suffix "core_macros.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-core-macros)]
    [(string.eq suffix "env.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-env)]
    [(string.eq suffix "eq.tl") (CompilerEmbeddedStdlibPayloadSome payload-eq)]
    [(string.eq suffix "ffi.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-ffi)]
    [(string.eq suffix "fs.tl") (CompilerEmbeddedStdlibPayloadSome payload-fs)]
    [(string.eq suffix "format.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-format)]
    [(string.eq suffix "hash.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-hash)]
    [(string.eq suffix "hashmap.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-hashmap)]
    [(string.eq suffix "io_core.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-io-core)]
    [(string.eq suffix "io.tl") (CompilerEmbeddedStdlibPayloadSome payload-io)]
    [(string.eq suffix "iterator.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-iterator)]
    [(string.eq suffix "json.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-json)]
    [(string.eq suffix "math.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-math)]
    [(string.eq suffix "msvc.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-msvc)]
    [(string.eq suffix "process.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-process)]
    [(string.eq suffix "process_borrowed.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-process-borrowed)]
    [(string.eq suffix "process_runtime.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-process-runtime)]
    [(string.eq suffix "profile.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-profile)]
    [(string.eq suffix "queue.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-queue)]
    [(string.eq suffix "random.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-random)]
    [(string.eq suffix "result.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-result)]
    [(string.eq suffix "runtime.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-runtime)]
    [(string.eq suffix "serialize.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-serialize)]
    [(string.eq suffix "sort.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-sort)]
    [(string.eq suffix "sync.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-sync)]
    [(string.eq suffix "string.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-string)]
    [(string.eq suffix "str_cat.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-str-cat)]
    [(string.eq suffix "str_cat_runtime.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-str-cat-runtime)]
    [(string.eq suffix "test.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-test)]
    [(string.eq suffix "thread.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-thread)]
    [(string.eq suffix "time.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-time)]
    [(string.eq suffix "text_buf.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-text-buf)]
    [(string.eq suffix "text_buf_borrowed.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-text-buf-borrowed)]
    [(string.eq suffix "text_buf_family.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-text-buf-family)]
    [(string.eq suffix "vector.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-vector)]
    [(string.eq suffix "vector_slice.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-vector-slice)]
    [(string.eq suffix "io_caller_result.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-io-caller-result)]
    [(string.eq suffix "option.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-option)]
    [(string.eq suffix "set.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-set)]
    [(string.eq suffix "string_caller_result.tl")
      (CompilerEmbeddedStdlibPayloadSome payload-string-caller-result)]
    [else (CompilerEmbeddedStdlibPayloadNone)]))