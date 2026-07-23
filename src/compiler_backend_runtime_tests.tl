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
    false))

(define (compiler-backend-runtime-test-full-features) : runtime_common.CompilerBackendRuntimeFeatures
  (runtime_common.CompilerBackendRuntimeFeatures
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
        "full Windows externs include float formatting"))))