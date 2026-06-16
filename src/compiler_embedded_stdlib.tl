;; compiler_embedded_stdlib.tl - Checked-in stdlib source payloads (#1509).
(defenum CompilerEmbeddedStdlibSource
  (CompilerEmbeddedStdlibNoSource)
  (CompilerEmbeddedStdlibSomeSource String))

(include-str compiler-embedded-stdlib-arena "stdlib/arena.tl")

(include-str compiler-embedded-stdlib-args "stdlib/args.tl")

(include-str compiler-embedded-stdlib-cpu "stdlib/cpu.tl")

(include-str compiler-embedded-stdlib-comptime "stdlib/comptime.tl")

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

(include-str compiler-embedded-stdlib-sort "stdlib/sort.tl")

(include-str compiler-embedded-stdlib-sync "stdlib/sync.tl")

(include-str compiler-embedded-stdlib-string "stdlib/string.tl")

(include-str compiler-embedded-stdlib-test "stdlib/test.tl")

(include-str compiler-embedded-stdlib-thread "stdlib/thread.tl")

(include-str compiler-embedded-stdlib-time "stdlib/time.tl")

(include-str compiler-embedded-stdlib-tests-arena-patterns "stdlib/tests/arena_patterns.tl")

(include-str compiler-embedded-stdlib-tests-arena-policy-escape-string "stdlib/tests/arena_policy_escape_string.tl")

(include-str compiler-embedded-stdlib-tests-arena-policy-escape-text-buf "stdlib/tests/arena_policy_escape_text_buf.tl")

(include-str compiler-embedded-stdlib-tests-arena-policy-escape-text-buf-borrowed "stdlib/tests/arena_policy_escape_text_buf_borrowed.tl")

(include-str compiler-embedded-stdlib-tests-args-api "stdlib/tests/args_api.tl")

(include-str compiler-embedded-stdlib-tests-cpu-api "stdlib/tests/cpu_api.tl")

(include-str compiler-embedded-stdlib-tests-core-macros-api "stdlib/tests/core_macros_api.tl")

(include-str compiler-embedded-stdlib-tests-comptime-api "stdlib/tests/comptime_api.tl")

(include-str compiler-embedded-stdlib-tests-env-api "stdlib/tests/env_api.tl")

(include-str compiler-embedded-stdlib-tests-fs-api "stdlib/tests/fs_api.tl")

(include-str compiler-embedded-stdlib-tests-fs-path-join-many-api "stdlib/tests/fs_path_join_many_api.tl")

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

(include-str compiler-embedded-stdlib-tests-msvc-api "stdlib/tests/msvc_api.tl")

(include-str compiler-embedded-stdlib-tests-process-api "stdlib/tests/process_api.tl")

(include-str compiler-embedded-stdlib-tests-process-borrowed-escape "stdlib/tests/process_borrowed_escape.tl")

(include-str compiler-embedded-stdlib-tests-process-runtime "stdlib/tests/process_runtime.tl")

(include-str compiler-embedded-stdlib-tests-profile-api "stdlib/tests/profile_api.tl")

(include-str compiler-embedded-stdlib-tests-random-api "stdlib/tests/random_api.tl")

(include-str compiler-embedded-stdlib-tests-sort-api "stdlib/tests/sort_api.tl")

(include-str compiler-embedded-stdlib-tests-sync-api "stdlib/tests/sync_api.tl")

(include-str compiler-embedded-stdlib-tests-string-edges "stdlib/tests/string_edges.tl")

(include-str compiler-embedded-stdlib-tests-test-assert-failure "stdlib/tests/test_assert_failure.tl")

(include-str compiler-embedded-stdlib-tests-time-api "stdlib/tests/time_api.tl")

(include-str compiler-embedded-stdlib-tests-text-buf-api "stdlib/tests/text_buf_api.tl")

(include-str compiler-embedded-stdlib-tests-vector-api "stdlib/tests/vector_api.tl")

(include-str compiler-embedded-stdlib-text-buf "stdlib/text_buf.tl")

(include-str compiler-embedded-stdlib-text-buf-borrowed "stdlib/text_buf_borrowed.tl")

(include-str compiler-embedded-stdlib-vector "stdlib/vector.tl")

(define (compiler-embedded-stdlib-lookup-modules [suffix : String]) : CompilerEmbeddedStdlibSource
  (if (string-eq suffix "arena.tl")
    (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-arena)
    (if (string-eq suffix "args.tl")
      (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-args)
      (if (string-eq suffix "cpu.tl")
        (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-cpu)
        (if (string-eq suffix "comptime.tl")
          (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-comptime)
          (if (string-eq suffix "core_macros.tl")
            (CompilerEmbeddedStdlibSomeSource
              compiler-embedded-stdlib-core-macros)
            (if (string-eq suffix "env.tl")
              (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-env)
              (if (string-eq suffix "ffi.tl")
                (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-ffi)
                (if (string-eq suffix "fs.tl")
                  (CompilerEmbeddedStdlibSomeSource compiler-embedded-stdlib-fs)
                  (if (string-eq suffix "hash.tl")
                    (CompilerEmbeddedStdlibSomeSource
                      compiler-embedded-stdlib-hash)
                    (if (string-eq suffix "hashmap.tl")
                      (CompilerEmbeddedStdlibSomeSource
                        compiler-embedded-stdlib-hashmap)
                      (if (string-eq suffix "io.tl")
                        (CompilerEmbeddedStdlibSomeSource
                          compiler-embedded-stdlib-io)
                        (if (string-eq suffix "json.tl")
                          (CompilerEmbeddedStdlibSomeSource
                            compiler-embedded-stdlib-json)
                          (if (string-eq suffix "list.tl")
                            (CompilerEmbeddedStdlibSomeSource
                              compiler-embedded-stdlib-list)
                            (if (string-eq suffix "math.tl")
                              (CompilerEmbeddedStdlibSomeSource
                                compiler-embedded-stdlib-math)
                              (if (string-eq suffix "msvc.tl")
                                (CompilerEmbeddedStdlibSomeSource
                                  compiler-embedded-stdlib-msvc)
                                (if (string-eq suffix "process.tl")
                                  (CompilerEmbeddedStdlibSomeSource
                                    compiler-embedded-stdlib-process)
                                  (if (string-eq suffix "process_borrowed.tl")
                                    (CompilerEmbeddedStdlibSomeSource
                                      compiler-embedded-stdlib-process-borrowed)
                                    (if (string-eq suffix "profile.tl")
                                      (CompilerEmbeddedStdlibSomeSource
                                        compiler-embedded-stdlib-profile)
                                      (if (string-eq suffix "queue.tl")
                                        (CompilerEmbeddedStdlibSomeSource
                                          compiler-embedded-stdlib-queue)
                                        (if (string-eq suffix "random.tl")
                                          (CompilerEmbeddedStdlibSomeSource
                                            compiler-embedded-stdlib-random)
                                          (if (string-eq suffix "runtime.tl")
                                            (CompilerEmbeddedStdlibSomeSource
                                              compiler-embedded-stdlib-runtime)
                                            (if (string-eq suffix "sort.tl")
                                              (CompilerEmbeddedStdlibSomeSource
                                                compiler-embedded-stdlib-sort)
                                              (if (string-eq suffix "sync.tl")
                                                (CompilerEmbeddedStdlibSomeSource
                                                  compiler-embedded-stdlib-sync)
                                                (if (string-eq
                                                  suffix
                                                  "string.tl")
                                                  (CompilerEmbeddedStdlibSomeSource
                                                    compiler-embedded-stdlib-string)
                                                  (if (string-eq
                                                    suffix
                                                    "test.tl")
                                                    (CompilerEmbeddedStdlibSomeSource
                                                      compiler-embedded-stdlib-test)
                                                    (if (string-eq
                                                      suffix
                                                      "thread.tl")
                                                      (CompilerEmbeddedStdlibSomeSource
                                                        compiler-embedded-stdlib-thread)
                                                      (if (string-eq
                                                        suffix
                                                        "time.tl")
                                                        (CompilerEmbeddedStdlibSomeSource
                                                          compiler-embedded-stdlib-time)
                                                        (if (string-eq
                                                          suffix
                                                          "text_buf.tl")
                                                          (CompilerEmbeddedStdlibSomeSource
                                                            compiler-embedded-stdlib-text-buf)
                                                          (if (string-eq
                                                            suffix
                                                            "text_buf_borrowed.tl")
                                                            (CompilerEmbeddedStdlibSomeSource
                                                              compiler-embedded-stdlib-text-buf-borrowed)
                                                            (if (string-eq
                                                              suffix
                                                              "vector.tl")
                                                              (CompilerEmbeddedStdlibSomeSource
                                                                compiler-embedded-stdlib-vector)
                                                              (CompilerEmbeddedStdlibNoSource))))))))))))))))))))))))))))))))

(define (compiler-embedded-stdlib-lookup-tests [suffix : String]) : CompilerEmbeddedStdlibSource
  (let
    [source : CompilerEmbeddedStdlibSource (CompilerEmbeddedStdlibNoSource)]
    (begin
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
      (if (string-eq suffix "tests/args_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-args-api))
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
      (if (string-eq suffix "tests/env_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-env-api))
        unit)
      (if (string-eq suffix "tests/fs_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-fs-api))
        unit)
      (if (string-eq suffix "tests/fs_path_join_many_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-fs-path-join-many-api))
        unit)
      (if (string-eq suffix "tests/hashmap_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-hashmap-api))
        unit)
      (if (string-eq suffix "tests/hashmap_mut_borrow_insert_or_update_live.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-hashmap-mut-borrow-insert-or-update-live))
        unit)
      (if (string-eq suffix "tests/io_edges.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-io-edges))
        unit)
      (if (string-eq suffix "tests/io_file_handle.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-io-file-handle))
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
      (if (string-eq suffix "tests/json_helpers.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-json-helpers))
        unit)
      (if (string-eq suffix "tests/json_parse_stringify.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-json-parse-stringify))
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
      (if (string-eq suffix "tests/random_api.tl")
        (set!
          source
          (CompilerEmbeddedStdlibSomeSource
            compiler-embedded-stdlib-tests-random-api))
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
      source)))

(define (compiler-embedded-stdlib-lookup [suffix : String]) : CompilerEmbeddedStdlibSource
  (match (compiler-embedded-stdlib-lookup-modules suffix)
    [(CompilerEmbeddedStdlibSomeSource source)
      (CompilerEmbeddedStdlibSomeSource source)]
    [(CompilerEmbeddedStdlibNoSource)
      (compiler-embedded-stdlib-lookup-tests suffix)]))