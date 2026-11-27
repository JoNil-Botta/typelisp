;; compiler_backend_object_target_tests.tl - Focused direct-object leaf tests.
(import compiler_object_windows_sections as coff_sections)
(import compiler_backend_object_target as object_target)
(import compiler_backend_object_target_linux as object_linux)
(import compiler_backend_object_target_windows as object_windows)
(import compiler_object as cobj)
(import stdlib.test)

(define (compiler-backend-object-target-leaf-shapes-test!) : unit
  (let
    [linux-image : cobj.CompilerObjectImage
      (object_linux.compiler-backend-object-target-linux-image
        (object_target.compiler-backend-object-parts-empty)
        true
        true
        false
        false)]
    [windows-image : cobj.CompilerObjectImage
      (object_windows.compiler-backend-object-target-windows-image
        (object_target.compiler-backend-object-parts-empty)
        true
        true
        false
        false)]
    [linux-sections : cobj.CompilerObjectSectionList linux-image.sections]
    [windows-sections : cobj.CompilerObjectSectionList windows-image.sections]
    (test.assert-true
      (= (cobj.compiler-object-section-list-count linux-sections) 4)
      "Linux leaf emits only the shared ELF section set")
    (test.assert-true
      (cobj.compiler-object-section-contains-bytes?
        linux-sections
        (& (object_linux.compiler-backend-object-tlci-entry-bytes)))
      "Linux leaf owns the System V TLCI image bridge")
    (test.assert-true
      (cobj.compiler-object-section-contains-bytes?
        linux-sections
        (& (object_linux.compiler-backend-object-tlci-macro-entry-bytes)))
      "Linux leaf owns the System V TLCI macro bridge")
    (test.assert-true
      (cobj.compiler-object-section-contains-bytes?
        linux-sections
        (& (object_linux.compiler-backend-object-exit-bytes)))
      "Linux leaf owns the syscall exit tail")
    (test.assert-true
      (cobj.compiler-object-symbol-list-contains?
        linux-image.symbols
        "_tl_start"
        (Export)
        (Function))
      "Linux leaf exports the native entry")
    (test.assert-true
      (= (cobj.compiler-object-section-list-count windows-sections) 7)
      "Windows leaf emits COFF pdata, xdata, and resource sections")
    (test.assert-true
      (cobj.compiler-object-section-contains-bytes?
        windows-sections
        (& (object_windows.compiler-backend-object-tlci-entry-bytes)))
      "Windows leaf owns the Win64 TLCI image bridge")
    (test.assert-true
      (cobj.compiler-object-section-contains-bytes?
        windows-sections
        (& (object_windows.compiler-backend-object-tlci-macro-entry-bytes)))
      "Windows leaf owns the Win64 TLCI macro bridge")
    (test.assert-true
      (cobj.compiler-object-section-contains-label?
        windows-sections
        coff_sections.pdata-id
        ".L_tl_start_pdata_begin")
      "Windows leaf emits entry unwind pdata")
    (test.assert-true
      (cobj.compiler-object-section-contains-label?
        windows-sections
        coff_sections.xdata-id
        ".L_tl_start_xdata")
      "Windows leaf emits entry unwind xdata")
    (test.assert-true
      (let
        [label
          (object_windows.compiler-backend-object-manifest-label-shared-view)]
        (cobj.compiler-object-section-contains-label?
          windows-sections
          coff_sections.rsrc-id
          label))
      "Windows leaf emits the UTF-8 manifest resource")
    (test.assert-true
      (let
        [target
          (object_windows.compiler-backend-object-manifest-label-shared-view)]
        (cobj.compiler-object-relocation-list-contains?
          windows-image.relocations
          (Addr32Nb)
          target))
      "Windows leaf relocates the manifest resource")))

(test
  compiler-backend-object-target-leaf-shapes
  (compiler-backend-object-target-leaf-shapes-test!))

(define (compiler-backend-object-target-crt-entry-gate-test!) : unit
  (let
    [linux-image : cobj.CompilerObjectImage
      (object_linux.compiler-backend-object-target-linux-image
        (object_target.compiler-backend-object-parts-empty)
        false
        true
        true
        false)]
    [windows-image : cobj.CompilerObjectImage
      (object_windows.compiler-backend-object-target-windows-image
        (object_target.compiler-backend-object-parts-empty)
        false
        true
        true
        false)]
    [empty-windows
      (object_windows.compiler-backend-object-target-windows-image
        (object_target.compiler-backend-object-parts-empty)
        false
        false
        false
        true)]
    (test.assert-i64-eq
      linux-image.sections.len
      4
      "empty Linux base sections remain declared")
    (test.assert-i64-eq
      empty-windows.sections.len
      4
      "empty Windows base sections remain and unused metadata is omitted")
    (test.assert-true
      (not
        (cobj.compiler-object-symbol-list-contains?
          linux-image.symbols
          "_tl_start"
          (Export)
          (Function)))
      "Linux CRT mode omits the backend-owned native entry")
    (test.assert-true
      (not
        (cobj.compiler-object-symbol-list-contains?
          windows-image.symbols
          "_tl_start"
          (Export)
          (Function)))
      "Windows CRT mode omits the backend-owned native entry")
    (test.assert-true
      (not
        (let
          [name
            (object_windows.compiler-backend-object-manifest-label-shared-view)]
          (cobj.compiler-object-symbol-list-contains?
            windows-image.symbols
            name
            (Local)
            (Data))))
      "Windows CRT mode omits the executable manifest symbol")))

(test
  compiler-backend-object-target-crt-entry-gate
  (compiler-backend-object-target-crt-entry-gate-test!))

(define (compiler-backend-object-target-tests-main) : i64
  (compiler-backend-object-target-leaf-shapes-test!)
  (compiler-backend-object-target-crt-entry-gate-test!)
  42)