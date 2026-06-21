;; compiler_embedded_stdlib.tl - Checked-in stdlib source payloads (#1509).
(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

(include-str compiler-embedded-stdlib-arena "stdlib/arena.tl")
(include-str compiler-embedded-stdlib-atomic "stdlib/atomic.tl")
(include-str compiler-embedded-stdlib-args "stdlib/args.tl")
(include-str compiler-embedded-stdlib-byte-buf "stdlib/byte_buf.tl")
(include-str compiler-embedded-stdlib-cpu "stdlib/cpu.tl")
(include-str compiler-embedded-stdlib-comptime "stdlib/comptime.tl")
(include-str compiler-embedded-stdlib-core-macros "stdlib/core_macros.tl")
(include-str compiler-embedded-stdlib-env "stdlib/env.tl")
(include-str compiler-embedded-stdlib-ffi "stdlib/ffi.tl")
(include-str compiler-embedded-stdlib-fs "stdlib/fs.tl")
(include-str compiler-embedded-stdlib-hash "stdlib/hash.tl")
(include-str compiler-embedded-stdlib-hashmap "stdlib/hashmap.tl")
(include-str compiler-embedded-stdlib-io "stdlib/io.tl")
(include-str compiler-embedded-stdlib-iterator "stdlib/iterator.tl")
(include-str compiler-embedded-stdlib-json "stdlib/json.tl")
(include-str compiler-embedded-stdlib-list "stdlib/list.tl")
(include-str compiler-embedded-stdlib-math "stdlib/math.tl")
(include-str compiler-embedded-stdlib-msvc "stdlib/msvc.tl")
(include-str compiler-embedded-stdlib-process "stdlib/process.tl")
(include-str compiler-embedded-stdlib-process-borrowed "stdlib/process_borrowed.tl")
(include-str compiler-embedded-stdlib-profile "stdlib/profile.tl")
(include-str compiler-embedded-stdlib-queue "stdlib/queue.tl")
(include-str compiler-embedded-stdlib-random "stdlib/random.tl")
(include-str compiler-embedded-stdlib-runtime "stdlib/runtime.tl")
(include-str compiler-embedded-stdlib-sort "stdlib/sort.tl")
(include-str compiler-embedded-stdlib-sync "stdlib/sync.tl")
(include-str compiler-embedded-stdlib-string "stdlib/string.tl")
(include-str compiler-embedded-stdlib-test "stdlib/test.tl")
(include-str compiler-embedded-stdlib-thread "stdlib/thread.tl")
(include-str compiler-embedded-stdlib-time "stdlib/time.tl")
(include-str compiler-embedded-stdlib-tests-arena-atomic-api "stdlib/tests/arena_atomic_api.tl")
(include-str compiler-embedded-stdlib-tests-arena-patterns "stdlib/tests/arena_patterns.tl")
(include-str compiler-embedded-stdlib-tests-arena-policy-escape-string "stdlib/tests/arena_policy_escape_string.tl")
(include-str compiler-embedded-stdlib-tests-arena-policy-escape-text-buf "stdlib/tests/arena_policy_escape_text_buf.tl")
(include-str compiler-embedded-stdlib-tests-arena-policy-escape-text-buf-borrowed "stdlib/tests/arena_policy_escape_text_buf_borrowed.tl")
(include-str compiler-embedded-stdlib-tests-byte-buf-api "stdlib/tests/byte_buf_api.tl")
(include-str compiler-embedded-stdlib-tests-cpu-api "stdlib/tests/cpu_api.tl")
(include-str compiler-embedded-stdlib-tests-core-macros-api "stdlib/tests/core_macros_api.tl")
(include-str compiler-embedded-stdlib-tests-comptime-api "stdlib/tests/comptime_api.tl")
(include-str compiler-embedded-stdlib-tests-hashmap-mut-borrow-insert-or-update-live "stdlib/tests/hashmap_mut_borrow_insert_or_update_live.tl")
(include-str compiler-embedded-stdlib-tests-io-stdio-bytes "stdlib/tests/io_stdio_bytes.tl")
(include-str compiler-embedded-stdlib-tests-io-stdio-lines "stdlib/tests/io_stdio_lines.tl")
(include-str compiler-embedded-stdlib-tests-io-stdio-pipe-short-read "stdlib/tests/io_stdio_pipe_short_read.tl")
(include-str compiler-embedded-stdlib-tests-list-api "stdlib/tests/list_api.tl")
(include-str compiler-embedded-stdlib-tests-msvc-api "stdlib/tests/msvc_api.tl")
(include-str compiler-embedded-stdlib-tests-process-api "stdlib/tests/process_api.tl")
(include-str compiler-embedded-stdlib-tests-process-borrowed-escape "stdlib/tests/process_borrowed_escape.tl")
(include-str compiler-embedded-stdlib-tests-process-runtime "stdlib/tests/process_runtime.tl")
(include-str compiler-embedded-stdlib-tests-profile-api "stdlib/tests/profile_api.tl")
(include-str compiler-embedded-stdlib-tests-sort-api "stdlib/tests/sort_api.tl")
(include-str compiler-embedded-stdlib-tests-sync-api "stdlib/tests/sync_api.tl")
(include-str compiler-embedded-stdlib-tests-string-edges "stdlib/tests/string_edges.tl")
(include-str compiler-embedded-stdlib-tests-test-assert-failure "stdlib/tests/test_assert_failure.tl")
(include-str compiler-embedded-stdlib-tests-time-api "stdlib/tests/time_api.tl")
(include-str compiler-embedded-stdlib-tests-text-buf-api "stdlib/tests/text_buf_api.tl")
(include-str compiler-embedded-stdlib-tests-vector-api "stdlib/tests/vector_api.tl")
(include-str compiler-embedded-stdlib-tests-vector-slice-escape "stdlib/tests/vector_slice_escape.tl")
(include-str compiler-embedded-stdlib-text-buf "stdlib/text_buf.tl")
(include-str compiler-embedded-stdlib-text-buf-borrowed "stdlib/text_buf_borrowed.tl")
(include-str compiler-embedded-stdlib-vector "stdlib/vector.tl")
(include-str compiler-embedded-stdlib-vector-family "stdlib/vector_family.tl")
(include-str compiler-embedded-stdlib-vector-slice "stdlib/vector_slice.tl")

(define (compiler-embedded-stdlib-lookup-modules [suffix : String]) : CompilerEmbeddedStdlibSource
  (cond
    [(string-eq suffix "arena.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-arena)]
    [(string-eq suffix "atomic.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-atomic)]
    [(string-eq suffix "args.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-args)]
    [(string-eq suffix "byte_buf.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-byte-buf)]
    [(string-eq suffix "cpu.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-cpu)]
    [(string-eq suffix "comptime.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-comptime)]
    [(string-eq suffix "core_macros.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-core-macros)]
    [(string-eq suffix "env.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-env)]
    [(string-eq suffix "ffi.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-ffi)]
    [(string-eq suffix "fs.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-fs)]
    [(string-eq suffix "hash.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-hash)]
    [(string-eq suffix "hashmap.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-hashmap)]
    [(string-eq suffix "io.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-io)]
    [(string-eq suffix "iterator.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-iterator)]
    [(string-eq suffix "json.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-json)]
    [(string-eq suffix "list.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-list)]
    [(string-eq suffix "math.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-math)]
    [(string-eq suffix "msvc.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-msvc)]
    [(string-eq suffix "process.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-process)]
    [(string-eq suffix "process_borrowed.tl")
      (CompilerEmbeddedStdlibSomeSource
        compiler-embedded-stdlib-process-borrowed)]
    [(string-eq suffix "profile.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-profile)]
    [(string-eq suffix "queue.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-queue)]
    [(string-eq suffix "random.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-random)]
    [(string-eq suffix "runtime.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-runtime)]
    [(string-eq suffix "sort.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-sort)]
    [(string-eq suffix "sync.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-sync)]
    [(string-eq suffix "string.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-string)]
    [(string-eq suffix "test.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-test)]
    [(string-eq suffix "thread.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-thread)]
    [(string-eq suffix "time.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-time)]
    [(string-eq suffix "text_buf.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-text-buf)]
    [(string-eq suffix "text_buf_borrowed.tl")
      (CompilerEmbeddedStdlibSomeSource
        compiler-embedded-stdlib-text-buf-borrowed)]
    [(string-eq suffix "vector.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-vector)]
    [(string-eq suffix "vector_family.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-vector-family)]
    [(string-eq suffix "vector_slice.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-vector-slice)]
    [else (CompilerEmbeddedStdlibNoSource)]))

(define (compiler-embedded-stdlib-lookup-tests [suffix : String]) : CompilerEmbeddedStdlibSource
  (let
    [source : CompilerEmbeddedStdlibSource (CompilerEmbeddedStdlibNoSource)]
    (begin
      (if (string-eq suffix "tests/arena_atomic_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-arena-atomic-api))
        unit)
      (if (string-eq suffix "tests/arena_patterns.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-arena-patterns))
        unit)
      (if (string-eq suffix "tests/arena_policy_escape_string.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-arena-policy-escape-string))
        unit)
      (if (string-eq suffix "tests/arena_policy_escape_text_buf.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-arena-policy-escape-text-buf))
        unit)
      (if (string-eq suffix "tests/arena_policy_escape_text_buf_borrowed.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-arena-policy-escape-text-buf-borrowed))
        unit)
      (if (string-eq suffix "tests/byte_buf_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-byte-buf-api))
        unit)
      (if (string-eq suffix "tests/cpu_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-cpu-api))
        unit)
      (if (string-eq suffix "tests/comptime_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-comptime-api))
        unit)
      (if (string-eq suffix "tests/core_macros_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-core-macros-api))
        unit)
      (if (string-eq suffix "tests/hashmap_mut_borrow_insert_or_update_live.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-hashmap-mut-borrow-insert-or-update-live))
        unit)
      (if (string-eq suffix "tests/io_stdio_bytes.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-io-stdio-bytes))
        unit)
      (if (string-eq suffix "tests/io_stdio_lines.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-io-stdio-lines))
        unit)
      (if (string-eq suffix "tests/io_stdio_pipe_short_read.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-io-stdio-pipe-short-read))
        unit)
      (if (string-eq suffix "tests/list_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-list-api))
        unit)
      (if (string-eq suffix "tests/msvc_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-msvc-api))
        unit)
      (if (string-eq suffix "tests/process_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-process-api))
        unit)
      (if (string-eq suffix "tests/process_borrowed_escape.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-process-borrowed-escape))
        unit)
      (if (string-eq suffix "tests/process_runtime.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-process-runtime))
        unit)
      (if (string-eq suffix "tests/profile_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-profile-api))
        unit)
      (if (string-eq suffix "tests/sort_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-sort-api))
        unit)
      (if (string-eq suffix "tests/sync_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-sync-api))
        unit)
      (if (string-eq suffix "tests/string_edges.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-string-edges))
        unit)
      (if (string-eq suffix "tests/test_assert_failure.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-test-assert-failure))
        unit)
      (if (string-eq suffix "tests/time_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-time-api))
        unit)
      (if (string-eq suffix "tests/text_buf_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-text-buf-api))
        unit)
      (if (string-eq suffix "tests/vector_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-vector-api))
        unit)
      (if (string-eq suffix "tests/vector_slice_escape.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-vector-slice-escape))
        unit)
      source)))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (match (compiler-embedded-stdlib-lookup-modules suffix)
    [(CompilerEmbeddedStdlibSomeSource source)
      (CompilerEmbeddedStdlibSomeSource source)]
    [(CompilerEmbeddedStdlibNoSource)
      (compiler-embedded-stdlib-lookup-tests suffix)]))