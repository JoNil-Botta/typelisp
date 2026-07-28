;; compiler_backend_runtime_tests.tl - Focused runtime leaf composition tests.
(import compiler_backend_runtime_common as runtime_common)
(import compiler_backend_runtime_linux as runtime_linux)
(import compiler_backend_runtime_windows as runtime_windows)
(import stdlib.string)
(import stdlib.test)

(define (compiler-backend-runtime-test-contains?
  [text : (& text str)]
  [needle : String]) : bool
  (string.contains text (& needle)))

(define (compiler-backend-runtime-test-minimal-features) : runtime_common.CompilerBackendRuntimeFeatures
  (runtime_common.CompilerBackendRuntimeFeatures
    false
    false
    false
    false
    false
    false
    false
    false
    false))

(define (compiler-backend-runtime-test-full-features) : runtime_common.CompilerBackendRuntimeFeatures
  (runtime_common.CompilerBackendRuntimeFeatures
    true
    true
    true
    true
    true
    true
    true
    true
    true))

(test
  compiler-backend-runtime-leaf-feature-subsets
  (let
    [minimal : runtime_common.CompilerBackendRuntimeFeatures
      (compiler-backend-runtime-test-minimal-features)]
    [full : runtime_common.CompilerBackendRuntimeFeatures
      (compiler-backend-runtime-test-full-features)]
    [linux-min-data : String
      (runtime_linux.compiler-backend-runtime-data (& minimal))]
    [windows-min-data : String
      (runtime_windows.compiler-backend-runtime-data (& minimal))]
    [linux-full-data : String
      (runtime_linux.compiler-backend-runtime-data (& full))]
    [windows-full-data : String
      (runtime_windows.compiler-backend-runtime-data (& full))]
    [linux-min-functions : String
      (runtime_linux.compiler-backend-runtime-functions (& minimal))]
    [windows-min-functions : String
      (runtime_windows.compiler-backend-runtime-functions (& minimal))]
    [linux-full-functions : String
      (runtime_linux.compiler-backend-runtime-functions (& full))]
    [windows-full-functions : String
      (runtime_windows.compiler-backend-runtime-functions (& full))]
    [linux-externs : String
      (runtime_linux.compiler-backend-runtime-externs (& full))]
    [windows-min-externs : String
      (runtime_windows.compiler-backend-runtime-externs (& minimal))]
    [windows-full-externs : String
      (runtime_windows.compiler-backend-runtime-externs (& full))]
    (begin
      (test.assert-true
        (compiler-backend-runtime-test-contains? (& linux-min-data) ".tbss")
        "Linux runtime data owns the TLS arena slot")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& linux-min-data)
            ".L_tl_startup_profile_process_entry_tick"))
        "minimal data omits the process-entry timestamp")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-full-data)
          ".L_tl_startup_profile_process_entry_tick")
        "full Linux data emits the process-entry timestamp")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-full-functions)
          "call QueryPerformanceCounter")
        "full Windows entry captures QPC before argv setup")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-full-functions)
          "tl_startup_profile_process_entry_tick:")
        "full Linux runtime exposes the process-entry timestamp")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains? (& windows-min-data) ".tbss"))
        "Windows runtime data does not emit ELF TLS")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& linux-min-data)
            "tl_profile_alloc_total_bytes"))
        "minimal data omits profile counters")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-full-data)
          "tl_profile_alloc_total_bytes")
        "full Linux data emits profile counters")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-full-data)
          ".L_tl_region_reset_msg")
        "full Windows data emits region-reset diagnostics")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-min-functions)
          ".globl tl_memcpy")
        "minimal Linux functions keep common memory helpers")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-min-functions)
          ".globl tl_memchr")
        "minimal Windows functions keep memchr")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-min-functions)
          ".globl tl_array_zero")
        "minimal Linux functions keep array zero")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-min-functions)
          ".globl tl_tlci_call_image_entry")
        "minimal Windows functions keep the TLCI image bridge")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-min-functions)
          ".globl tl_arena_current")
        "minimal Linux functions keep the arena API")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-min-functions)
          ".globl tl_thread_init")
        "minimal Linux functions keep thread initialization")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-min-functions)
          ".globl tl_thread_entry_ptr")
        "minimal Windows functions keep the thread entry bridge")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& linux-min-functions)
            "tl_arena_debug"))
        "minimal Linux functions omit arena debug guards")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& windows-min-functions)
            "tl_arena_debug"))
        "minimal Windows functions omit arena debug guards")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& linux-min-data)
            ".L_tl_arena_debug_roots"))
        "minimal Linux data omits the arena debug registry")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& windows-min-data)
            ".L_tl_arena_debug_roots"))
        "minimal Windows data omits the arena debug registry")
      (test.assert-true
        (string.eq
          (runtime_linux.compiler-backend-runtime-linux-arena-functions-base
            false)
          (runtime_linux.compiler-backend-runtime-linux-arena-functions
            false
            false))
        "disabled Linux arena debug leaves arena assembly byte-identical")
      (test.assert-true
        (string.eq
          (runtime_linux.compiler-backend-runtime-region-reset-functions-base
            false)
          (runtime_linux.compiler-backend-runtime-region-reset-functions
            false
            false))
        "disabled Linux arena debug leaves reset assembly byte-identical")
      (test.assert-true
        (string.eq
          (runtime_linux.compiler-backend-runtime-linux-alloc-functions-base
            false)
          (runtime_linux.compiler-backend-runtime-linux-alloc-functions
            false
            false))
        "disabled Linux arena debug leaves allocator assembly byte-identical")
      (test.assert-true
        (string.eq
          (runtime_windows.compiler-backend-runtime-windows-arena-functions-base
            false)
          (runtime_windows.compiler-backend-runtime-windows-arena-functions
            false
            false))
        "disabled Windows arena debug leaves arena assembly byte-identical")
      (test.assert-true
        (string.eq
          (runtime_windows.compiler-backend-runtime-windows-region-reset-functions-base
            false)
          (runtime_windows.compiler-backend-runtime-windows-region-reset-functions
            false
            false))
        "disabled Windows arena debug leaves reset assembly byte-identical")
      (test.assert-true
        (string.eq
          (runtime_windows.compiler-backend-runtime-windows-alloc-functions-base
            false)
          (runtime_windows.compiler-backend-runtime-windows-alloc-functions
            false
            false))
        "disabled Windows arena debug leaves allocator assembly byte-identical")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& linux-min-functions)
            ".globl tl_alloc"))
        "minimal Linux functions omit optional allocation")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& windows-min-functions)
            "tl_tlci_call_macro_entry:"))
        "minimal Windows functions omit the macro-entry bridge")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-full-functions)
          ".globl tl_region_reset")
        "full Linux functions emit region reset")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-full-functions)
          ".globl tl_alloc")
        "full Windows functions emit the allocator")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-full-functions)
          "tl_tlci_call_macro_entry:")
        "full Windows functions emit the macro-entry bridge")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& linux-full-functions)
          "%fs:tl_current_arena@tpoff")
        "Linux functions use the ELF TLS arena slot")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-full-functions)
          "%gs:0x28")
        "Windows functions use the TEB arena slot")
      (cfg
        (any compiler-arena-debug test)
        (begin
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& linux-full-functions)
              ".globl tl_arena_debug_protect_never_reset")
            "debug Linux runtime emits the protect operation")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& windows-full-functions)
              ".globl tl_arena_debug_assert_pool_install")
            "debug Windows runtime emits the pool-install assertion")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& linux-full-functions)
              "call .L_tl_arena_debug_register_root")
            "debug Linux arena creation registers roots")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& windows-full-functions)
              "call .L_tl_arena_debug_unregister_root")
            "debug Windows destruction unregisters roots")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& linux-full-functions)
              "orq $8, 48(%rdi)")
            "debug protection uses a flag separate from atomic state")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& linux-full-data)
              ".L_tl_arena_debug_roots")
            "debug Linux data emits the root registry")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& windows-full-data)
              ".L_tl_arena_debug_roots")
            "debug Windows data emits the root registry")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& linux-full-functions)
              "jnz tl_arena_debug_destroy_abort")
            "debug Linux destroy fails before release")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& windows-full-functions)
              "call tl_arena_debug_reset_abort")
            "debug Windows reset fails through the stable operation abort")
          (test.assert-true
            (compiler-backend-runtime-test-contains?
              (& linux-full-functions)
              "lock cmpxchgq %rcx, 48(%r9)")
            "debug mode preserves the atomic 1/3 lock protocol"))
        unit)
      (test.assert-true
        (string.eq linux-externs "")
        "Linux leaf has no backend runtime extern set")
      (test.assert-true
        (not
          (compiler-backend-runtime-test-contains?
            (& windows-min-externs)
            ".extern WriteFile"))
        "minimal Windows externs omit write support")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-full-externs)
          ".extern WriteFile")
        "full Windows externs include write support")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-full-externs)
          ".extern _snprintf")
        "full Windows externs include float formatting")
      (test.assert-true
        (compiler-backend-runtime-test-contains?
          (& windows-full-externs)
          ".extern QueryPerformanceCounter")
        "full Windows externs include the entry clock dependency"))))