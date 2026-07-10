;; compiler_embedded_stdlib.tl - Checked-in stdlib source payloads.
(import stdlib.string)

(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

(define (embedded-eq? [left : String] [right : String]) : bool
  (string.eq left right))

(include-str compiler-embedded-stdlib-arena "stdlib/arena.tl")
(include-str compiler-embedded-stdlib-atomic "stdlib/atomic.tl")
(include-str compiler-embedded-stdlib-args "stdlib/args.tl")
(include-str compiler-embedded-stdlib-array "stdlib/array.tl")
(include-str compiler-embedded-stdlib-byte-buf "stdlib/byte_buf.tl")
(include-str compiler-embedded-stdlib-byte-buf-core "stdlib/byte_buf_core.tl")
(include-str compiler-embedded-stdlib-cpu "stdlib/cpu.tl")
(include-str compiler-embedded-stdlib-comptime "stdlib/comptime.tl")
(include-str compiler-embedded-stdlib-core-macros "stdlib/core_macros.tl")
(include-str compiler-embedded-stdlib-env "stdlib/env.tl")
(include-str compiler-embedded-stdlib-eq "stdlib/eq.tl")
(include-str compiler-embedded-stdlib-ffi "stdlib/ffi.tl")
(include-str compiler-embedded-stdlib-fs "stdlib/fs.tl")
(include-str compiler-embedded-stdlib-format "stdlib/format.tl")
(include-str compiler-embedded-stdlib-hash "stdlib/hash.tl")
(include-str compiler-embedded-stdlib-hashmap "stdlib/hashmap.tl")
(include-str compiler-embedded-stdlib-io-core "stdlib/io_core.tl")
(include-str compiler-embedded-stdlib-io "stdlib/io.tl")
(include-str compiler-embedded-stdlib-iterator "stdlib/iterator.tl")
(include-str compiler-embedded-stdlib-json "stdlib/json.tl")
(include-str compiler-embedded-stdlib-math "stdlib/math.tl")
(include-str compiler-embedded-stdlib-msvc "stdlib/msvc.tl")
(include-str compiler-embedded-stdlib-process "stdlib/process.tl")
(include-str compiler-embedded-stdlib-process-borrowed "stdlib/process_borrowed.tl")
(include-str compiler-embedded-stdlib-profile "stdlib/profile.tl")
(include-str compiler-embedded-stdlib-queue "stdlib/queue.tl")
(include-str compiler-embedded-stdlib-random "stdlib/random.tl")
(include-str compiler-embedded-stdlib-result "stdlib/result.tl")
(include-str compiler-embedded-stdlib-runtime "stdlib/runtime.tl")
(include-str compiler-embedded-stdlib-serialize "stdlib/serialize.tl")
(include-str compiler-embedded-stdlib-sort "stdlib/sort.tl")
(include-str compiler-embedded-stdlib-sync "stdlib/sync.tl")
(include-str compiler-embedded-stdlib-string "stdlib/string.tl")
(include-str compiler-embedded-stdlib-test "stdlib/test.tl")
(include-str compiler-embedded-stdlib-thread "stdlib/thread.tl")
(include-str compiler-embedded-stdlib-time "stdlib/time.tl")
(include-str compiler-embedded-stdlib-text-buf "stdlib/text_buf.tl")
(include-str compiler-embedded-stdlib-text-buf-borrowed "stdlib/text_buf_borrowed.tl")
(include-str compiler-embedded-stdlib-text-buf-family "stdlib/text_buf_family.tl")
(include-str compiler-embedded-stdlib-vector "stdlib/vector.tl")
(include-str compiler-embedded-stdlib-vector-slice "stdlib/vector_slice.tl")

(define (compiler-embedded-stdlib-lookup-modules [suffix : String]) : CompilerEmbeddedStdlibSource
  (cond
    [(embedded-eq? suffix "arena.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-arena)]
    [(embedded-eq? suffix "atomic.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-atomic)]
    [(embedded-eq? suffix "args.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-args)]
    [(embedded-eq? suffix "array.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-array)]
    [(embedded-eq? suffix "byte_buf.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-byte-buf)]
    [(embedded-eq? suffix "byte_buf_core.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-byte-buf-core)]
    [(embedded-eq? suffix "cpu.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-cpu)]
    [(embedded-eq? suffix "comptime.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-comptime)]
    [(embedded-eq? suffix "core_macros.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-core-macros)]
    [(embedded-eq? suffix "env.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-env)]
    [(embedded-eq? suffix "ffi.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-ffi)]
    [(embedded-eq? suffix "fs.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-fs)]
    [(embedded-eq? suffix "format.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-format)]
    [(embedded-eq? suffix "hash.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-hash)]
    [(embedded-eq? suffix "hashmap.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-hashmap)]
    [(embedded-eq? suffix "io_core.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-io-core)]
    [(embedded-eq? suffix "io.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-io)]
    [(embedded-eq? suffix "iterator.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-iterator)]
    [(embedded-eq? suffix "json.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-json)]
    [(embedded-eq? suffix "math.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-math)]
    [(embedded-eq? suffix "msvc.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-msvc)]
    [(embedded-eq? suffix "process.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-process)]
    [(embedded-eq? suffix "process_borrowed.tl")
      (CompilerEmbeddedStdlibSomeSource
        compiler-embedded-stdlib-process-borrowed)]
    [(embedded-eq? suffix "profile.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-profile)]
    [(embedded-eq? suffix "queue.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-queue)]
    [(embedded-eq? suffix "random.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-random)]
    [(embedded-eq? suffix "result.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-result)]
    [(embedded-eq? suffix "runtime.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-runtime)]
    [(embedded-eq? suffix "serialize.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-serialize)]
    [(embedded-eq? suffix "sort.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-sort)]
    [(embedded-eq? suffix "sync.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-sync)]
    [(embedded-eq? suffix "string.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-string)]
    [(embedded-eq? suffix "test.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-test)]
    [(embedded-eq? suffix "thread.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-thread)]
    [(embedded-eq? suffix "time.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-time)]
    [(embedded-eq? suffix "text_buf.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-text-buf)]
    [(embedded-eq? suffix "text_buf_borrowed.tl")
      (CompilerEmbeddedStdlibSomeSource
        compiler-embedded-stdlib-text-buf-borrowed)]
    [(embedded-eq? suffix "text_buf_family.tl")
      (CompilerEmbeddedStdlibSomeSource
        compiler-embedded-stdlib-text-buf-family)]
    [(embedded-eq? suffix "vector.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-vector)]
    [(embedded-eq? suffix "vector_slice.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-vector-slice)]
    [(embedded-eq? suffix "eq.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-eq)]
    [else (CompilerEmbeddedStdlibNoSource)]))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (compiler-embedded-stdlib-lookup-modules suffix))