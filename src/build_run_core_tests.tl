;; build_run_core_tests.tl - White-box tests for source-tool builds: link
;; inputs, direct-object linkability and the Windows linker options.
(import compiler_owned_view as owned_view)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)
(import compiler_backend as backend)
(import compiler_ast_types as ast)
(import compiler_ir_types as ir)
(import compiler_object as cobj)
(import compiler_windows_coff_core)
(import stdlib.process)
(import stdlib.string)
(import build_run_core as build_run)

(define (source-tool-string-list-eq?
  [left : process.ProcessStringList]
  [right : process.ProcessStringList]) : bool
  (let
    [n : i64 (process.args-count left)]
    [i : i64 0]
    [same : bool (= n (process.args-count right))]
    (begin
      (while (and same (< i n))
        (begin
          (if (string.eq (process.args-ref left i) (process.args-ref right i))
            unit
            (set! same false))
          (set! i (+ i 1))))
      same)))

(define (source-tool-link-inputs-eq?
  [left : build_run.SourceToolLinkInputs]
  [right : build_run.SourceToolLinkInputs]) : bool
  (and
    (source-tool-string-list-eq?
      (build_run.source-tool-link-inputs-libs left)
      (build_run.source-tool-link-inputs-libs right))
    (source-tool-string-list-eq?
      (build_run.source-tool-link-inputs-search-dirs left)
      (build_run.source-tool-link-inputs-search-dirs right))
    (source-tool-string-list-eq?
      (build_run.source-tool-link-inputs-raw-args left)
      (build_run.source-tool-link-inputs-raw-args right))
    (source-tool-string-list-eq?
      (build_run.source-tool-link-inputs-archives left)
      (build_run.source-tool-link-inputs-archives right))))

(define (source-tool-link-inputs-dedupe-smoke-ok?) : bool
  (let
    [metadata-items : ast.AstExternLinkInputList
      (ast.ast-extern-link-input-list-new)]
    [metadata-inputs : build_run.SourceToolLinkInputs
      (begin
        (ast.ast-extern-link-input-list-push
          (&mut metadata-items)
          (ast.AstExternLinkInput.Lib "m"))
        (ast.ast-extern-link-input-list-push
          (&mut metadata-items)
          (ast.AstExternLinkInput.Lib "m"))
        (ast.ast-extern-link-input-list-push
          (&mut metadata-items)
          (ast.AstExternLinkInput.Search "native"))
        (ast.ast-extern-link-input-list-push
          (&mut metadata-items)
          (ast.AstExternLinkInput.Arg "-Wl,a"))
        (build_run.source-tool-link-inputs-add-ast-list
          (build_run.source-tool-link-inputs-empty)
          (& metadata-items)
          0))]
    [explicit-inputs : build_run.SourceToolLinkInputs
      (build_run.source-tool-link-inputs-add-raw-arg
        (build_run.source-tool-link-inputs-add-raw-arg
          (build_run.source-tool-link-inputs-add-search-dir
            (build_run.source-tool-link-inputs-add-search-dir
              (build_run.source-tool-link-inputs-add-lib
                (build_run.source-tool-link-inputs-add-lib
                  (build_run.source-tool-link-inputs-empty)
                  "m")
                "z")
              "native")
            "cli")
          "-Wl,a")
        "-Wl,b")]
    [expected : build_run.SourceToolLinkInputs
      (build_run.SourceToolLinkInputs
        (process.args-cons "m" (process.args-cons "z" (process.args-empty)))
        (process.args-cons
          "native"
          (process.args-cons "cli" (process.args-empty)))
        (process.args-cons
          "-Wl,a"
          (process.args-cons "-Wl,b" (process.args-empty)))
        (process.args-empty)
        (build_run.source-tool-link-origins-empty))]
    (source-tool-link-inputs-eq?
      (build_run.source-tool-link-inputs-merge metadata-inputs explicit-inputs)
      expected)))

(define (source-tool-linux-direct-object-linkable?
  [image : cobj.CompilerObjectImage]) : bool
  (match (build_run.source-tool-linux-direct-object-eligibility
    backend.CompilerDirectObjectArtifactKind.Bin
    image)
    [(build_run.SourceToolLinuxDirectObjectEligibility.Eligible) true]
    [(build_run.SourceToolLinuxDirectObjectEligibility.Fallback _) false]))

(define (source-tool-windows-direct-object-relocations-linkable?
  [symbols : (& symbols cobj.CompilerObjectSymbolList)]
  [relocs : cobj.CompilerObjectRelocationList]) : bool
  (let
    [symbols : cobj.CompilerObjectSymbolList
      (owned_view.compiler-owned-reference-shared-view symbols)]
    (compiler_windows_coff_core.compiler-windows-coff-relocations-linkable?
      symbols
      relocs)))

(define (source-tool-windows-system-libs-smoke-ok?) : bool
  (let
    [libs : process.ProcessStringList (build_run.source-tool-windows-link-libs)]
    (and
      (= (process.args-count libs) 2)
      (string.eq (process.args-ref libs 0) "kernel32.lib")
      (string.eq (process.args-ref libs 1) "ntdll.lib"))))

(define (source-tool-windows-stack-reserve-smoke-ok?) : bool
  (let
    [linker-args
      (build_run.source-tool-windows-linker-args
        "input.obj"
        "output.exe"
        (build_run.source-tool-link-inputs-empty))]
    (build_run.source-tool-string-list-contains?
      linker-args
      (build_run.source-tool-windows-stack-reserve-arg))))

(define (source-tool-windows-debug-linker-smoke-ok?) : bool
  (let
    [previous : bool (ir.compiler-debug-info-enabled?)]
    [ok : bool false]
    (begin
      (ir.compiler-debug-info-set-enabled! true)
      (set!
        ok
        (let
          [linker-args
            (build_run.source-tool-windows-linker-args
              "input.obj"
              "output.exe"
              (build_run.source-tool-link-inputs-empty))]
          (build_run.source-tool-string-list-contains? linker-args "/DEBUG")))
      (ir.compiler-debug-info-set-enabled! previous)
      ok)))

(define (source-tool-linux-direct-object-linkability-smoke-ok?) : bool
  (match (backend.compiler-backend-emit-source-object-image-for-target
    "(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : i64 (inc answer))"
    (backend.CompilerBackendTarget.Linux))
    [(backend.ResultCompilerBackendObject.Ok image)
      (if (source-tool-linux-direct-object-linkable?
        (owned_view.compiler-owned-shared-view image))
        (match (build_run.source-tool-render-linkable-linux-elf-object image)
          [(build_run.ResultSourceToolString.Ok obj)
            (> (string.string-length obj) 0)]
          [(build_run.ResultSourceToolString.Err _) false])
        false)]
    [(backend.ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-linkability-smoke-ok?) : bool
  (match (backend.compiler-backend-emit-source-object-image-for-target
    "(extern (unused-direct [value : i64]) : i64
  (:symbol \"typelisp_unused_direct\"))
(extern unused-data (:symbol \"typelisp_unused_data\") : i64)
(extern unused-fnptr (:symbol \"typelisp_unused_fnptr\") : (CFunc non-null (-> i64 i64)))
(define (main) : i64 0)"
    (backend.CompilerBackendTarget.Windows))
    [(backend.ResultCompilerBackendObject.Ok image)
      (if (build_run.source-tool-windows-direct-object-linkable?
        (owned_view.compiler-owned-shared-view image))
        (match (build_run.source-tool-render-linkable-windows-coff-object image)
          [(build_run.ResultSourceToolString.Ok obj)
            (> (string.string-length obj) 0)]
          [(build_run.ResultSourceToolString.Err _) false])
        false)]
    [(backend.ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-runtime-fallback-smoke-ok?) : bool
  (match (backend.compiler-backend-emit-source-object-image-for-target
    "(define (main) : i64
  (let [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    (array-length items)))"
    (backend.CompilerBackendTarget.Windows))
    [(backend.ResultCompilerBackendObject.Ok image)
      (not (build_run.source-tool-windows-direct-object-linkable? image))]
    [(backend.ResultCompilerBackendObject.Err _) false]))

(define (source-tool-windows-direct-object-relocation-gate-smoke-ok?) : bool
  (let
    [symbols0 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-with-capacity 4)]
    [symbols1 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols0
        (cobj.CompilerObjectSymbol.Symbol
          "GetStdHandle"
          (cobj.CompilerObjectSymbolBinding.Extern)
          (cobj.CompilerObjectSymbolKind.Function)
          cobj.CompilerObjectMaybeSection.No))]
    [symbols2 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols1
        (cobj.CompilerObjectSymbol.Symbol
          "NtCreateFile"
          (cobj.CompilerObjectSymbolBinding.Extern)
          (cobj.CompilerObjectSymbolKind.Function)
          cobj.CompilerObjectMaybeSection.No))]
    [symbols3 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols2
        (cobj.CompilerObjectSymbol.Symbol
          "GetCurrentProcessId"
          (cobj.CompilerObjectSymbolBinding.Extern)
          (cobj.CompilerObjectSymbolKind.Function)
          cobj.CompilerObjectMaybeSection.No))]
    [symbols4 : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-push
        symbols3
        (cobj.CompilerObjectSymbol.Symbol
          "NtOpenFile"
          (cobj.CompilerObjectSymbolBinding.Extern)
          (cobj.CompilerObjectSymbolKind.Function)
          cobj.CompilerObjectMaybeSection.No))]
    [symbols : cobj.CompilerObjectSymbolList
      (cobj.compiler-object-symbol-builder-finish symbols4)]
    [empty-relocs : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-with-capacity 1))]
    [allowed-relocs : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-push
          (cobj.compiler-object-relocation-builder-push
            (cobj.compiler-object-relocation-builder-with-capacity 2)
            (cobj.CompilerObjectRelocation.Relocation
              (cobj.CompilerObjectSectionKind.Text)
              "main"
              (cobj.CompilerObjectRelocationKind.Call)
              "GetStdHandle"))
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "main"
            (cobj.CompilerObjectRelocationKind.Call)
            "NtCreateFile")))]
    [blocked-win32-relocs : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-push
          (cobj.compiler-object-relocation-builder-with-capacity 1)
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "main"
            (cobj.CompilerObjectRelocationKind.Call)
            "GetCurrentProcessId")))]
    [blocked-ntdll-relocs : cobj.CompilerObjectRelocationList
      (cobj.compiler-object-relocation-builder-finish
        (cobj.compiler-object-relocation-builder-push
          (cobj.compiler-object-relocation-builder-with-capacity 1)
          (cobj.CompilerObjectRelocation.Relocation
            (cobj.CompilerObjectSectionKind.Text)
            "main"
            (cobj.CompilerObjectRelocationKind.Call)
            "NtOpenFile")))]
    (and
      (source-tool-windows-direct-object-relocations-linkable?
        symbols
        empty-relocs)
      (source-tool-windows-direct-object-relocations-linkable?
        symbols
        allowed-relocs)
      (not
        (source-tool-windows-direct-object-relocations-linkable?
          symbols
          blocked-win32-relocs))
      (not
        (source-tool-windows-direct-object-relocations-linkable?
          symbols
          blocked-ntdll-relocs)))))

(define (source-tool-test-list [items : cli_svec.Vec]) : process.ProcessStringList
  (let
    [out : process.ProcessStringList (process.args-empty)]
    [index : i64 0]
    (begin
      (while (< index (cli_svec.len (& items)))
        (begin
          (set!
            out
            (process.args-append
              out
              (process.args-single (cli_svec.get (& items) index ""))))
          (set! index (+ index 1))))
      out)))

(define (source-tool-test-strings2 [a : String] [b : String]) : process.ProcessStringList
  (process.args-cons a (process.args-single b)))

;; A dependency section: one library, search path, raw argument and two
;; archives, each declared by a package.
(define (source-tool-dependency-section-inputs) : build_run.SourceToolLinkInputs
  (build_run.source-tool-link-inputs-add-origin
    (build_run.source-tool-link-inputs-merge
      (build_run.source-tool-link-inputs-add-raw-arg
        (build_run.source-tool-link-inputs-add-search-dir
          (build_run.source-tool-link-inputs-add-lib
            (build_run.source-tool-link-inputs-empty)
            "m")
          "native dir")
        "-Wl,--as-needed")
      (build_run.source-tool-link-inputs-from-archives
        (source-tool-test-strings2 "wa.a" "wb.a")))
    "library"
    "m"
    "package `wa` (wa/typelisp.pkg) field `linux-libraries`"))

;; Linux groups the dependency section so archives and libraries resolve in any
;; order; without archives the command keeps its historical shape. Windows
;; appends the archives after the raw arguments.
(define (source-tool-link-dependency-rendering-smoke-ok?) : bool
  (let
    [inputs : build_run.SourceToolLinkInputs
      (source-tool-dependency-section-inputs)]
    [linux : process.ProcessStringList
      (build_run.source-tool-link-inputs-linux-args
        (owned_view.compiler-owned-shared-view inputs))]
    [windows : process.ProcessStringList
      (build_run.source-tool-link-inputs-windows-args
        (owned_view.compiler-owned-shared-view inputs))]
    [no-archives : process.ProcessStringList
      (build_run.source-tool-link-inputs-linux-args
        (build_run.source-tool-link-inputs-add-lib
          (build_run.source-tool-link-inputs-empty)
          "m"))]
    [expected-linux : cli_svec.Vec (cli_svec.new)]
    [expected-windows : cli_svec.Vec (cli_svec.new)]
    (begin
      (cli_svec.push-ref! (&mut expected-linux) "-Lnative dir")
      (cli_svec.push-ref! (&mut expected-linux) "-Wl,--start-group")
      (cli_svec.push-ref! (&mut expected-linux) "-lm")
      (cli_svec.push-ref! (&mut expected-linux) "-Wl,--as-needed")
      (cli_svec.push-ref! (&mut expected-linux) "wa.a")
      (cli_svec.push-ref! (&mut expected-linux) "wb.a")
      (cli_svec.push-ref! (&mut expected-linux) "-Wl,--end-group")
      (cli_svec.push-ref! (&mut expected-windows) "/LIBPATH:native dir")
      (cli_svec.push-ref! (&mut expected-windows) "m.lib")
      (cli_svec.push-ref! (&mut expected-windows) "-Wl,--as-needed")
      (cli_svec.push-ref! (&mut expected-windows) "wa.a")
      (cli_svec.push-ref! (&mut expected-windows) "wb.a")
      (and
        (source-tool-string-list-eq?
          linux
          (source-tool-test-list expected-linux))
        (source-tool-string-list-eq?
          windows
          (source-tool-test-list expected-windows))
        (source-tool-string-list-eq? no-archives (process.args-single "-lm"))))))

;; Libraries, search paths and archives merge once; raw arguments merge once
;; only when asked, since another package's copy may be half of a positional
;; pair; every origin is kept.
(define (source-tool-link-dependency-merge-smoke-ok?) : bool
  (let
    [left : build_run.SourceToolLinkInputs
      (source-tool-dependency-section-inputs)]
    [right : build_run.SourceToolLinkInputs
      (source-tool-dependency-section-inputs)]
    [kept : build_run.SourceToolLinkInputs
      (build_run.source-tool-link-inputs-merge-with
        (owned_view.compiler-owned-shared-view left)
        (owned_view.compiler-owned-shared-view right)
        false)]
    [deduped : build_run.SourceToolLinkInputs
      (build_run.source-tool-link-inputs-merge-with left right true)]
    [origins : build_run.SourceToolLinkOrigins
      (build_run.source-tool-link-inputs-origins (& kept))]
    (and
      (source-tool-string-list-eq?
        (build_run.source-tool-link-inputs-libs (& kept))
        (process.args-single "m"))
      (source-tool-string-list-eq?
        (build_run.source-tool-link-inputs-search-dirs (& kept))
        (process.args-single "native dir"))
      (source-tool-string-list-eq?
        (build_run.source-tool-link-inputs-archives (& kept))
        (source-tool-test-strings2 "wa.a" "wb.a"))
      (source-tool-string-list-eq?
        (build_run.source-tool-link-inputs-raw-args (& kept))
        (source-tool-test-strings2 "-Wl,--as-needed" "-Wl,--as-needed"))
      (source-tool-string-list-eq?
        (build_run.source-tool-link-inputs-raw-args (& deduped))
        (process.args-single "-Wl,--as-needed"))
      (= (process.args-count origins.kinds) 2))))

;; A linker's missing-library report names the declarations that asked for it
;; and the quoted search paths; other failures get no notes.
(define (source-tool-link-failure-notes-smoke-ok?) : bool
  (let
    [inputs : build_run.SourceToolLinkInputs
      (build_run.source-tool-link-inputs-add-search-dir
        (source-tool-dependency-section-inputs)
        "it's")]
    [gnu : String "/usr/bin/ld: cannot find -lm: No such file or directory\n"]
    [lld : String "ld.lld: error: unable to find library -lm\n"]
    [msvc : String
      "LINK : fatal error LNK1181: cannot open input file 'm.lib'\n"]
    [other : String "/usr/bin/ld: main.o: undefined reference to `f'\n"]
    [expected : String
      "\nnote: native library `m` is required by package `wa` (wa/typelisp.pkg) field `linux-libraries`\nnote: search paths: 'native dir' 'it'\\''s' and the linker's defaults"]
    (and
      (string.eq
        (build_run.source-tool-link-failure-notes (& gnu) (& inputs))
        (& expected))
      (string.eq
        (build_run.source-tool-link-failure-notes (& lld) (& inputs))
        (& expected))
      (string.eq
        (build_run.source-tool-link-failure-notes (& msvc) (& inputs))
        (& expected))
      (string.eq
        (build_run.source-tool-link-failure-notes (& other) (& inputs))
        "")
      (string.eq
        (build_run.source-tool-missing-library-in-line "cannot find -l")
        "")
      (string.eq
        (build_run.source-tool-missing-library-in-line
          "cannot open input file 'x.obj'")
        "x.obj"))))

(define (source-tool-link-dependency-section-smoke-ok?) : bool
  (and
    (source-tool-link-dependency-rendering-smoke-ok?)
    (source-tool-link-dependency-merge-smoke-ok?)
    (source-tool-link-failure-notes-smoke-ok?)))