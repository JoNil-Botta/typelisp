;; compiler_runtime_bindings_tests.tl - The runtime binding table against its
;; producers and the Windows object route (#8318).
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.test)
(import compiler_runtime_bindings as bindings)
(import compiler_backend_runtime_common as runtime_common)
(import compiler_backend_runtime_windows as runtime_windows)
(import compiler_backend_object_target as object_target)
(import compiler_backend_object_target_windows as object_windows)
(import compiler_backend as backend)
(import compiler_object as cobj)
(import compiler_windows_coff_core as coff)

;; The external names the object ABI fixtures call (the COFF batch gate's
;; eleven-argument `nt_create_file` program and the relocation-gate smoke in
;; build_run_core_tests): their only producer outside the runtime.
(define (runtime-bindings-test-fixture-externs) : String
  "NtCreateFile\n")

;; --- a small name set: one `\n`-terminated name per entry -----------------
(define (runtime-bindings-test-set-has?
  [set : (& set str)]
  [name : (& name str)]) : bool
  (let
    [needle : String (str_cat.str-cat "\n" (string.copy name) "\n")]
    [haystack : String (str_cat.str-cat "\n" (string.copy set))]
    [n : i64 (string.string-length (& needle))]
    [limit : i64 (- (string.string-length (& haystack)) n)]
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (<= index limit))
      (when
        (string.eq (string.substring (& haystack) index n) needle)
        (set! found true))
      (set! index (+ index 1)))
    found))

(define (runtime-bindings-test-set-add [set : String] [name : String]) : String
  (if (runtime-bindings-test-set-has? (& set) (& name))
    set
    (str_cat.str-cat set name "\n")))

(define (runtime-bindings-test-identifier-char? [c : char]) : bool
  (or
    (and (>= c 'a') (<= c 'z'))
    (and (>= c 'A') (<= c 'Z'))
    (and (>= c '0') (<= c '9'))
    (= c '_')
    (= c '.')
    (= c '$')))

;; The identifier at `start` of `text`.
(define (runtime-bindings-test-word [text : (& text str)] [start : i64]) : String
  (let
    [end : i64 start]
    (while (and
      (< end (string.string-length text))
      (runtime-bindings-test-identifier-char? (string.char-at text end)))
      (set! end (+ end 1)))
    (string.substring text start (- end start))))

;; Names `.extern`-declared, defined as labels, and called or jumped to in
;; assembly `text`, as three sets.
(defstruct RuntimeBindingsTestScan
  (externs String)
  (labels String)
  (calls String))

(define (runtime-bindings-test-scan [text : (& text str)]) : RuntimeBindingsTestScan
  (let
    [length : i64 (string.string-length text)]
    [start : i64 0]
    [externs : String ""]
    [labels : String ""]
    [calls : String ""]
    (while (< start length)
      (let
        [end : i64 (bindings.compiler-runtime-binding-line-end text start)]
        [first : i64 start]
        (while (and
          (< first end)
          (or
            (= (string.char-at text first) ' ')
            (= (string.char-at text first) '\t')))
          (set! first (+ first 1)))
        (let
          [word : String (runtime-bindings-test-word text first)]
          [after : i64 (+ first (string.string-length (& word)))]
          (cond
            [(string.eq word ".extern")
              (set!
                externs
                (runtime-bindings-test-set-add
                  externs
                  (runtime-bindings-test-word text (+ after 1))))]
            [(or (string.eq word "call") (string.eq word "jmp"))
              (let
                [target : String (runtime-bindings-test-word text (+ after 1))]
                (when
                  (> (string.string-length (& target)) 0)
                  (set! calls (runtime-bindings-test-set-add calls target))))]
            [(and
                (> (string.string-length (& word)) 0)
                (< after end)
                (= (string.char-at text after) ':'))
              (set! labels (runtime-bindings-test-set-add labels word))]
            [else unit]))
        (set! start (+ end 1))))
    (RuntimeBindingsTestScan externs labels calls)))

(define (runtime-bindings-test-features [on : bool] [startup-profile : bool]) : runtime_common.CompilerBackendRuntimeFeatures
  (runtime_common.CompilerBackendRuntimeFeatures
    on
    on
    on
    on
    on
    on
    startup-profile
    on
    (if on
      -1
      0)))

(define (runtime-bindings-test-runtime-text
  [features : runtime_common.CompilerBackendRuntimeFeatures]) : String
  (str_cat.str-cat
    (runtime_windows.compiler-backend-runtime-functions (& features))
    (runtime_windows.compiler-backend-runtime-externs (& features))))

;; A name the compiler's own program output defines: `main`, or a TypeLisp
;; runtime label.
(define (runtime-bindings-test-program-name? [name : (& name str)]) : bool
  (or
    (string.eq name "main")
    (and
      (>= (string.string-length name) 3)
      (string.eq (string.substring name 0 3) "tl_"))
    (and
      (>= (string.string-length name) 4)
      (string.eq (string.substring name 0 4) "_tl_"))))

;; Every external name the Windows runtime text uses with `features`: its
;; `.extern` declarations and the calls and jumps to names it does not define.
(define (runtime-bindings-test-runtime-externals
  [features : runtime_common.CompilerBackendRuntimeFeatures]) : String
  (let
    [text : String (runtime-bindings-test-runtime-text features)]
    [scan : RuntimeBindingsTestScan (runtime-bindings-test-scan (& text))]
    [out : String scan.externs]
    [start : i64 0]
    [calls : String scan.calls]
    (while (< start (string.string-length (& calls)))
      (let
        [end : i64 (bindings.compiler-runtime-binding-line-end (& calls) start)]
        [name : String (string.substring (& calls) start (- end start))]
        (unless
          (or
            (runtime-bindings-test-set-has? (& scan.labels) (& name))
            (runtime-bindings-test-program-name? (& name)))
          (set! out (runtime-bindings-test-set-add out name)))
        (set! start (+ end 1))))
    out))

;; The external symbols the Windows object startup declares.
(define (runtime-bindings-test-startup-externals) : String
  (let
    [image : cobj.CompilerObjectImage
      (object_windows.compiler-backend-object-target-windows-image
        (object_target.compiler-backend-object-parts-empty)
        false
        true
        false)]
    [count : i64 (cobj.compiler-object-symbol-list-count (& image.symbols))]
    [index : i64 0]
    [out : String ""]
    (while (< index count)
      (match (cobj.compiler-object-symbol-list-ref (& image.symbols) index)
        [(Symbol name (Extern) _ _)
          (set! out (runtime-bindings-test-set-add out name))]
        [_ unit])
      (set! index (+ index 1)))
    out))

;; The binding table's rows for `target` with `feature` (or any feature for
;; ""), as a name set.
(define (runtime-bindings-test-rows-in
  [text : (& text str)]
  [target : String]
  [feature : String]) : String
  (let
    [start : i64 0]
    [out : String ""]
    (while (< start (string.string-length text))
      (let
        [end : i64 (bindings.compiler-runtime-binding-line-end text start)]
        (when
          (and
            (string.eq
              (bindings.compiler-runtime-binding-field text start end 0)
              target)
            (or
              (= (string.string-length (& feature)) 0)
              (string.eq
                (bindings.compiler-runtime-binding-field text start end 4)
                feature)))
          (set!
            out
            (runtime-bindings-test-set-add
              out
              (bindings.compiler-runtime-binding-field text start end 1))))
        (set! start (+ end 1))))
    out))

(define (runtime-bindings-test-rows [target : String] [feature : String]) : String
  (runtime-bindings-test-rows-in
    (& bindings.compiler-runtime-bindings-text)
    target
    feature))

;; The first name of `names` that `set` lacks, or "".
(define (runtime-bindings-test-first-missing
  [names : (& names str)]
  [set : (& set str)]) : String
  (let
    [start : i64 0]
    [missing : String ""]
    (while (and
      (< start (string.string-length names))
      (= (string.string-length (& missing)) 0))
      (let
        [end : i64 (bindings.compiler-runtime-binding-line-end names start)]
        [name : String (string.substring names start (- end start))]
        (unless
          (runtime-bindings-test-set-has? set (& name))
          (set! missing name))
        (set! start (+ end 1))))
    missing))

(define (runtime-bindings-test-union [a : (& a str)] [b : (& b str)]) : String
  (let
    [out : String (string.copy a)]
    [start : i64 0]
    (while (< start (string.string-length b))
      (let
        [end : i64 (bindings.compiler-runtime-binding-line-end b start)]
        (set!
          out
          (runtime-bindings-test-set-add
            out
            (string.substring b start (- end start))))
        (set! start (+ end 1))))
    out))

(define (runtime-bindings-test-error [text : (& text str)]) : String
  (bindings.compiler-runtime-bindings-error text))

(test
  runtime-bindings-table-valid
  (test.assert-true
    (string.eq
      (bindings.compiler-runtime-bindings-error
        (& bindings.compiler-runtime-bindings-text))
      "")
    "the shipped binding table validates"))

(test
  runtime-bindings-reject-malformed-rows
  (let
    [row : String
      "windows-x86_64\tGetStdHandle\tfunction\tkernel32.lib\talways\tobject"]
    (test.assert-true
      (string.eq (runtime-bindings-test-error (& row)) "")
      "one valid row")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "linux-x86_64\tfoo\tdata\t-\talways\tassembly\n")
        "")
      "a Linux row names no provider")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "windows-x86_64\tGetStdHandle\tfunction\tkernel32.lib\talways")
        "row 1: expected 6 tab-separated fields")
      "five fields")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "windows-x86_64\tGetStdHandle\tfunction\tkernel32.lib\talways\tobject\textra")
        "row 1: expected 6 tab-separated fields")
      "seven fields")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "macos-arm64\tGetStdHandle\tfunction\tkernel32.lib\talways\tobject")
        "row 1: unknown target")
      "unknown target")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "windows-x86_64\t\tfunction\tkernel32.lib\talways\tobject")
        "row 1: empty name")
      "empty name")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "windows-x86_64\tGetStdHandle\tvariable\tkernel32.lib\talways\tobject")
        "row 1: unknown kind")
      "unknown kind")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "windows-x86_64\tGetStdHandle\tfunction\tkernel32.dll\talways\tobject")
        "row 1: unknown provider")
      "a Windows provider is an import library")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "windows-x86_64\tGetStdHandle\tfunction\t.lib\talways\tobject")
        "row 1: unknown provider")
      "an import library has a name")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "linux-x86_64\tfoo\tdata\tlibc.so\talways\tobject")
        "row 1: unknown provider")
      "a Linux row names no provider")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "windows-x86_64\tGetStdHandle\tfunction\tkernel32.lib\tsometimes\tobject")
        "row 1: unknown feature")
      "unknown feature")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          "windows-x86_64\tGetStdHandle\tfunction\tkernel32.lib\talways\tmaybe")
        "row 1: unknown route")
      "unknown route")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          (&
            (str_cat.str-cat
              (string.copy (& row))
              "\nwindows-x86_64\tGetLastError\tfunction\tkernel32.lib\talways\tassembly\n"
              (string.copy (& row))
              "\n")))
        "row 3: duplicate binding GetStdHandle")
      "a name bound twice on one target")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          (&
            (str_cat.str-cat
              (string.copy (& row))
              "\nlinux-x86_64\tGetStdHandle\tfunction\t-\talways\tassembly\n")))
        "")
      "the same name on another target is a separate binding")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-error
          (&
            (str_cat.str-cat (string.copy (& row)) "\n\n" (string.copy (& row)))))
        "row 2: empty row")
      "an empty row")))

(test
  runtime-bindings-route-lookup
  (test.assert-true
    (bindings.compiler-runtime-binding-object-route?
      "windows-x86_64"
      "GetStdHandle"
      "function")
    "an admitted function")
  (test.assert-true
    (bindings.compiler-runtime-binding-object-route?
      "windows-x86_64"
      "NtCreateFile"
      "function")
    "the ABI fixture's function")
  (test.assert-false
    (bindings.compiler-runtime-binding-object-route?
      "windows-x86_64"
      "GetLastError"
      "function")
    "a declared binding is not admitted to the object route by its row")
  (test.assert-true
    (string.eq
      (bindings.compiler-runtime-binding-route
        (& bindings.compiler-runtime-bindings-text)
        "windows-x86_64"
        "GetLastError"
        "function")
      "assembly")
    "GetLastError is an assembly-route binding")
  (test.assert-false
    (bindings.compiler-runtime-binding-object-route?
      "windows-x86_64"
      "GetStdHandle"
      "data")
    "the kind must match")
  (test.assert-false
    (bindings.compiler-runtime-binding-object-route?
      "windows-x86_64"
      "NtOpenFile"
      "function")
    "an undeclared name")
  (test.assert-false
    (bindings.compiler-runtime-binding-object-route?
      "linux-x86_64"
      "GetStdHandle"
      "function")
    "Linux declares no bindings"))

;; Every name the runtime text, the object startup or an ABI fixture uses has a
;; row, and every row has such a producer: a new `.extern`, call or startup
;; import fails here until it is declared, and so does a row nothing uses.
(test
  runtime-bindings-producers-match-table
  (let
    [plain : String
      (runtime-bindings-test-runtime-externals
        (runtime-bindings-test-features false false))]
    [all : String
      (runtime-bindings-test-runtime-externals
        (runtime-bindings-test-features true true))]
    [startup : String (runtime-bindings-test-startup-externals)]
    [fixtures : String (runtime-bindings-test-fixture-externs)]
    [runtime-and-startup : String
      (runtime-bindings-test-union (& all) (& startup))]
    [plain-and-startup : String
      (runtime-bindings-test-union (& plain) (& startup))]
    [produced : String
      (runtime-bindings-test-union (& runtime-and-startup) (& fixtures))]
    [rows : String (runtime-bindings-test-rows "windows-x86_64" "")]
    [unbound : String
      (runtime-bindings-test-first-missing (& produced) (& rows))]
    [orphan : String
      (runtime-bindings-test-first-missing (& rows) (& produced))]
    (test.assert-true
      (string.eq unbound "")
      (str_cat.str-cat "an external name without a binding row: " unbound))
    (test.assert-true
      (string.eq orphan "")
      (str_cat.str-cat "a binding row no producer uses: " orphan))
    (test.assert-true
      (runtime-bindings-test-set-has? (& all) "GetCommandLineA")
      "the runtime text calls GetCommandLineA without declaring it")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-first-missing
          (& (runtime-bindings-test-rows "windows-x86_64" "always"))
          (& plain-and-startup))
        "")
      "an `always` row is used without optional runtime features")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-first-missing
          (& (runtime-bindings-test-rows "windows-x86_64" "startup-profile"))
          (& plain-and-startup))
        "QueryPerformanceCounter")
      "a `startup-profile` row is only used with that feature")
    (test.assert-true
      (string.eq
        (runtime-bindings-test-first-missing
          (& (runtime-bindings-test-rows "windows-x86_64" "abi-fixture"))
          (& runtime-and-startup))
        "NtCreateFile")
      "an `abi-fixture` row is used by no runtime or startup text")
    (test.assert-true
      (string.eq (runtime-bindings-test-rows "linux-x86_64" "") "")
      "Linux has no rows")))

(test
  runtime-bindings-startup-imports-are-object-route
  (let
    [startup : String (runtime-bindings-test-startup-externals)]
    [start : i64 0]
    (test.assert-true
      (> (string.string-length (& startup)) 0)
      "startup imports")
    (while (< start (string.string-length (& startup)))
      (let
        [end : i64
          (bindings.compiler-runtime-binding-line-end (& startup) start)]
        [name : String (string.substring (& startup) start (- end start))]
        (test.assert-true
          (bindings.compiler-runtime-binding-object-route?
            "windows-x86_64"
            (& name)
            "function")
          (str_cat.str-cat "a startup import outside the object route: " name))
        (set! start (+ end 1))))))

(test
  runtime-bindings-providers-feed-link-libs
  (let
    [windows : (__tl_dyn-array String)
      (bindings.compiler-runtime-binding-providers "windows-x86_64")]
    [linux : (__tl_dyn-array String)
      (bindings.compiler-runtime-binding-providers "linux-x86_64")]
    (test.assert-true (= (array-length windows) 2) "two Windows providers")
    (test.assert-true
      (string.eq (array-ref windows 0) "kernel32.lib")
      "kernel32.lib first")
    (test.assert-true
      (string.eq (array-ref windows 1) "ntdll.lib")
      "then ntdll.lib")
    (test.assert-true (= (array-length linux) 0) "no Linux providers")))

;; --- the Windows object route ----------------------------------------------
(define (runtime-bindings-test-image [source : String]) : cobj.CompilerObjectImage
  (match (backend.compiler-backend-emit-source-object-image-for-target
    source
    (Windows))
    [(Ok image) image]
    [(Err _) (io.panic "the object image did not build")]))

(define (runtime-bindings-test-extern-program [symbol : String]) : String
  (str_cat.str-cat
    "(extern (win-external [kind : i64]) : u64 (:symbol \""
    symbol
    "\"))\n\n(define (main) : i64\n  (cast (win-external -11) : i64))"))

(test
  runtime-bindings-object-route-admits-declared-externals
  (match (coff.compiler-windows-coff-linkability
    (runtime-bindings-test-image
      (runtime-bindings-test-extern-program "GetStdHandle")))
    [(Linkable) unit]
    [(Unavailable reason)
      (io.panic
        (str_cat.str-cat
          "GetStdHandle should link: "
          (backend.compiler-direct-object-fallback-transcript reason)))]))

(test
  runtime-bindings-object-route-rejects-undeclared-external
  (match (coff.compiler-windows-coff-linkability
    (runtime-bindings-test-image
      (runtime-bindings-test-extern-program "CreateFileW")))
    [(Unavailable (UndeclaredExternal section label offset symbol))
      (test.assert-true (string.eq section ".text") "in .text")
      (test.assert-true
        (> (string.string-length (& label)) 0)
        "the containing label")
      (test.assert-true (>= offset 0) "the label's offset")
      (test.assert-true
        (string.eq symbol "CreateFileW")
        "the undeclared symbol")
      (test.assert-true
        (string.eq
          (backend.compiler-direct-object-fallback-category
            (UndeclaredExternal section label offset symbol))
          "unsupported-external-relocation")
        "the batch plan keeps its reason")]
    [(Unavailable reason)
      (io.panic
        (str_cat.str-cat
          "unexpected fallback: "
          (backend.compiler-direct-object-fallback-transcript reason)))]
    [(Linkable) (io.panic "an undeclared external must not link")]))

(test
  runtime-bindings-object-route-rejects-assembly-binding
  (match (coff.compiler-windows-coff-linkability
    (runtime-bindings-test-image
      (runtime-bindings-test-extern-program "GetLastError")))
    [(Unavailable (UndeclaredExternal _ _ _ symbol))
      (test.assert-true
        (string.eq symbol "GetLastError")
        "a declared assembly-route binding is not object-linkable")]
    [_ (io.panic "GetLastError must stay on the assembly route")]))

;; A runtime definition the image plans as a local symbol but never
;; materializes is rejected by the image's own target resolution, even under a
;; name the table admits: the table speaks only for external symbols. The
;; program's GetStdHandle becomes a local symbol in `section`.
(define (runtime-bindings-test-planned-local-linkability
  [section : cobj.CompilerObjectMaybeSection]) : coff.CompilerWindowsCoffLinkability
  (let
    [image : cobj.CompilerObjectImage
      (runtime-bindings-test-image
        (runtime-bindings-test-extern-program "GetStdHandle"))]
    [symbols : cobj.CompilerObjectSymbolList image.symbols]
    [symbol-count : i64 (cobj.compiler-object-symbol-list-count (& symbols))]
    [symbol-builder : cobj.CompilerObjectSymbolBuilder
      (cobj.compiler-object-symbol-builder-with-capacity symbol-count)]
    [index : i64 0]
    (while (< index symbol-count)
      (match (cobj.compiler-object-symbol-list-ref (& symbols) index)
        [(Symbol name binding kind symbol-section)
          (let
            [planned? : bool (string.eq name "GetStdHandle")]
            (set!
              symbol-builder
              (cobj.compiler-object-symbol-builder-push
                symbol-builder
                (if planned?
                  (Symbol name (Local) (Runtime) section)
                  (Symbol name binding kind symbol-section)))))])
      (set! index (+ index 1)))
    (coff.compiler-windows-coff-linkability
      (cobj.CompilerObjectImage
        image.sections
        (cobj.compiler-object-symbol-builder-finish symbol-builder)
        image.relocations))))

(test
  runtime-bindings-unmaterialized-local-definition
  (match (runtime-bindings-test-planned-local-linkability No)
    [(Unavailable (UnsupportedCoffImage)) unit]
    [_ (io.panic "a local definition with no section must not link")])
  (match (runtime-bindings-test-planned-local-linkability (Some (Text)))
    [(Unavailable (UnsupportedCoffImage)) unit]
    [_ (io.panic "a local definition with no .text label must not link")]))