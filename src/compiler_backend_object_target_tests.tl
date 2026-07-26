;; compiler_backend_object_target_tests.tl - Focused direct-object leaf tests.
(import compiler_backend_object_target as object_target)
(import compiler_backend_object_target_linux as object_linux)
(import compiler_backend_object_target_windows as object_windows)
(import compiler_object as cobj)
(import stdlib.test)

(test
  compiler-backend-object-target-leaf-shapes
  (let
    [linux-image : cobj.CompilerObjectImage
      (object_linux.compiler-backend-object-target-linux-image
        (object_target.compiler-backend-object-parts-empty)
        true
        true
        false)]
    [windows-image : cobj.CompilerObjectImage
      (object_windows.compiler-backend-object-target-windows-image
        (object_target.compiler-backend-object-parts-empty)
        true
        true
        false)]
    [linux-sections : cobj.CompilerObjectSectionList
      (struct-get linux-image sections)]
    [windows-sections : cobj.CompilerObjectSectionList
      (struct-get windows-image sections)]
    (begin
      (test.assert-true
        (= (cobj.compiler-object-section-list-count linux-sections) 4)
        "Linux leaf emits only the shared ELF section set")
      (test.assert-true
        (cobj.compiler-object-section-contains-bytes?
          linux-sections
          (object_linux.compiler-backend-object-tlci-entry-bytes))
        "Linux leaf owns the System V TLCI image bridge")
      (test.assert-true
        (cobj.compiler-object-section-contains-bytes?
          linux-sections
          (object_linux.compiler-backend-object-tlci-macro-entry-bytes))
        "Linux leaf owns the System V TLCI macro bridge")
      (test.assert-true
        (cobj.compiler-object-section-contains-bytes?
          linux-sections
          (object_linux.compiler-backend-object-exit-bytes))
        "Linux leaf owns the syscall exit tail")
      (test.assert-true
        (cobj.compiler-object-symbol-list-contains?
          (struct-get linux-image symbols)
          "_tl_start"
          (cobj.CompilerObjectSymbolBinding.Export)
          (cobj.CompilerObjectSymbolKind.Function))
        "Linux leaf exports the native entry")
      (test.assert-true
        (= (cobj.compiler-object-section-list-count windows-sections) 7)
        "Windows leaf emits COFF pdata, xdata, and resource sections")
      (test.assert-true
        (cobj.compiler-object-section-contains-bytes?
          windows-sections
          (object_windows.compiler-backend-object-tlci-entry-bytes))
        "Windows leaf owns the Win64 TLCI image bridge")
      (test.assert-true
        (cobj.compiler-object-section-contains-bytes?
          windows-sections
          (object_windows.compiler-backend-object-tlci-macro-entry-bytes))
        "Windows leaf owns the Win64 TLCI macro bridge")
      (test.assert-true
        (cobj.compiler-object-section-contains-label?
          windows-sections
          (cobj.CompilerObjectSectionKind.Pdata)
          ".L_tl_start_pdata_begin")
        "Windows leaf emits entry unwind pdata")
      (test.assert-true
        (cobj.compiler-object-section-contains-label?
          windows-sections
          (cobj.CompilerObjectSectionKind.Xdata)
          ".L_tl_start_xdata")
        "Windows leaf emits entry unwind xdata")
      (test.assert-true
        (cobj.compiler-object-section-contains-label?
          windows-sections
          (cobj.CompilerObjectSectionKind.Rsrc)
          object_windows.compiler-backend-object-manifest-label)
        "Windows leaf emits the UTF-8 manifest resource")
      (test.assert-true
        (cobj.compiler-object-relocation-list-contains?
          (struct-get windows-image relocations)
          (cobj.CompilerObjectRelocationKind.Addr32Nb)
          object_windows.compiler-backend-object-manifest-label)
        "Windows leaf relocates the manifest resource"))))

(test
  compiler-backend-object-target-crt-entry-gate
  (let
    [linux-image : cobj.CompilerObjectImage
      (object_linux.compiler-backend-object-target-linux-image
        (object_target.compiler-backend-object-parts-empty)
        false
        true
        true)]
    [windows-image : cobj.CompilerObjectImage
      (object_windows.compiler-backend-object-target-windows-image
        (object_target.compiler-backend-object-parts-empty)
        false
        true
        true)]
    (begin
      (test.assert-true
        (not
          (cobj.compiler-object-symbol-list-contains?
            (struct-get linux-image symbols)
            "_tl_start"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)))
        "Linux CRT mode omits the backend-owned native entry")
      (test.assert-true
        (not
          (cobj.compiler-object-symbol-list-contains?
            (struct-get windows-image symbols)
            "_tl_start"
            (cobj.CompilerObjectSymbolBinding.Export)
            (cobj.CompilerObjectSymbolKind.Function)))
        "Windows CRT mode omits the backend-owned native entry")
      (test.assert-true
        (not
          (cobj.compiler-object-symbol-list-contains?
            (struct-get windows-image symbols)
            object_windows.compiler-backend-object-manifest-label
            (cobj.CompilerObjectSymbolBinding.Local)
            (cobj.CompilerObjectSymbolKind.Data)))
        "Windows CRT mode omits the executable manifest symbol"))))