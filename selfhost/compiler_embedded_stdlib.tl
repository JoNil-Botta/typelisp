;; compiler_embedded_stdlib.tl - Checked-in stdlib source payloads (#1509).
(import "../stdlib/core_macros.tl" module stdlib.core-macros as core)

(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

(include-str compiler-embedded-stdlib-arena "stdlib/arena.tl")

(include-str compiler-embedded-stdlib-args "stdlib/args.tl")

(include-str compiler-embedded-stdlib-cpu "stdlib/cpu.tl")

(include-str compiler-embedded-stdlib-core-macros "stdlib/core_macros.tl")

(include-str compiler-embedded-stdlib-env "stdlib/env.tl")

(include-str compiler-embedded-stdlib-ffi "stdlib/ffi.tl")

(include-str compiler-embedded-stdlib-fs "stdlib/fs.tl")

(include-str compiler-embedded-stdlib-hash "stdlib/hash.tl")

(include-str compiler-embedded-stdlib-hashmap "stdlib/hashmap.tl")

(include-str compiler-embedded-stdlib-io "stdlib/io.tl")

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

(include-str compiler-embedded-stdlib-string "stdlib/string.tl")

(include-str compiler-embedded-stdlib-test "stdlib/test.tl")

(include-str compiler-embedded-stdlib-thread "stdlib/thread.tl")

(include-str compiler-embedded-stdlib-tests-arena-api "stdlib/tests/arena_api.tl")

(include-str compiler-embedded-stdlib-tests-arena-patterns "stdlib/tests/arena_patterns.tl")

(include-str compiler-embedded-stdlib-tests-arena-policy "stdlib/tests/arena_policy.tl")

(include-str compiler-embedded-stdlib-tests-arena-policy-escape-string "stdlib/tests/arena_policy_escape_string.tl")

(include-str compiler-embedded-stdlib-tests-arena-policy-escape-text-buf "stdlib/tests/arena_policy_escape_text_buf.tl")

(include-str compiler-embedded-stdlib-tests-arena-policy-escape-text-buf-borrowed "stdlib/tests/arena_policy_escape_text_buf_borrowed.tl")

(include-str compiler-embedded-stdlib-tests-args-api "stdlib/tests/args_api.tl")

(include-str compiler-embedded-stdlib-tests-borrowed-str-gate "stdlib/tests/borrowed_str_gate.tl")

(include-str compiler-embedded-stdlib-tests-cpu-api "stdlib/tests/cpu_api.tl")

(include-str compiler-embedded-stdlib-tests-core-macros-api "stdlib/tests/core_macros_api.tl")

(include-str compiler-embedded-stdlib-tests-env-api "stdlib/tests/env_api.tl")

(include-str compiler-embedded-stdlib-tests-ffi-api "stdlib/tests/ffi_api.tl")

(include-str compiler-embedded-stdlib-tests-fs-api "stdlib/tests/fs_api.tl")

(include-str compiler-embedded-stdlib-tests-fs-path-join-many-api "stdlib/tests/fs_path_join_many_api.tl")

(include-str compiler-embedded-stdlib-tests-hash-api "stdlib/tests/hash_api.tl")

(include-str compiler-embedded-stdlib-tests-hashmap-api "stdlib/tests/hashmap_api.tl")

(include-str compiler-embedded-stdlib-tests-hashmap-mut-borrow-insert-or-update-live "stdlib/tests/hashmap_mut_borrow_insert_or_update_live.tl")

(include-str compiler-embedded-stdlib-tests-io-edges "stdlib/tests/io_edges.tl")

(include-str compiler-embedded-stdlib-tests-io-file-handle "stdlib/tests/io_file_handle.tl")

(include-str compiler-embedded-stdlib-tests-io-stdio-bytes "stdlib/tests/io_stdio_bytes.tl")

(include-str compiler-embedded-stdlib-tests-io-stdio-lines "stdlib/tests/io_stdio_lines.tl")

(include-str compiler-embedded-stdlib-tests-io-stdio-pipe-short-read "stdlib/tests/io_stdio_pipe_short_read.tl")

(include-str compiler-embedded-stdlib-tests-json-helpers "stdlib/tests/json_helpers.tl")

(include-str compiler-embedded-stdlib-tests-json-parse-stringify "stdlib/tests/json_parse_stringify.tl")

(include-str compiler-embedded-stdlib-tests-list-api "stdlib/tests/list_api.tl")

(include-str compiler-embedded-stdlib-tests-math-api "stdlib/tests/math_api.tl")

(include-str compiler-embedded-stdlib-tests-process-api "stdlib/tests/process_api.tl")

(include-str compiler-embedded-stdlib-tests-process-borrowed-check "stdlib/tests/process_borrowed_check.tl")

(include-str compiler-embedded-stdlib-tests-process-borrowed-escape "stdlib/tests/process_borrowed_escape.tl")

(include-str compiler-embedded-stdlib-tests-process-runtime "stdlib/tests/process_runtime.tl")

(include-str compiler-embedded-stdlib-tests-profile-api "stdlib/tests/profile_api.tl")

(include-str compiler-embedded-stdlib-tests-queue-api "stdlib/tests/queue_api.tl")

(include-str compiler-embedded-stdlib-tests-random-api "stdlib/tests/random_api.tl")

(include-str compiler-embedded-stdlib-tests-string-edges "stdlib/tests/string_edges.tl")

(include-str compiler-embedded-stdlib-tests-test-assert-failure "stdlib/tests/test_assert_failure.tl")

(include-str compiler-embedded-stdlib-tests-test-assert-success "stdlib/tests/test_assert_success.tl")

(include-str compiler-embedded-stdlib-tests-text-buf-api "stdlib/tests/text_buf_api.tl")

(include-str compiler-embedded-stdlib-tests-text-buf-borrowed-check "stdlib/tests/text_buf_borrowed_check.tl")

(include-str compiler-embedded-stdlib-tests-vector-api "stdlib/tests/vector_api.tl")

(include-str compiler-embedded-stdlib-text-buf "stdlib/text_buf.tl")

(include-str compiler-embedded-stdlib-text-buf-borrowed "stdlib/text_buf_borrowed.tl")

(include-str compiler-embedded-stdlib-vector "stdlib/vector.tl")

(define (compiler-embedded-stdlib-lookup-modules [suffix : String]) : CompilerEmbeddedStdlibSource
  (core/cond
    (string-eq suffix "arena.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-arena)
    (string-eq suffix "args.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-args)
    (string-eq suffix "cpu.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-cpu)
    (string-eq suffix "core_macros.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-core-macros)
    (string-eq suffix "env.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-env)
    (string-eq suffix "ffi.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-ffi)
    (string-eq suffix "fs.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-fs)
    (string-eq suffix "hash.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-hash)
    (string-eq suffix "hashmap.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-hashmap)
    (string-eq suffix "io.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-io)
    (string-eq suffix "json.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-json)
    (string-eq suffix "list.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-list)
    (string-eq suffix "math.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-math)
    (string-eq suffix "msvc.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-msvc)
    (string-eq suffix "process.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-process)
    (string-eq suffix "process_borrowed.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-process-borrowed)
    (string-eq suffix "profile.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-profile)
    (string-eq suffix "queue.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-queue)
    (string-eq suffix "random.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-random)
    (string-eq suffix "runtime.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-runtime)
    (string-eq suffix "string.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-string)
    (string-eq suffix "test.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-test)
    (string-eq suffix "thread.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-thread)
    (string-eq suffix "text_buf.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-text-buf)
    (string-eq suffix "text_buf_borrowed.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-text-buf-borrowed)
    (string-eq suffix "vector.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-vector)
    (CompilerEmbeddedStdlibNoSource)))

(define (compiler-embedded-stdlib-lookup-tests [suffix : String]) : CompilerEmbeddedStdlibSource
  (core/cond
    (string-eq suffix "tests/arena_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-arena-api)
    (string-eq suffix "tests/arena_patterns.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-arena-patterns)
    (string-eq suffix "tests/arena_policy.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-arena-policy)
    (string-eq suffix "tests/arena_policy_escape_string.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-arena-policy-escape-string)
    (string-eq suffix "tests/arena_policy_escape_text_buf.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-arena-policy-escape-text-buf)
    (string-eq suffix "tests/arena_policy_escape_text_buf_borrowed.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-arena-policy-escape-text-buf-borrowed)
    (string-eq suffix "tests/args_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-args-api)
    (string-eq suffix "tests/borrowed_str_gate.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-borrowed-str-gate)
    (string-eq suffix "tests/cpu_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-cpu-api)
    (string-eq suffix "tests/core_macros_api.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-core-macros-api)
    (string-eq suffix "tests/env_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-env-api)
    (string-eq suffix "tests/ffi_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-ffi-api)
    (string-eq suffix "tests/fs_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-fs-api)
    (string-eq suffix "tests/fs_path_join_many_api.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-fs-path-join-many-api)
    (string-eq suffix "tests/hash_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-hash-api)
    (string-eq suffix "tests/hashmap_api.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-hashmap-api)
    (string-eq suffix "tests/hashmap_mut_borrow_insert_or_update_live.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-hashmap-mut-borrow-insert-or-update-live)
    (string-eq suffix "tests/io_edges.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-io-edges)
    (string-eq suffix "tests/io_file_handle.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-io-file-handle)
    (string-eq suffix "tests/io_stdio_bytes.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-io-stdio-bytes)
    (string-eq suffix "tests/io_stdio_lines.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-io-stdio-lines)
    (string-eq suffix "tests/io_stdio_pipe_short_read.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-io-stdio-pipe-short-read)
    (string-eq suffix "tests/json_helpers.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-json-helpers)
    (string-eq suffix "tests/json_parse_stringify.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-json-parse-stringify)
    (string-eq suffix "tests/list_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-list-api)
    (string-eq suffix "tests/math_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-math-api)
    (string-eq suffix "tests/process_api.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-process-api)
    (string-eq suffix "tests/process_borrowed_check.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-process-borrowed-check)
    (string-eq suffix "tests/process_borrowed_escape.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-process-borrowed-escape)
    (string-eq suffix "tests/process_runtime.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-process-runtime)
    (string-eq suffix "tests/profile_api.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-profile-api)
    (string-eq suffix "tests/queue_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-queue-api)
    (string-eq suffix "tests/random_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-random-api)
    (string-eq suffix "tests/string_edges.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-string-edges)
    (string-eq suffix "tests/test_assert_failure.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-test-assert-failure)
    (string-eq suffix "tests/test_assert_success.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-test-assert-success)
    (string-eq suffix "tests/text_buf_api.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-text-buf-api)
    (string-eq suffix "tests/text_buf_borrowed_check.tl")
    (CompilerEmbeddedStdlibSomeSource
      compiler-embedded-stdlib-tests-text-buf-borrowed-check)
    (string-eq suffix "tests/vector_api.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-tests-vector-api)
    (CompilerEmbeddedStdlibNoSource)))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (match (compiler-embedded-stdlib-lookup-modules suffix)
    [(CompilerEmbeddedStdlibSomeSource source)
      (CompilerEmbeddedStdlibSomeSource source)]
    [(CompilerEmbeddedStdlibNoSource)
      (compiler-embedded-stdlib-lookup-tests suffix)]))