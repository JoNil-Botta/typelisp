;; compiler_typecheck.tl - First scalar typechecker pass over compiler AstProgram (#426).
(import "../stdlib/io.tl")
(import "compiler_typecheck_core.tl")
(import "compiler_load.tl")
(import "compiler_specialize.tl")
(import "../stdlib/string.tl")
(import "../stdlib/str_cat.tl")

(define (compiler-typecheck-prefix-cache-scope
  [kind : String]
  [stdlib-roots : StringVec]
  [cfgs : SymI64Env]) : String
  (compiler-load-prelude-cache-key kind stdlib-roots cfgs))

(define (typecheck-compiler-program-with-paths-cache
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : StringVec]
  [cache-scope : String]) : ResultCompilerTypecheck
  ;; Generate declaration families (e.g. hashmap) before macro expansion. Macro
  ;; expansion type-directs some sub-expressions (let-init / match-scrutinee
  ;; typing), which must be able to see generated functions; the later template
  ;; specialization pass would otherwise produce them too late and any program
  ;; that both defines a macro and uses a generated function would fail to
  ;; typecheck. The downstream specialize call re-normalizes harmlessly.
  (begin
    (tc-spmd-inline-helper-stack-reset!)
    (tc-typecheck-result-with-pool-check
      (match (gen-normalize-program-with-paths program paths "")
        [(OkGenProgramWithPaths generated generated-paths)
          (match (macro-expand-program-with-paths generated generated-paths)
            [(OkMacroExpand expanded expanded-paths)
              (if (compiler-specialize-needed? expanded)
                (match (build-compiler-symbols-with-paths
                  expanded
                  expanded-paths)
                  [(OkCompilerSymbols _)
                    (match (compiler-specialize-program expanded)
                      [(OkSpecProgram specialized)
                        (typecheck-compiler-specialized-program-with-paths-cache
                          specialized
                          AstDeclPathNil
                          stdlib-roots
                          cache-scope)]
                      [(ErrSpecProgram diag) (ErrCompilerTypecheck diag)])]
                  [(ErrCompilerSymbols message)
                    (ErrCompilerTypecheck (tc-diag-at-start message))])
                (typecheck-compiler-specialized-program-with-paths-cache
                  expanded
                  expanded-paths
                  stdlib-roots
                  cache-scope))]
            [(ErrMacroExpand diag) (ErrCompilerTypecheck diag)])]
        [(ErrGenProgramWithPaths diag) (ErrCompilerTypecheck diag)]))))

(define (typecheck-compiler-program-with-paths
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths-cache
    program
    paths
    (string-vec-new)
    (tc-prefix-default-cache-scope)))

(define (typecheck-compiler-program-with-paths-checked-cache
  [program : AstProgram]
  [paths : AstDeclPathList]
  [stdlib-roots : StringVec]
  [cache-scope : String]) : ResultCompilerTypecheckChecked
  (begin
    (tc-spmd-inline-helper-stack-reset!)
    (match (gen-normalize-program-with-paths program paths "")
      [(OkGenProgramWithPaths generated generated-paths)
        (match (macro-expand-program-with-paths generated generated-paths)
          [(OkMacroExpand expanded expanded-paths)
            (if (compiler-specialize-needed? expanded)
              (match (build-compiler-symbols-with-paths expanded expanded-paths)
                [(OkCompilerSymbols _)
                  (match (compiler-specialize-program expanded)
                    [(OkSpecProgram specialized)
                      (typecheck-compiler-specialized-program-with-paths-checked-cache
                        specialized
                        AstDeclPathNil
                        stdlib-roots
                        cache-scope)]
                    [(ErrSpecProgram diag) (ErrCompilerTypecheckChecked diag)])]
                [(ErrCompilerSymbols message)
                  (ErrCompilerTypecheckChecked (tc-diag-at-start message))])
              (typecheck-compiler-specialized-program-with-paths-checked-cache
                expanded
                expanded-paths
                stdlib-roots
                cache-scope))]
          [(ErrMacroExpand diag) (ErrCompilerTypecheckChecked diag)])]
      [(ErrGenProgramWithPaths diag) (ErrCompilerTypecheckChecked diag)])))

(define (typecheck-compiler-program-with-paths-checked
  [program : AstProgram]
  [paths : AstDeclPathList]) : ResultCompilerTypecheckChecked
  (typecheck-compiler-program-with-paths-checked-cache
    program
    paths
    (string-vec-new)
    (tc-prefix-default-cache-scope)))

(define (typecheck-compiler-program [program : AstProgram]) : ResultCompilerTypecheck
  (typecheck-compiler-program-with-paths program AstDeclPathNil))

(define (typecheck-compiler-repl-expr [decls : AstDeclList] [expr : AstExpr]) : ResultTcType
  (let
    [program : AstProgram (ast-program decls)]
    (begin
      (tc-clone-able-cache-reset!)
      (macro-alias-cache-reset!)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (match (build-compiler-exports-with program symbols registries)
                [(OkCompilerExports _)
                  (let
                    [ctx : TcContext (TcContext program symbols registries "")]
                    (match (tc-program-source-types-policy-ok ctx program)
                      [(OkTcUnit)
                        (match (tc-source-expr-policy-ok ctx expr)
                          [(OkTcUnit)
                            (match (tc-build-top-env ctx program)
                              [(OkTcEnv top-env)
                                (match (tc-check-decls
                                  ctx
                                  top-env
                                  decls
                                  (CompilerTypecheckSummary 0 0 0))
                                  [(OkCompilerTypecheck _)
                                    (tc-expr ctx top-env expr)]
                                  [(ErrCompilerTypecheck diag)
                                    (ErrTcType
                                      (compiler-diagnostic-message diag))])]
                              [(ErrTcEnv message) (ErrTcType message)])]
                          [(ErrTcUnit message) (ErrTcType message)])]
                      [(ErrTcUnit message) (ErrTcType message)]))]
                [(ErrCompilerExports message) (ErrTcType message)])]
            [(ErrCompilerRegistries message) (ErrTcType message)])]
        [(ErrCompilerSymbols message) (ErrTcType message)]))))

(define (typecheck-compiler-source [src : String]) : ResultCompilerTypecheck
  (match (parse-ast-source-diagnostic "" src)
    [(OkAstProgramDiagnostic program) (typecheck-compiler-program program)]
    [(ErrAstProgramDiagnostic diag) (ErrCompilerTypecheck diag)]))

(define (compiler-typecheck-with-io-source [src : String]) : String
  (string-append
    "(extern (print [arg0 : i64]) : unit)
(extern (print-bool [arg0 : bool]) : unit)
(extern (print-float [arg0 : f64]) : unit)
(extern (print-char [arg0 : char]) : unit)
(extern (print-newline) : unit)
(extern (print-string [arg0 : String]) : unit)
(extern (print-str [arg0 : String]) : unit)
(extern (print-error [arg0 : String]) : unit)
(extern (panic [arg0 : String]) : never)
(extern (error [arg0 : String]) : never)
(extern (arg-count) : i64)
(extern (arg [arg0 : i64]) : String)
(extern (read-file [arg0 : String]) : String)
(extern (read-file-status [arg0 : String]) : i64)
(extern (write-file [arg0 : String] [arg1 : String]) : unit)
(extern (write-file-status [arg0 : String] [arg1 : String]) : i64)
(extern (append-file-status [arg0 : String] [arg1 : String]) : i64)
(extern (file-exists? [arg0 : String]) : bool)
(extern (file-exists-status [arg0 : String]) : i64)
(extern (file-open-status [arg0 : String] [arg1 : i64]) : i64)
(extern (file-close-status [arg0 : i64]) : i64)
(extern (file-read-chunk-status [arg0 : i64] [arg1 : i64]) : i64)
(extern (file-write-status [arg0 : i64] [arg1 : String]) : i64)
(extern (file-flush-status [arg0 : i64]) : i64)
(extern (file-read-chunk-bytes [arg0 : i64]) : String)
(extern (file-read-chunk-eof? [arg0 : i64]) : bool)
(extern (read-stdin-line) : String)
(extern (read-stdin-bytes [arg0 : i64]) : String)
(extern (stdin-eof?) : bool)
(extern (flush-stdout) : unit)
"
    src))

(define (compiler-typecheck-with-alloc-string-helper-source [src : String]) : String
  (string-append
    "(define (int->string [value : i64]) : String
  (if (= value 0) \"0\" \"1\"))
(define (substring [text : String] [start : i64] [len : i64]) : String
  text)
(define (string-slice [text : String] [start : i64] [len : i64]) : String
  (substring text start len))
(define (string-append [left : String] [right : String]) : String
  left)
(define (string-concat [left : String] [right : String]) : String
  (string-append left right))
"
    src))

(define (compiler-typecheck-with-fs-source [src : String]) : String
  (compiler-typecheck-with-io-source
    (compiler-typecheck-with-alloc-string-helper-source
      (string-append
        "(extern (fs-mkdir-status [arg0 : String]) : i64)
(extern (fs-remove-file-status [arg0 : String]) : i64)
(extern (fs-remove-dir-status [arg0 : String]) : i64)
(extern (fs-rename-status [arg0 : String] [arg1 : String]) : i64)
(extern (fs-read-dir-status [arg0 : String]) : i64)
(extern (fs-read-dir [arg0 : String]) : String)
(extern (fs-file-kind-status [arg0 : String]) : i64)
(extern (fs-file-size-status [arg0 : String]) : i64)
(extern (fs-file-size [arg0 : String]) : i64)
(extern (fs-process-id) : i64)
(extern (fs-current-dir-status) : i64)
(extern (fs-current-dir) : String)
"
        src))))

(define (compiler-typecheck-with-cpu-source [src : String]) : String
  (string-append "(import \"stdlib/cpu.tl\")\n" src))

(define (compiler-typecheck-with-env-source [src : String]) : String
  (string-append
    "(define (env-var-exists? [name : String]) : bool true)
(define (env-var-value [name : String]) : String name)
(define (env-path-separator) : String \":\")
"
    src))

(define (compiler-typecheck-with-arena-source [src : String]) : String
  (string-append
    "(extern (tl_arena_make) : i64)
(extern (tl_arena_current) : i64)
(extern (tl_region_mark) : i64)
(unsafe (extern (tl_arena_set [arg0 : i64]) : unit))
(unsafe (extern (tl_arena_destroy [arg0 : i64]) : unit))
(unsafe (extern (tl_region_reset [arg0 : i64]) : unit))
(define (arena-make) : i64 (tl_arena_make))
(define (arena-current) : i64 (tl_arena_current))
(define (arena-mark) : i64 (tl_region_mark))
(unsafe (define (arena-set! [arena : i64]) : unit (unsafe (tl_arena_set arena))))
(unsafe (define (arena-destroy [arena : i64]) : unit (unsafe (tl_arena_destroy arena))))
(unsafe (define (arena-rewind [mark : i64]) : unit (unsafe (tl_region_reset mark))))
"
    (compiler-typecheck-with-alloc-string-helper-source src)))

(define (compiler-typecheck-smoke-source) : String
  "(extern (print-i64 [arg0 : i64]) : unit)
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main [flag : bool]) : i64
  (let
    [x : i64 (inc answer)]
    (begin
      (set! x (+ x 1))
      (if flag x 0))))")

(define (compiler-typecheck-summary-score [summary : CompilerTypecheckSummary]) : i64
  (match summary
    [(CompilerTypecheckSummary values functions externs)
      (+ values (+ (* functions 10) (* externs 100)))]))

(define (compiler-typecheck-error-ok? [src : String] [want : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-error-code-ok?
  [src : String]
  [want-code : String]
  [want-category : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (match (compiler-diagnostic-code diag)
        [(CompilerDiagnosticSomeString code)
          (if (string-eq code want-code)
            (match (compiler-diagnostic-category diag)
              [(CompilerDiagnosticSomeString category)
                (string-eq category want-category)]
              [CompilerDiagnosticNoString false])
            false)]
        [CompilerDiagnosticNoString false])]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-secondary-count
  [labels : CompilerDiagnosticLabelList]) : i64
  (match labels
    [(CompilerDiagnosticLabelNil) 0]
    [(CompilerDiagnosticLabelCons _ rest)
      (+ 1 (compiler-typecheck-secondary-count (box-get rest)))]))

(define (compiler-typecheck-help-present? [diag : CompilerDiagnostic]) : bool
  (match (compiler-diagnostic-help diag)
    [(CompilerDiagnosticSomeString _) true]
    [CompilerDiagnosticNoString false]))

(define (compiler-typecheck-error-shape-ok?
  [src : String]
  [want : String]
  [want-line : i64]
  [want-col : i64]
  [want-secondary-count : i64]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (and
        (string-eq (compiler-diagnostic-message diag) want)
        (= (compiler-diagnostic-line diag) want-line)
        (= (compiler-diagnostic-col diag) want-col)
        (=
          (compiler-typecheck-secondary-count
            (compiler-diagnostic-secondary-spans diag))
          want-secondary-count)
        (compiler-typecheck-help-present? diag))]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-program-error-ok?
  [program : AstProgram]
  [want : String]) : bool
  (match (typecheck-compiler-program program)
    [(ErrCompilerTypecheck diag)
      (string-eq (compiler-diagnostic-message diag) want)]
    [(OkCompilerTypecheck _) false]))

;; #2357: with the growing ty-node pool a compile that starts with the pool at
;; capacity grows the backing array and succeeds rather than failing closed with
;; an exhaustion diagnostic. Verify the typecheck still succeeds under that
;; pressure (and that the pool grew).
(define (compiler-typecheck-pool-exhaustion-diagnostic-ok?) : bool
  (let
    [capacity : i64 (ty-node-pool-capacity)]
    (begin
      (ty-node-pool-reset!)
      (ty-node-pool-truncate! capacity)
      (let
        [result : ResultCompilerTypecheck
          (typecheck-compiler-source "(define (main) : i64 0)")]
        [grew : bool (> (ty-node-pool-capacity) capacity)]
        [ok : bool
          (match result
            [(OkCompilerTypecheck _) grew]
            [(ErrCompilerTypecheck _) false])]
        (begin
          (ty-node-pool-reset!)
          ok)))))

(define (compiler-typecheck-prefix-cache-paths [entry-path : String]) : AstDeclPathList
  (ast-decl-path-cons
    "stdlib/tc_prefix_shared.tl"
    (ast-decl-path-cons entry-path AstDeclPathNil)))

(define (compiler-typecheck-prefix-cache-source-a) : String
  "(define (shared-helper [x : i64]) : i64 (+ x 1))
(define (main) : i64 (shared-helper 1))")

(define (compiler-typecheck-prefix-cache-source-b) : String
  "(define (shared-helper [x : i64]) : i64 (+ x 1))
(define (main) : i64 (shared-helper 2))")

(define (compiler-typecheck-prefix-cache-check
  [src : String]
  [entry-path : String]) : bool
  (match (parse-ast-source-diagnostic entry-path src)
    [(OkAstProgramDiagnostic program)
      (match (typecheck-compiler-program-with-paths
        program
        (compiler-typecheck-prefix-cache-paths entry-path))
        [(OkCompilerTypecheck _) true]
        [(ErrCompilerTypecheck _) false])]
    [(ErrAstProgramDiagnostic _) false]))

(define (compiler-typecheck-prefix-cache-smoke-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (compiler-load-session-cache-enable!)
      (tc-prefix-snapshot-cache-clear!)
      (if (compiler-typecheck-prefix-cache-check
        (compiler-typecheck-prefix-cache-source-a)
        "target/tc_prefix_entry_a.tl")
        unit
        (set! ok false))
      (compiler-load-session-reset-pools!)
      (compiler-load-session-reset-interns!)
      (if (compiler-typecheck-prefix-cache-check
        (compiler-typecheck-prefix-cache-source-b)
        "target/tc_prefix_entry_b.tl")
        unit
        (set! ok false))
      (if (> tc-prefix-snapshot-cache-hit-count 0)
        unit
        (set! ok false))
      (if (> tc-prefix-snapshot-cache-store-count 0)
        unit
        (set! ok false))
      (compiler-load-session-cache-disable-for-test!)
      (tc-prefix-snapshot-cache-clear!)
      ok)))

(define (compiler-typecheck-prefix-cache-stats-smoke-ok?) : bool
  (begin
    (tc-prefix-snapshot-cache-clear!)
    (tc-prefix-snapshot-cache-note-hit!)
    (tc-prefix-snapshot-cache-note-miss!)
    (tc-prefix-snapshot-cache-note-store!)
    (let
      [line : String (tc-prefix-snapshot-cache-stats-line "smoke")]
      (begin
        (tc-prefix-snapshot-cache-stats-reset!)
        (and
          (string-eq
            line
            "typecheck-prefix-cache|smoke|hits=1|misses=1|stores=1|lookups=2|hit-rate-per-mille=500")
          (string-eq
            (tc-prefix-snapshot-cache-stats-line "reset")
            "typecheck-prefix-cache|reset|hits=0|misses=0|stores=0|lookups=0|hit-rate-per-mille=0"))))))

(define (compiler-typecheck-ok-score? [src : String] [want : i64]) : bool
  (match (typecheck-compiler-source src)
    [(OkCompilerTypecheck summary)
      (= (compiler-typecheck-summary-score summary) want)]
    [(ErrCompilerTypecheck _) false]))

(define (compiler-typecheck-ok? [src : String]) : bool
  (match (typecheck-compiler-source src)
    [(OkCompilerTypecheck _) true]
    [(ErrCompilerTypecheck _) false]))

(define (compiler-typecheck-unbound-source) : String
  "(define (main) : i64 missing)")

(define (compiler-typecheck-bad-call-source) : String
  "(define (id [x : i64]) : i64 x)
(define (main) : i64 (id true))")

(define (compiler-typecheck-branch-mismatch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 1 false))")

(define (compiler-typecheck-escape-return-diagnostic-source) : String
  "(define (main [n : i64]) : (& n i64)
  (let [x : i64 1] (& x)))")

(define (compiler-typecheck-escape-assignment-diagnostic-source) : String
  "(define (main [n : i64]) : i64
  (let
    [slot : (& n i64) (& n)]
    (let [n : i64 1] (set! slot (& n)))))")

(define (compiler-typecheck-escape-with-arena-diagnostic-source) : String
  "(define (int->string [value : i64]) : String
  (if (= value 0) \"0\" \"1\"))
(define (main) : String
  (with-arena phase (int->string 42)))")

(define (compiler-typecheck-escape-lambda-capture-diagnostic-source) : String
  "(define (take [r : (& n i64)]) : i64 1)
(define (main [n : i64]) : (-> i64)
  (let [r : (& n i64) (& n)]
    (lambda () : i64 (take r))))")

(define (compiler-typecheck-escape-diagnostic-tests-ok?) : bool
  (and
    (compiler-typecheck-error-shape-ok?
      (compiler-typecheck-escape-return-diagnostic-source)
      "typecheck: reference value would escape lexical scope"
      2
      3
      1)
    (compiler-typecheck-error-shape-ok?
      (compiler-typecheck-escape-assignment-diagnostic-source)
      "typecheck: cannot store reference into longer-lived binding; reference value would escape lexical scope"
      4
      22
      2)
    (compiler-typecheck-error-shape-ok?
      (compiler-typecheck-escape-with-arena-diagnostic-source)
      "typecheck: region-tagged value cannot escape with-arena 'phase'"
      4
      21
      1)
    (compiler-typecheck-error-shape-ok?
      (compiler-typecheck-escape-lambda-capture-diagnostic-source)
      "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope"
      4
      5
      1)))

(define (compiler-typecheck-diagnostic-code-tests-ok?) : bool
  (and
    (compiler-typecheck-error-code-ok?
      "(define (main) : i64 (+ 1))"
      (compiler-diagnostic-code-parse)
      "parse")
    (compiler-typecheck-error-code-ok?
      (compiler-typecheck-branch-mismatch-source)
      (compiler-diagnostic-code-typecheck)
      "typecheck")))

(define (compiler-typecheck-type-parameter-source) : String
  "(define (id [x : T]) : T x)")

(define (compiler-typecheck-aggregate-source) : String
  "(define (id-lambda [n : i64]) : i64
  (let
    [f : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x 1))]
    (f n)))
(define (main [n : i64] [s : String]) : i64
  (let
    [fixed : (Array i64 3) (array 1 2 3)]
    [t : (Tuple i64 bool) (tuple 7 true)]
    [a : (Array i64) (make-array i64 n)]
    (begin
      (array-set! a 0 (cast (string-ref s 0) : i64))
      (foreach ([i : i64 0 n])
        (array-set! a i (+ (array-ref a i) 1)))
      (+ (array-length a)
         (+ (tuple-ref t 0) (+ (array-ref fixed 1) (id-lambda 3)))))))")

(define (compiler-typecheck-builtin-source) : String
  (compiler-typecheck-with-fs-source
    "(define (main [s : String]) : String
  (begin
    (fs-mkdir-status s)
    (fs-remove-file-status s)
    (fs-remove-dir-status s)
    (fs-rename-status s s)
    (fs-read-dir-status s)
    (fs-file-kind-status s)
    (fs-file-size-status s)
    (fs-file-size s)
    (fs-process-id)
    (fs-current-dir-status)
    (string-length (fs-current-dir))
    (string-append (fs-read-dir s)
      (string-append (substring s 0 (length s))
                    (int->string (string->int \"7\"))))))"))

(define (compiler-typecheck-stdio-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (string-length (read-stdin-line))
        (string-length (read-stdin-bytes 3)))))"))

(define (compiler-typecheck-env-source) : String
  (compiler-typecheck-with-env-source
    "(define (main [name : String]) : String
  (if (env-var-exists? name)
    (env-var-value name)
    (env-path-separator)))"))

(define (compiler-typecheck-env-missing-import-source) : String
  "(define (main [name : String]) : String
  (env-var-value name))")

(define (compiler-typecheck-tuple-oob-source) : String
  "(define (main) : i64 (tuple-ref (tuple 1 true) 2))")

(define (compiler-typecheck-array-mismatch-source) : String
  "(define bad : (Array i64 2) (array 1 true))")

(define (compiler-typecheck-string-index-source) : String
  "(define (main) : char (string-ref \"hi\" true))")

(define (compiler-typecheck-string-shadow-source) : String
  "(define (string-ref [a : i64] [b : i64]) : i64 (+ a b))
(define (char-at [a : i64] [b : i64]) : i64 (* a b))
(define (main) : i64 (+ (string-ref 10 7) (char-at 3 4)))")

(define (compiler-typecheck-char-range-source) : String
  "(define (is-digit [c : char]) : bool
  (if (>= c '0') (<= c '9') false))
(define (main [c : char]) : bool (is-digit c))")

(define (compiler-typecheck-never-branch-source) : String
  (compiler-typecheck-with-io-source
    "(define (main [flag : bool]) : i64
  (if flag 42 (panic \"stop\")))"))

(define (compiler-typecheck-return-source) : String
  "(define (main [flag : bool]) : i64
  (begin
    (if flag (return 7) unit)
    42))")

(define (compiler-typecheck-return-mismatch-source) : String
  "(define (main) : i64 (return true))")

(define (compiler-typecheck-return-outside-source) : String
  "(define answer : i64 (return 1))")

(define (compiler-typecheck-cast-bad-source) : String
  "(define (main) : i64 (cast true : i64))")

(define (compiler-typecheck-foreach-body-source) : String
  "(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n]) i))")

(define (compiler-typecheck-lambda-ret-source) : String
  "(define (main) : (-> i64 i64)
  (lambda ([x : i64]) : i64 true))")

(define (compiler-typecheck-clone-aggregate-source) : String
  "(defstruct Holder
  (name String)
  (fixed (Array String 2))
  (items (Array String))
  (pair (Tuple String String)))
(defenum StringList
  (SNil)
  (SCons String (Box StringList)))
(define (clone-tuple [items : (Array String)]) : (Tuple String (Array String))
  (clone (tuple \"tuple\" items)))
(define (clone-fixed) : (Array String 2)
  (clone (array \"left\" \"right\")))
(define (clone-dyn [items : (Array String)]) : (Array String)
  (clone items))
(define (clone-holder [items : (Array String)]) : Holder
  (clone (Holder \"holder\" (array \"x\" \"y\") items (tuple \"p\" \"q\"))))
(define (clone-list [list : StringList]) : StringList
  (clone list))
(define (main [items : (Array String)] [list : StringList]) : i64 0)")

(define (compiler-typecheck-clone-function-source) : String
  "(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : (-> i64 i64)
  (clone inc))")

(define (compiler-typecheck-clone-pointer-source) : String
  "(extern (raw-make) : (MutPtr i64))
(define (main) : (MutPtr i64)
  (unsafe (clone (raw-make))))")

(define (compiler-typecheck-clone-ref-source) : String
  "(define (main [n : i64]) : (& n i64)
  (clone (& n)))")

(define (compiler-typecheck-clone-tests-ok?) : bool
  (and
    (clone-name-set-smoke-ok?)
    (compiler-typecheck-ok? (compiler-typecheck-clone-aggregate-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-clone-function-source)
      "typecheck: clone unsupported type (-> i64 i64)")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-clone-pointer-source)
      "typecheck: clone unsupported type (MutPtr i64)")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-clone-ref-source)
      "typecheck: clone unsupported type (& n i64)")))

(define (compiler-typecheck-foreach-return-source) : String
  "(define (main [n : i64]) : i64
  (begin
    (foreach ([i : i64 0 n]) (return i))
    0))")

(define (compiler-typecheck-foreach-spmd-ok-source) : String
  "(define (main [n : i64]) : unit
  (let
    [a : (Array i64) (make-array i64 n)]
    [b : (Array i64) (make-array i64 n)]
    [out : (Array i64) (make-array i64 n)]
    (foreach ([i : i64 0 n])
      (let
        [sum : i64 (+ (array-ref a i) (array-ref b i))]
        (array-set! out i sum)))))")

(define (compiler-typecheck-foreach-spmd-f32-ok-source) : String
  "(define (main [n : i64]) : unit
  (let
    [a : (Array f32) (make-array f32 n)]
    [b : (Array f32) (make-array f32 n)]
    [out : (Array f32) (make-array f32 n)]
    (foreach ([i : i64 0 n])
      (let
        [sum : f32 (+ (array-ref a i) (array-ref b i))]
        (array-set! out i sum)))))")

(define (compiler-typecheck-foreach-spmd-i16-u16-ok-source) : String
  "(define (fill-i16 [a : (Array i16)] [b : (Array i16)] [out : (Array i16)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))
(define (fill-u16 [a : (Array u16)] [b : (Array u16)] [out : (Array u16)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (array-set! out i (+ (array-ref a i) (array-ref b i)))))")

(define (compiler-typecheck-foreach-varying-if-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (= (array-ref xs i) 0) unit unit)))")

(define (compiler-typecheck-foreach-varying-while-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (while (< (array-ref xs i) 0) unit)))")

(define (compiler-typecheck-foreach-inline-call-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (sink (array-ref xs i))))")

(define (compiler-typecheck-foreach-varying-call-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 unit) sink]
    (foreach ([i : i64 0 n])
      (f (array-ref xs i)))))")

(define (compiler-typecheck-foreach-outer-set-source) : String
  "(define (main [xs : (Array i64)] [n : i64]) : i64
  (let
    [sum : i64 0]
    (begin
      (foreach ([i : i64 0 n])
        (set! sum (+ sum (array-ref xs i))))
      sum)))")

(define (compiler-typecheck-foreach-unsupported-lane-source) : String
  "(define (main [ss : (Array String)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [s : String (array-ref ss i)]
      unit)))")

(define (compiler-typecheck-foreach-if-local-set-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [flag : bool] [n : i64]) : unit
  (let
    [f : (-> i64 unit) sink]
    (foreach ([i : i64 0 n])
      (let
        [x : i64 0]
        (begin
          (if flag (set! x (array-ref xs i)) unit)
          (f x))))))")

(define (compiler-typecheck-foreach-while-local-set-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [xs : (Array i64)] [flag : bool] [n : i64]) : unit
  (let
    [f : (-> i64 unit) sink]
    (foreach ([i : i64 0 n])
      (let
        [x : i64 0]
        (begin
          (while flag (set! x (array-ref xs i)))
          (f x))))))")

(define (compiler-typecheck-foreach-match-local-set-source) : String
  "(defenum Maybe (None) (Some i64))
(define (sink [x : i64]) : unit unit)
(define (main [m : Maybe] [xs : (Array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 unit) sink]
    (foreach ([i : i64 0 n])
      (let
        [x : i64 0]
        (begin
          (match m [(Some v) (set! x (array-ref xs i))] [None unit])
          (f x))))))")

(define (compiler-typecheck-foreach-local-set-ok-source) : String
  "(define (sink [x : i64]) : unit unit)
(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (set! x 1)
        (sink x)))))")

(define (compiler-typecheck-foreach-control-flow-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-foreach-local-set-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-if-local-set-source)
      "typecheck: foreach calls with varying arguments are not supported")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-while-local-set-source)
      "typecheck: foreach calls with varying arguments are not supported")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-match-local-set-source)
      "typecheck: foreach calls with varying arguments are not supported")))

(define (compiler-typecheck-foreach-spmd-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-foreach-spmd-ok-source))
    (compiler-typecheck-ok? (compiler-typecheck-foreach-spmd-f32-ok-source))
    (compiler-typecheck-ok? (compiler-typecheck-foreach-spmd-i16-u16-ok-source))
    (compiler-typecheck-ok? (compiler-typecheck-foreach-varying-if-source))
    (compiler-typecheck-ok? (compiler-typecheck-foreach-inline-call-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-varying-while-source)
      "typecheck: foreach while condition must be uniform")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-varying-call-source)
      "typecheck: foreach calls with varying arguments are not supported")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-outer-set-source)
      "typecheck: foreach cannot set binding declared outside foreach")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-unsupported-lane-source)
      "typecheck: foreach varying array lane type is not supported: String")
    (compiler-typecheck-foreach-control-flow-tests-ok?)))

(define (compiler-typecheck-return-tests-ok?) : bool
  (and
    (compiler-typecheck-ok-score? (compiler-typecheck-return-source) 10)
    (compiler-typecheck-error-ok?
      (compiler-typecheck-return-mismatch-source)
      "typecheck: return type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-return-outside-source)
      "typecheck: return requires enclosing function")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-return-source)
      "typecheck: return inside foreach is not supported")))

(define (compiler-typecheck-abstraction-policy-tests-ok?) : bool
  (compiler-typecheck-error-ok?
    (compiler-typecheck-type-parameter-source)
    (tc-source-type-policy-message "T")))

(define (compiler-typecheck-aggregate-tests-ok?) : bool
  (and
    (compiler-typecheck-ok-score? (compiler-typecheck-aggregate-source) 20)
    (compiler-typecheck-ok? (compiler-typecheck-builtin-source))
    (compiler-typecheck-ok? (compiler-typecheck-stdio-source))
    (compiler-typecheck-ok? (compiler-typecheck-env-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-env-missing-import-source)
      "typecheck: unbound name env-var-value")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-tuple-oob-source)
      "typecheck: tuple index out of bounds")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-array-mismatch-source)
      "typecheck: array elements must have same type")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-string-index-source)
      "typecheck: string index must be integer")
    (compiler-typecheck-ok-score? (compiler-typecheck-string-shadow-source) 30)
    (compiler-typecheck-error-ok?
      (compiler-typecheck-cast-bad-source)
      "typecheck: cast requires scalar numeric (integer/char/float) source and target")
    (compiler-typecheck-ok-score? (compiler-typecheck-char-range-source) 20)
    (compiler-typecheck-ok? (compiler-typecheck-never-branch-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-foreach-body-source)
      "typecheck: foreach body must be unit")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-lambda-ret-source)
      "typecheck: lambda return type mismatch")
    (compiler-typecheck-return-tests-ok?)))

(define (compiler-typecheck-nominal-source) : String
  "(defenum Maybe (None) (Some i64))
(defstruct Point (x i64) (y i64))
(define (from-maybe [m : Maybe]) : i64
  (match m [(Some v) v] [None 0]))
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (+ (struct-get p x) (from-maybe (Some (struct-get p y))))))")

(define (compiler-typecheck-comptime-decl-source) : String
  "(comptime-decl (defstruct Point (x i64) (y i64)))
(comptime-decl (defenum Maybe (None) (Some i64)))
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (match (Some (struct-get p y))
      [(Some n) (+ (struct-get p x) n)]
      [None 0])))")

(define (compiler-typecheck-generated-decl-source) : String
  "(comptime-decl (:generated point-family Point \"i64\")
  (defstruct Point (x i64)))
(comptime-decl (:generated make-point-family make-point \"i64\")
  (define (make-point [x : i64]) : Point (Point x)))
(define (main) : i64
  (struct-get (make-point 7) x))")

(define (compiler-typecheck-generated-decl-duplicate-visible-source) : String
  "(comptime-decl (:generated point-family Point \"left\")
  (defstruct Point (x i64)))
(comptime-decl (:generated point-family Point \"right\")
  (defstruct Point (x i64)))
(define (main) : i64 0)")

(define (compiler-typecheck-generated-decl-bad-source) : String
  "(comptime-decl (:generated bad-family bad-generated \"i64\")
  (define (bad-generated) : i64 true))
(define (main) : i64 0)")

(define (compiler-typecheck-generated-key
  [generator : String]
  [item : String]
  [arg : String]) : String
  (gen-full-key "" generator item (string-append (spec-string-key arg) "_none")))

(define (compiler-typecheck-generated-notes-ok?
  [notes : CompilerDiagnosticNoteList]
  [want-key : String]
  [want-context : String]) : bool
  (match notes
    [(CompilerDiagnosticNoteCons identity-note rest)
      (and
        (string-eq
          identity-note
          (string-append "generated identity: " want-key))
        (match (box-get rest)
          [(CompilerDiagnosticNoteCons context-note _)
            (string-eq context-note want-context)]
          [(CompilerDiagnosticNoteNil) false]))]
    [(CompilerDiagnosticNoteNil) false]))

(define (compiler-typecheck-generated-diagnostic-ok?) : bool
  (match (typecheck-compiler-source
    (compiler-typecheck-generated-decl-bad-source))
    [(OkCompilerTypecheck _) false]
    [(ErrCompilerTypecheck diag)
      (let
        [message-ok : bool
          (string-eq
            (compiler-diagnostic-message diag)
            "typecheck: return type mismatch")]
        [path-ok : bool (string-eq (compiler-diagnostic-path diag) "")]
        [line-ok : bool (= (compiler-diagnostic-line diag) 2)]
        [col-ok : bool (= (compiler-diagnostic-col diag) 33)]
        [notes-ok : bool
          (compiler-typecheck-generated-notes-ok?
            (compiler-diagnostic-notes diag)
            (compiler-typecheck-generated-key
              "bad-family"
              "bad-generated"
              "i64")
            "generated declaration: bad-generated from bad-family")]
        (and message-ok path-ok line-ok col-ok notes-ok))]))

(define (compiler-typecheck-generated-fallback-diagnostic-ok?) : bool
  (let
    [meta : AstGeneratedDeclMeta
      (AstSomeGeneratedDeclMeta
        "policy-family"
        "GeneratedStruct"
        AstExprNil
        "policy-key")]
    [decl : AstDecl
      (ast-decl-comptime-decl-with-meta
        meta
        (ast-decl-def-struct
          "GeneratedStruct"
          (AstStructReprDefault)
          (AstStructNoCleanup)
          AstFieldDefNil))]
    [diag : CompilerDiagnostic (tc-decl-diag decl "typecheck: policy fallback")]
    [message-ok : bool
      (string-eq
        (compiler-diagnostic-message diag)
        "typecheck: policy fallback")]
    [path-ok : bool (string-eq (compiler-diagnostic-path diag) "")]
    [line-ok : bool (= (compiler-diagnostic-line diag) 1)]
    [col-ok : bool (= (compiler-diagnostic-col diag) 1)]
    [notes-ok : bool
      (compiler-typecheck-generated-notes-ok?
        (compiler-diagnostic-notes diag)
        "policy-key"
        "generated declaration: GeneratedStruct from policy-family")]
    (and message-ok path-ok line-ok col-ok notes-ok)))

(define (compiler-typecheck-match-mismatch-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (match m [(Some v) v] [None false]))")

(define (compiler-typecheck-unknown-variant-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (match m [(Other) 1] [_ 0]))")

(define (compiler-typecheck-unknown-field-source) : String
  "(defstruct Point (x i64) (y i64))
(define (main [p : Point]) : i64
  (struct-get p z))")

(define (compiler-typecheck-aggregate-global-source) : String
  "(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(define point : Point (Point 20 2))
(define pair : (Tuple i64 bool) (tuple 7 true))
(define fixed : (Array i64 2) (array 5 6))
(define maybe : Maybe (Some 8))
(define (main) : i64
  (+ (struct-get point x)
     (+ (tuple-ref pair 0)
        (+ (array-ref fixed 1)
           (match maybe [(Some n) n] [None 0])))))")

(define (compiler-typecheck-global-region-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define bad : String (with-arena r (int->string 1)))"))

(define (compiler-typecheck-global-reference-aggregate-source) : String
  "(define bad : (Tuple (& n i64) i64) (tuple (& n) 1))")

(define (compiler-typecheck-struct-constructor-mismatch-source) : String
  "(defstruct Point (x i64) (flag bool))
(define bad : Point (Point true false))")

(define (compiler-typecheck-struct-constructor-arity-source) : String
  "(defstruct Point (x i64) (flag bool))
(define bad : Point (Point 1))")

(define (compiler-typecheck-struct-get-nonstruct-source) : String
  "(define (main) : i64 (struct-get 1 x))")

(define (compiler-typecheck-recursive-enum-boxed-source) : String
  "(defenum ListI64
  (ListNil)
  (ListCons i64 (Box ListI64)))
(define (head [xs : ListI64]) : i64
  (match xs [(ListCons v rest) v] [ListNil 0]))
(define (main) : i64 (head (ListCons 1 (box ListNil))))")

(define (compiler-typecheck-duplicate-variant-source) : String
  "(defenum Left (Same) (Same))
(define (main) : i64 0)")

(define (compiler-typecheck-cross-enum-qualified-variant-source) : String
  "(defenum Left (Same) (Other))
(defenum Right (Same))
(define left : Left Left.Same)
(define right : Right Right.Same)
(define (main) : i64
  (+ (match left [Left.Same 1] [_ 0])
     (match right [Right.Same 2] [_ 0])))")

(define (compiler-typecheck-enum-qualified-variant-source) : String
  "(defenum Json (Null) (Bool bool))
(defstruct Holder (Null i64))
(define value : Json Json.Null)
(define flag : Json (Json.Bool true))
(define (score [item : Json]) : i64
  (match item
    [Json.Null 0]
    [(Json.Bool b) (if b 1 2)]))
(define (main) : i64
  (let [Json : Holder (Holder 41)]
    (+ Json.Null (+ (score value) (score flag)))))")

(define (compiler-typecheck-variant-function-collision-source) : String
  "(defenum A (Foo))
(define (Foo [x : i64]) : i64 x)")

(define (compiler-typecheck-variant-define-collision-source) : String
  "(defenum A (Foo))
(define Foo : i64 42)")

(define (compiler-typecheck-variant-extern-collision-source) : String
  "(defenum A (Foo))
(extern (Foo [arg0 : i64]) : i64)")

(define (compiler-typecheck-variant-struct-collision-source) : String
  "(defenum A (Foo))
(defstruct Foo (x i64))")

(define (compiler-typecheck-struct-function-collision-source) : String
  "(defstruct Point (x i64))
(define (Point [x : i64]) : i64 x)")

(define (compiler-typecheck-struct-define-collision-source) : String
  "(defstruct Point (x i64))
(define Point : i64 42)")

(define (compiler-typecheck-struct-extern-collision-source) : String
  "(defstruct Point (x i64))
(extern (Point [arg0 : i64]) : i64)")

(define (compiler-typecheck-builtin-shadow-source) : String
  "(define (string-length [n : i64]) : i64 n)
(define (main) : i64 (string-length 7))")

(define (compiler-typecheck-module-qualified-source) : String
  "(module left)
(define same : i64 20)
(define (get) : i64 same)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(export (value get))
(module right)
(define same : i64 22)
(define (get) : i64 same)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(export
  (value get)
  (type Maybe)
  (variant None)
  (variant Some)
  (type Point)
  (constructor Point)
  (field Point x))
(module main)
(import left)
(import right)
(define (main) : i64
  (+
    (left.get)
    (+
      (right.get)
      (+
        (let ([p : right.Point (right.Point 7)])
          (struct-get p x))
        (match (right.Maybe.Some 1)
          [(right.Maybe.Some v) v]
          [right.Maybe.None 0])))))")

(define (compiler-typecheck-module-unqualified-import-source) : String
  "(module left)
(define (get) : i64 20)
(module main)
(define (main) : i64 (get))")

(define (compiler-typecheck-import-alias-source) : String
  "(module data)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(export
  (value get)
  (type Maybe)
  (variant None)
  (variant Some)
  (type Point)
  (constructor Point)
  (field Point x))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64
  (+
    (d.get)
    (+
      (let ([p : d.Point (d.Point 7)])
        (struct-get p x))
      (match (d.Maybe.Some 3)
        [(d.Maybe.Some v) v]
        [d.Maybe.None 0]))))")

(define (compiler-typecheck-dotted-import-default-alias-source) : String
  "(module pkg.data)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(export
  (value get)
  (type Maybe)
  (variant None)
  (variant Some)
  (type Point)
  (constructor Point)
  (field Point x))
(module main)
(import pkg.data)
(define (main) : i64
  (+
    (data.get)
    (+
      (let ([p : data.Point (data.Point 7)])
        (struct-get p x))
      (match (data.Maybe.Some 3)
        [(data.Maybe.Some v) v]
        [data.Maybe.None 0]))))")

(define (compiler-typecheck-dot-field-source) : String
  "(defstruct Pair (x i64) (y i64))
(defstruct Outer (p Pair) (z i64))
(define (take [r : (& n i64)]) : i64 5)
(define (main) : i64
  (let [o : Outer (Outer (Pair 1 2) 3)]
    (begin
      (set! o.p.x 17)
      (+ o.p.x (+ o.p.y (+ o.z (take (& o.p.x))))))))")

(define (compiler-typecheck-dot-field-local-shadows-alias-source) : String
  "(module pkg.data)
(define (value) : i64 99)
(export (value value))
(module main)
(import pkg.data)
(defstruct Pair (value i64))
(define (main) : i64
  (let [data : Pair (Pair 42)]
    data.value))")

(define (compiler-typecheck-dot-field-index-source) : String
  "(defstruct Pair (x i64))
(define (main) : i64
  (let [p : Pair (Pair 1)]
    p.0))")

(define (compiler-typecheck-dotted-import-default-alias-with-macro-source) : String
  "(module pkg.data)
(define (get) : i64 20)
(export (value get))
(module pkg.macros)
(defmacro (identity [x : Expr]) : Expr x)
(module main)
(import pkg.data)
(define (main) : i64 (+ (data.get) 1))")

(define (compiler-typecheck-dotted-import-full-path-source) : String
  "(module pkg.data)
(define (get) : i64 20)
(export (value get))
(module main)
(import pkg.data)
(define (main) : i64 (pkg.data.get))")

(define (compiler-typecheck-dotted-import-full-path-unimported-source) : String
  "(module pkg.data)
(define (get) : i64 20)
(export (value get))
(module main)
(define (main) : i64 (pkg.data.get))")

(define (compiler-typecheck-dotted-import-explicit-alias-collision-source) : String
  "(module left.same)
(define (get) : i64 20)
(export (value get))
(module right.same)
(define (get) : i64 22)
(export (value get))
(module main)
(import left.same as l)
(import right.same as r)
(define (main) : i64 (+ (l.get) (r.get)))")

(define (compiler-typecheck-dotted-import-unqualified-source) : String
  "(module pkg.data)
(define (get) : i64 20)
(export (value get))
(module main)
(import pkg.data)
(define (main) : i64 (get))")

(define (compiler-typecheck-import-alias-missing-source) : String
  "(module data)
(define (get) : i64 20)
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64 (missing.get))")

(define (compiler-typecheck-import-alias-missing-member-source) : String
  "(module data)
(define (get) : i64 20)
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64 (d.missing))")

(define (compiler-typecheck-slash-qualified-rejected-source) : String
  "(module data)
(define (get) : i64 20)
(export (value get))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64 (d/get))")

(define (compiler-typecheck-export-unknown-source) : String
  "(module data)
(export (value missing))
(define (main) : i64 0)")

(define (compiler-typecheck-export-visibility-allowed-source) : String
  "(module data)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64) (hidden i64))
(export
  (value get)
  (type Maybe)
  (variant None)
  (variant Some)
  (type Point)
  (constructor Point)
  (field Point x))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64
  (+
    (d.get)
    (+
      (let ([p : d.Point (d.Point 7 9)])
        (struct-get p x))
      (match (d.Maybe.Some 3)
        [(d.Maybe.Some v) v]
        [d.Maybe.None 0]))))")

(define (compiler-typecheck-export-private-alias-value-source) : String
  "(module data)
(define private : i64 1)
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64 d.private)")

(define (compiler-typecheck-export-private-canonical-value-source) : String
  "(module data)
(define private : i64 1)
(module main)
(import data)
(define (main) : i64 data.private)")

(define (compiler-typecheck-export-type-only-opaque-source) : String
  "(module data)
(defstruct Opaque (value i64))
(export (type Opaque))
(module main)
(import \"data.tl\" module data :as d)
(define (id [x : d.Opaque]) : d.Opaque x)
(define (main) : i64 0)")

(define (compiler-typecheck-export-type-only-constructor-source) : String
  "(module data)
(defstruct Opaque (value i64))
(export (type Opaque))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : d.Opaque (d.Opaque 1))")

(define (compiler-typecheck-export-type-only-field-source) : String
  "(module data)
(defstruct Opaque (value i64))
(define (make) : Opaque (Opaque 1))
(export (type Opaque) (value make))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64
  (let ([x : d.Opaque (d.make)])
    (struct-get x value)))")

(define (compiler-typecheck-export-generated-decl-source) : String
  "(module data)
(comptime-decl (:generated generated-family Generated \"i64\")
  (defstruct Generated (value i64)))
(export (type Generated) (constructor Generated) (field Generated value))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64
  (let ([x : d.Generated (d.Generated 7)])
    (struct-get x value)))")

(define (compiler-typecheck-export-private-type-source) : String
  "(module data)
(defstruct Hidden (value i64))
(module main)
(import \"data.tl\" module data :as d)
(define (main [x : d.Hidden]) : i64 0)")

(define (compiler-typecheck-export-private-variant-pattern-source) : String
  "(module data)
(defenum Choice (Hidden i64) (Visible i64))
(define (make) : Choice (Hidden 1))
(export (type Choice) (variant Visible) (value make))
(module main)
(import \"data.tl\" module data :as d)
(define (main) : i64
  (match (d.make)
    [(d.Hidden v) v]
    [(d.Visible v) v]))")

(define (compiler-typecheck-export-same-module-private-source) : String
  "(module data)
(define private : i64 2)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(define (main) : i64
  (+
    data.private
    (+
      (let ([p : data.Point (data.Point 1)])
        (struct-get p x))
      (match (data.Maybe.Some 2)
        [(data.Maybe.Some v) v]
        [data.Maybe.None 0]))))")

(define (compiler-typecheck-export-visibility-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-export-visibility-allowed-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-export-private-alias-value-source)
        "typecheck: private value d/private from module data")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-export-private-canonical-value-source)
        "typecheck: private value data/private from module data")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-export-type-only-opaque-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-export-type-only-constructor-source)
        "typecheck: private constructor d/Opaque from module data")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-export-type-only-field-source)
        "typecheck: private field data/Opaque.value from module data")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-export-generated-decl-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-export-private-type-source)
        "typecheck: private type data/Hidden from module data")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-export-private-variant-pattern-source)
        "typecheck: private variant d/Hidden from module data")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-export-same-module-private-source))
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-repr-c-layout-source) : String
  "(defstruct Packet
  (:repr c)
  (tag u8)
  (count i64)
  (flag bool))
(defstruct Inner
  (:repr c)
  (a u8)
  (b i32))
(defstruct Outer
  (:repr c)
  (tag u8)
  (inner Inner)
  (tail u16))")

(define (compiler-typecheck-repr-c-f32-source) : String
  "(defstruct Vec2
  (:repr c)
  (x f32)
  (y f32)
  (tag i64))
(define (main) : f32
  (let
    [v : Vec2 (Vec2 1.5 2.5 7)]
    (struct-get v x)))")

(define (compiler-typecheck-repr-c-layout-ok?) : bool
  (begin
    (tc-agg-caches-reset!)
    (match (parse-ast-source (compiler-typecheck-repr-c-layout-source))
      [(OkAstProgram program)
        (match (build-compiler-symbols program)
          [(OkCompilerSymbols symbols)
            (match (build-compiler-registries program)
              [(OkCompilerRegistries registries)
                (let
                  [ctx : TcContext (TcContext program symbols registries "")]
                  (match (tc-repr-c-struct-layout ctx "Packet")
                    [(OkTcReprCLayout packet)
                      (match (tc-repr-c-struct-layout ctx "Outer")
                        [(OkTcReprCLayout outer)
                          (and
                            (= (tc-repr-c-layout-size packet) 24)
                            (= (tc-repr-c-layout-align packet) 8)
                            (=
                              (tc-repr-c-layout-field-offset
                                (tc-repr-c-layout-fields packet)
                                "tag")
                              0)
                            (=
                              (tc-repr-c-layout-field-offset
                                (tc-repr-c-layout-fields packet)
                                "count")
                              8)
                            (=
                              (tc-repr-c-layout-field-offset
                                (tc-repr-c-layout-fields packet)
                                "flag")
                              16)
                            (= (tc-repr-c-layout-size outer) 16)
                            (= (tc-repr-c-layout-align outer) 4)
                            (=
                              (tc-repr-c-layout-field-offset
                                (tc-repr-c-layout-fields outer)
                                "inner")
                              4)
                            (=
                              (tc-repr-c-layout-field-offset
                                (tc-repr-c-layout-fields outer)
                                "tail")
                              12))]
                        [(ErrTcReprCLayout _) false])]
                    [(ErrTcReprCLayout _) false]))]
              [(ErrCompilerRegistries _) false])]
          [(ErrCompilerSymbols _) false])]
      [(ErrAstProgram _) false])))

(define (compiler-typecheck-repr-c-f32-layout-ok?) : bool
  (begin
    (tc-agg-caches-reset!)
    (match (parse-ast-source (compiler-typecheck-repr-c-f32-source))
      [(OkAstProgram program)
        (match (build-compiler-symbols program)
          [(OkCompilerSymbols symbols)
            (match (build-compiler-registries program)
              [(OkCompilerRegistries registries)
                (let
                  [ctx : TcContext (TcContext program symbols registries "")]
                  (match (tc-repr-c-struct-layout ctx "Vec2")
                    [(OkTcReprCLayout layout)
                      (and
                        (= (tc-repr-c-layout-size layout) 16)
                        (= (tc-repr-c-layout-align layout) 8)
                        (=
                          (tc-repr-c-layout-field-offset
                            (tc-repr-c-layout-fields layout)
                            "x")
                          0)
                        (=
                          (tc-repr-c-layout-field-offset
                            (tc-repr-c-layout-fields layout)
                            "y")
                          4)
                        (=
                          (tc-repr-c-layout-field-offset
                            (tc-repr-c-layout-fields layout)
                            "tag")
                          8))]
                    [(ErrTcReprCLayout _) false]))]
              [(ErrCompilerRegistries _) false])]
          [(ErrCompilerSymbols _) false])]
      [(ErrAstProgram _) false])))

(define (compiler-typecheck-repr-c-string-source) : String
  "(defstruct Bad
  (:repr c)
  (s String))")

(define (compiler-typecheck-repr-c-default-nested-source) : String
  "(defstruct Inner (x i64))
(defstruct Bad
  (:repr c)
  (inner Inner))")

(define (compiler-typecheck-repr-c-recursive-source) : String
  "(defstruct Node
  (:repr c)
  (next Node))")

(define (compiler-typecheck-repr-c-mutual-recursive-source) : String
  "(defstruct A
  (:repr c)
  (b B))
(defstruct B
  (:repr c)
  (a A))")

(define (compiler-typecheck-repr-c-default-cycle-source) : String
  "(defstruct Middle
  (back CRoot))
(defstruct CRoot
  (:repr c)
  (tag u8)
  (middle Middle))")

(define (compiler-typecheck-repr-c-mixed-layout-source) : String
  "(defstruct Point
  (x i64)
  (y i64))
(defenum Tag
  (TagNone)
  (TagVal i64))
(defstruct Mixed
  (:repr c)
  (lead u8)
  (point Point)
  (tag Tag)
  (tail u16))")

(define (compiler-typecheck-repr-c-layout-error-ok?
  [src : String]
  [name : String]
  [want : String]) : bool
  (begin
    (tc-agg-caches-reset!)
    (match (parse-ast-source src)
      [(OkAstProgram program)
        (match (build-compiler-symbols program)
          [(OkCompilerSymbols symbols)
            (match (build-compiler-registries program)
              [(OkCompilerRegistries registries)
                (let
                  [ctx : TcContext (TcContext program symbols registries "")]
                  (match (tc-repr-c-struct-layout ctx name)
                    [(OkTcReprCLayout _) false]
                    [(ErrTcReprCLayout message) (string-eq message want)]))]
              [(ErrCompilerRegistries _) false])]
          [(ErrCompilerSymbols _) false])]
      [(ErrAstProgram _) false])))

(define (compiler-typecheck-repr-c-mixed-layout-ok?) : bool
  (begin
    (tc-agg-caches-reset!)
    (match (parse-ast-source (compiler-typecheck-repr-c-mixed-layout-source))
      [(OkAstProgram program)
        (match (build-compiler-symbols program)
          [(OkCompilerSymbols symbols)
            (match (build-compiler-registries program)
              [(OkCompilerRegistries registries)
                (let
                  [ctx : TcContext (TcContext program symbols registries "")]
                  (match (tc-repr-c-struct-layout ctx "Mixed")
                    [(OkTcReprCLayout layout)
                      (and
                        (= (tc-repr-c-layout-size layout) 48)
                        (= (tc-repr-c-layout-align layout) 8)
                        (=
                          (tc-repr-c-layout-field-offset
                            (tc-repr-c-layout-fields layout)
                            "lead")
                          0)
                        (=
                          (tc-repr-c-layout-field-offset
                            (tc-repr-c-layout-fields layout)
                            "point")
                          8)
                        (=
                          (tc-repr-c-layout-field-offset
                            (tc-repr-c-layout-fields layout)
                            "tag")
                          24)
                        (=
                          (tc-repr-c-layout-field-offset
                            (tc-repr-c-layout-fields layout)
                            "tail")
                          40))]
                    [(ErrTcReprCLayout _) false]))]
              [(ErrCompilerRegistries _) false])]
          [(ErrCompilerSymbols _) false])]
      [(ErrAstProgram _) false])))

(define (compiler-typecheck-repr-c-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-layout-source))
    (compiler-typecheck-repr-c-layout-ok?)
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-f32-source))
    (compiler-typecheck-repr-c-f32-layout-ok?)
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-string-source))
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-default-nested-source))
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-recursive-source))
    (compiler-typecheck-repr-c-layout-error-ok?
      (compiler-typecheck-repr-c-mutual-recursive-source)
      "A"
      "typecheck: recursive repr c struct layout cycle involving A")
    (compiler-typecheck-repr-c-layout-error-ok?
      (compiler-typecheck-repr-c-default-cycle-source)
      "CRoot"
      "typecheck: inline aggregate layout cycle CRoot -> Middle -> CRoot; insert (Box CRoot) at the recursive edge")
    (compiler-typecheck-repr-c-mixed-layout-ok?)))

(define (compiler-typecheck-inline-layout-result [src : String] [name : String]) : ResultTcUnit
  (match (parse-ast-source src)
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (let
                [ctx : TcContext (TcContext program symbols registries "")]
                (tc-inline-aggregate-layout-finite-ok ctx name))]
            [(ErrCompilerRegistries message) (ErrTcUnit message)])]
        [(ErrCompilerSymbols message) (ErrTcUnit message)])]
    [(ErrAstProgram message) (ErrTcUnit message)]))

(define (compiler-typecheck-inline-layout-ok? [src : String] [name : String]) : bool
  (match (compiler-typecheck-inline-layout-result src name)
    [(OkTcUnit) true]
    [(ErrTcUnit _) false]))

(define (compiler-typecheck-inline-layout-error-ok?
  [src : String]
  [name : String]
  [want : String]) : bool
  (match (compiler-typecheck-inline-layout-result src name)
    [(ErrTcUnit message) (string-eq message want)]
    [(OkTcUnit) false]))

(define (compiler-typecheck-inline-layout-query-source) : String
  "(defstruct InlinePacket
  (tag u8)
  (count i64)
  (flag bool)
  (small u16))
(defenum InlineChoice
  (Empty)
  (Byte u8)
  (Wide u8 i64)
  (Pair (Tuple u8 i32)))
(defenum ListI64
  (ListNil)
  (ListCons i64 (Box ListI64)))
(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))")

(define (compiler-typecheck-inline-layout-query-ok?) : bool
  (match (parse-ast-source (compiler-typecheck-inline-layout-query-source))
    [(OkAstProgram program)
      (match (build-compiler-symbols program)
        [(OkCompilerSymbols symbols)
          (match (build-compiler-registries program)
            [(OkCompilerRegistries registries)
              (let
                [ctx : TcContext (TcContext program symbols registries "")]
                [ok : bool true]
                (begin
                  (match (tc-inline-aggregate-layout-for ctx "InlinePacket")
                    [(OkTcInlineAggregateLayout layout)
                      (begin
                        (if (= (tc-inline-aggregate-layout-size layout) 24)
                          unit
                          (set! ok false))
                        (if (= (tc-inline-aggregate-layout-align layout) 8)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-field-offset layout "tag")
                          0)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-field-offset
                            layout
                            "count")
                          8)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-field-offset
                            layout
                            "flag")
                          16)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-field-offset
                            layout
                            "small")
                          18)
                          unit
                          (set! ok false)))]
                    [(ErrTcInlineAggregateLayout _) (set! ok false)])
                  (match (tc-inline-aggregate-layout-for ctx "InlineChoice")
                    [(OkTcInlineAggregateLayout layout)
                      (begin
                        (if (= (tc-inline-aggregate-layout-size layout) 24)
                          unit
                          (set! ok false))
                        (if (= (tc-inline-aggregate-layout-align layout) 8)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-variant-size
                            layout
                            "Empty")
                          8)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-variant-size
                            layout
                            "Byte")
                          16)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-variant-size
                            layout
                            "Wide")
                          24)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-variant-payload-offset
                            layout
                            "Wide"
                            0)
                          8)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-variant-payload-offset
                            layout
                            "Wide"
                            1)
                          16)
                          unit
                          (set! ok false))
                        (if (=
                          (tc-inline-aggregate-layout-variant-payload-offset
                            layout
                            "Pair"
                            0)
                          8)
                          unit
                          (set! ok false)))]
                    [(ErrTcInlineAggregateLayout _) (set! ok false)])
                  (match (tc-inline-aggregate-layout-for ctx "ListI64")
                    [(OkTcInlineAggregateLayout layout)
                      (if (= (tc-inline-aggregate-layout-size layout) 24)
                        unit
                        (set! ok false))]
                    [(ErrTcInlineAggregateLayout _) (set! ok false)])
                  (match (tc-inline-aggregate-layout-for ctx "Tree")
                    [(OkTcInlineAggregateLayout layout)
                      (if (= (tc-inline-aggregate-layout-size layout) 24)
                        unit
                        (set! ok false))]
                    [(ErrTcInlineAggregateLayout _) (set! ok false)])
                  (match (tc-inline-aggregate-type-layout
                    ctx
                    (AstTyTuple (tc-type-list2 (AstTyU8) (AstTyI32))))
                    [(OkTcLayoutInfo info)
                      (if (and
                        (= (tc-layout-info-size info) 8)
                        (= (tc-layout-info-align info) 4))
                        unit
                        (set! ok false))]
                    [(ErrTcLayoutInfo _) (set! ok false)])
                  (match (tc-inline-aggregate-type-layout
                    ctx
                    (ast-ty-array
                      (AstTyTuple (tc-type-list2 (AstTyU8) (AstTyI32)))
                      2))
                    [(OkTcLayoutInfo info)
                      (if (and
                        (= (tc-layout-info-size info) 16)
                        (= (tc-layout-info-align info) 4))
                        unit
                        (set! ok false))]
                    [(ErrTcLayoutInfo _) (set! ok false)])
                  (match (tc-inline-aggregate-type-layout
                    ctx
                    (ast-ty-box (AstTyStruct (intern "InlinePacket"))))
                    [(OkTcLayoutInfo info)
                      (if (and
                        (= (tc-layout-info-size info) 8)
                        (= (tc-layout-info-align info) 8))
                        unit
                        (set! ok false))]
                    [(ErrTcLayoutInfo _) (set! ok false)])
                  (match (tc-inline-aggregate-type-layout
                    ctx
                    (ast-ty-dyn-array (AstTyStruct (intern "InlinePacket"))))
                    [(OkTcLayoutInfo info)
                      (if (and
                        (= (tc-layout-info-size info) 8)
                        (= (tc-layout-info-align info) 8))
                        unit
                        (set! ok false))]
                    [(ErrTcLayoutInfo _) (set! ok false)])
                  ok))]
            [(ErrCompilerRegistries _) false])]
        [(ErrCompilerSymbols _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-typecheck-inline-boxed-list-source) : String
  "(defenum ListI64
  (ListNil)
  (ListCons i64 (Box ListI64)))")

(define (compiler-typecheck-inline-boxed-tree-source) : String
  "(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))")

(define (compiler-typecheck-inline-boxed-sym-i64-env-source) : String
  "(defenum SymI64Env
  (SymI64Nil)
  (SymI64Bind i64 i64 (Box SymI64Env)))")

(define (compiler-typecheck-inline-boxed-loader-helper-source) : String
  "(defenum InlineHelperRootList
  (InlineHelperRootNil)
  (InlineHelperRootCons String (Box InlineHelperRootList)))
(defstruct CompilerPkgDep
  (alias String)
  (path String))
(defenum CompilerPkgDepList
  (CompilerPkgDepNil)
  (CompilerPkgDepCons CompilerPkgDep (Box CompilerPkgDepList)))")

(define (compiler-typecheck-inline-loader-helper-layout-ok?) : bool
  (let
    [src : String (compiler-typecheck-inline-boxed-loader-helper-source)]
    (and
      (compiler-typecheck-inline-layout-ok? src "InlineHelperRootList")
      (compiler-typecheck-inline-layout-ok? src "CompilerPkgDepList"))))

(define (compiler-typecheck-inline-boxed-ctfe-metadata-source) : String
  "(defenum CompilerCtfeValue
  (CtfeUnit))
(defstruct CtfeLayoutField
  (name String)
  (offset i64))
(defstruct CtfeLayoutFieldList
  (slots (Array CtfeLayoutField))
  (len i64))
(defstruct CtfeLayoutInfo
  (name String)
  (is-struct bool)
  (size i64)
  (align i64)
  (fields CtfeLayoutFieldList))
(defstruct CtfeLayoutInfoList
  (slots (Array CtfeLayoutInfo))
  (len i64))
(defenum AstType
  (AstTyI64))
(defenum AstTypeList
  (AstTypeNil)
  (AstTypeCons (Box AstType) (Box AstTypeList)))
(defstruct CtfeReflectField
  (name String)
  (ty AstType))
(defstruct CtfeReflectFieldList
  (slots (Array CtfeReflectField))
  (len i64))
(defstruct CtfeReflectVariant
  (name String)
  (payloads AstTypeList))
(defstruct CtfeReflectVariantList
  (slots (Array CtfeReflectVariant))
  (len i64))
(defenum CtfeReflectInfo
  (CtfeReflectStruct String String String CtfeReflectFieldList)
  (CtfeReflectEnum String String String CtfeReflectVariantList))
(defstruct CtfeReflectInfoList
  (slots (Array CtfeReflectInfo))
  (len i64))
(defenum CtfeEnv
  (CtfeEnvNil CtfeLayoutInfoList CtfeReflectInfoList)
  (CtfeEnvCons String CompilerCtfeValue AstType (Box CtfeEnv)))")

(define (compiler-typecheck-inline-ctfe-metadata-layout-ok?) : bool
  (let
    [src : String (compiler-typecheck-inline-boxed-ctfe-metadata-source)]
    (and
      (compiler-typecheck-inline-layout-ok? src "CtfeEnv")
      (compiler-typecheck-inline-layout-ok? src "CtfeLayoutInfoList")
      (compiler-typecheck-inline-layout-ok? src "CtfeLayoutFieldList")
      (compiler-typecheck-inline-layout-ok? src "CtfeReflectInfoList")
      (compiler-typecheck-inline-layout-ok? src "CtfeReflectFieldList")
      (compiler-typecheck-inline-layout-ok? src "CtfeReflectVariantList"))))

(define (compiler-typecheck-inline-boxed-ast-list-source) : String
  "(defenum AstType
  (AstTyI64)
  (AstTyFunc AstTypeList (Box AstType))
  (AstTyTuple AstTypeList)
  (AstTyBox (Box AstType)))
(defenum AstTypeList
  (AstTypeNil)
  (AstTypeCons (Box AstType) (Box AstTypeList)))
(defenum AstPattern
  (AstPatWildcard)
  (AstPatTuple (Box AstPatternList)))
(defenum AstPatternList
  (AstPatternNil)
  (AstPatternCons (Box AstPattern) (Box AstPatternList)))
(defenum AstExpr
  (AstExprLiteral i64)
  (AstExprCall (Box AstExpr) AstExprList)
  (AstExprTuple AstExprList)
  (AstExprMatch (Box AstExpr) AstPatternList))
(defenum AstExprList
  (AstExprNil)
  (AstExprCons (Box AstExpr) (Box AstExprList)))")

(define (compiler-typecheck-inline-ast-list-layout-ok?) : bool
  (let
    [src : String (compiler-typecheck-inline-boxed-ast-list-source)]
    (and
      (compiler-typecheck-inline-layout-ok? src "AstType")
      (compiler-typecheck-inline-layout-ok? src "AstTypeList")
      (compiler-typecheck-inline-layout-ok? src "AstPattern")
      (compiler-typecheck-inline-layout-ok? src "AstPatternList")
      (compiler-typecheck-inline-layout-ok? src "AstExpr")
      (compiler-typecheck-inline-layout-ok? src "AstExprList"))))

(define (compiler-typecheck-inline-boxed-formatter-source) : String
  "(defenum FormatToken
  (FmtSymbol String)
  (FmtColon))
(defenum FormatCst
  (FmtCstAtom FormatToken)
  (FmtCstComment String)
  (FmtCstPrefix FormatToken (Box FormatCst))
  (FmtCstList (Box FormatCstList))
  (FmtCstBracketList (Box FormatCstList))
  (FmtCstForms (Box FormatCstList)))
(defenum FormatCstList
  (FmtCstNil)
  (FmtCstCons FormatCst (Box FormatCstList)))
(defenum Doc
  (DEmpty)
  (DText String)
  (DSoftLine)
  (DHardLine)
  (DConcat (Box Doc) (Box Doc))
  (DNest i64 (Box Doc))
  (DGroup (Box Doc)))")

(define (compiler-typecheck-inline-formatter-layout-ok?) : bool
  (let
    [src : String (compiler-typecheck-inline-boxed-formatter-source)]
    (and
      (compiler-typecheck-inline-layout-ok? src "FormatCst")
      (compiler-typecheck-inline-layout-ok? src "FormatCstList")
      (compiler-typecheck-inline-layout-ok? src "Doc"))))

(define (compiler-typecheck-inline-pointer-boundaries-source) : String
  "(defstruct Node
  (name String)
  (children (Array Node))
  (next (Box Node))
  (raw (Ptr Node))
  (raw-mut (MutPtr Node))
  (ref (& phase Node))
  (ref-mut (&mut phase Node))
  (visit (-> Node Node)))")

(define (compiler-typecheck-inline-unboxed-list-source) : String
  "(defenum BadList
  (BadNil)
  (BadCons i64 BadList))")

(define (compiler-typecheck-inline-mutual-struct-source) : String
  "(defstruct A (b B))
(defstruct B (a A))")

(define (compiler-typecheck-inline-fixed-array-source) : String
  "(defstruct BadFixed
  (items (Array BadFixed 2)))")

(define (compiler-typecheck-inline-tuple-source) : String
  "(defstruct BadTuple
  (item (Tuple i64 BadTuple)))")

(define (compiler-typecheck-inline-region-wrapper-source) : String
  "(defstruct BadRegion
  (next (in phase BadRegion)))")

(define (compiler-typecheck-inline-layout-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-error-ok?
        (str-cat
          (compiler-typecheck-inline-unboxed-list-source)
          "\n"
          "(define (main [x : BadList]) : i64 0)")
        "typecheck: inline aggregate layout cycle BadList -> BadList; insert (Box BadList) at the recursive edge")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-inline-mutual-struct-source)
        "typecheck: inline aggregate layout cycle A -> B -> A; insert (Box A) at the recursive edge")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-inline-boxed-list-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-inline-boxed-tree-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-ok?
        (compiler-typecheck-inline-boxed-list-source)
        "ListI64")
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-ok?
        (compiler-typecheck-inline-boxed-tree-source)
        "Tree")
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-ok?
        (compiler-typecheck-inline-boxed-sym-i64-env-source)
        "SymI64Env")
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-loader-helper-layout-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-ctfe-metadata-layout-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-ast-list-layout-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-formatter-layout-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-ok?
        (compiler-typecheck-inline-pointer-boundaries-source)
        "Node")
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-query-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-error-ok?
        (compiler-typecheck-inline-unboxed-list-source)
        "BadList"
        "typecheck: inline aggregate layout cycle BadList -> BadList; insert (Box BadList) at the recursive edge")
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-error-ok?
        (compiler-typecheck-inline-mutual-struct-source)
        "A"
        "typecheck: inline aggregate layout cycle A -> B -> A; insert (Box A) at the recursive edge")
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-error-ok?
        (compiler-typecheck-inline-fixed-array-source)
        "BadFixed"
        "typecheck: inline aggregate layout cycle BadFixed -> BadFixed; insert (Box BadFixed) at the recursive edge")
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-error-ok?
        (compiler-typecheck-inline-tuple-source)
        "BadTuple"
        "typecheck: inline aggregate layout cycle BadTuple -> BadTuple; insert (Box BadTuple) at the recursive edge")
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-error-ok?
        (compiler-typecheck-inline-region-wrapper-source)
        "BadRegion"
        "typecheck: inline aggregate layout cycle BadRegion -> BadRegion; insert (Box BadRegion) at the recursive edge")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-nominal-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok? (compiler-typecheck-nominal-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-comptime-decl-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-generated-decl-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-generated-decl-duplicate-visible-source)
        (string-append
          "symbols: duplicate type declaration Point (generated identity: "
          (string-append
            (compiler-typecheck-generated-key "point-family" "Point" "right")
            ")")))
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-diagnostic-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-generated-fallback-diagnostic-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-match-mismatch-source)
        "typecheck: match arm result type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-unknown-variant-source)
        "typecheck: unknown variant Other")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-unknown-field-source)
        "typecheck: unknown struct field Point.z")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-aggregate-global-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-global-region-source)
        "typecheck: region-tagged value cannot escape with-arena 'r'")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-global-reference-aggregate-source)
        "typecheck: storing references in top-level values requires lifetime support (#804)")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-struct-constructor-mismatch-source)
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-struct-constructor-arity-source)
        "typecheck: arity mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-struct-get-nonstruct-source)
        "typecheck: struct-get requires struct")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-recursive-enum-boxed-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-duplicate-variant-source)
        "symbols: duplicate enum variant Left.Same")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-cross-enum-qualified-variant-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-enum-qualified-variant-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-module-qualified-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-module-unqualified-import-source)
        "typecheck: unbound name get")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-import-alias-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-dotted-import-default-alias-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-dot-field-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-dot-field-local-shadows-alias-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-dot-field-index-source)
        "typecheck: dotted field access p.0 cannot use numeric field segments; use tuple-ref or array-ref")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-dotted-import-default-alias-with-macro-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-dotted-import-full-path-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-dotted-import-full-path-unimported-source)
        "typecheck: unknown qualified name pkg.data.get; import the module or use a visible dotted module alias")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-dotted-import-explicit-alias-collision-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-dotted-import-unqualified-source)
        "typecheck: unbound name get")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-import-alias-missing-source)
        "typecheck: unknown qualified name missing.get; import the module or use a visible dotted module alias")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-import-alias-missing-member-source)
        "typecheck: unbound name d/missing")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-slash-qualified-rejected-source)
        "typecheck: slash-qualified name d/get is no longer supported; use d.get")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-export-unknown-source)
        "symbols: cannot export unknown value data/missing")
        unit
        (set! ok false))
      (if (compiler-typecheck-export-visibility-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-repr-c-tests-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-inline-layout-tests-ok?)
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-region-builtin-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (string-length s))))"))

(define (compiler-typecheck-region-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : String
  (with-arena r (int->string 41)))"))

(define (compiler-typecheck-region-user-call-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (sink [s : String]) : i64 (string-length s))
(define (main) : i64
  (with-arena r
    (let
      [s : String (int->string 41)]
      (sink s))))"))

(define (compiler-typecheck-region-nested-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : i64
  (with-arena oute
    (let
      [s : String (with-arena inner (int->string 1))]
      0)))"))

(define (compiler-typecheck-region-outer-in-inner-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : i64
  (with-arena oute
    (let
      [s : String (int->string 1)]
      (with-arena inner (string-length s)))))"))

(define (compiler-typecheck-region-array-source) : String
  "(define (main [n : i64]) : i64
  (with-arena r
    (let
      [a : (Array i64) (make-array i64 n)]
      (begin
        (array-set! a 0 7)
        (array-length a)))))")

(define (compiler-typecheck-region-struct-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(defstruct Box (s String))
(define (main) : String
  (with-arena r
    (let
      [b : Box (Box (int->string 1))]
      (struct-get b s))))"))

(define (compiler-typecheck-region-match-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(defenum Token (Text String) (End))
(define (main) : i64
  (with-arena r
    (match (Text (int->string 1))
      [(Text s) (string-length s)]
      [End 0])))"))

(define (compiler-typecheck-with-escape-scalar-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : i64
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch 40 42)))"))

(define (compiler-typecheck-with-escape-string-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : String
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch (int->string 42))))"))

(define (compiler-typecheck-with-escape-region-strip-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : String
  (let
    [scratch : i64 (arena-make)]
    (with-arena r
      (with-escape scratch (int->string 42)))))"))

(define (compiler-typecheck-with-escape-bad-arena-source) : String
  "(define (main) : i64
  (with-escape true 1))")

(define (compiler-typecheck-with-escape-array-result-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : (Array i64)
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch (make-array i64 4))))"))

(define (compiler-typecheck-with-escape-box-result-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : (Box String)
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch (box (int->string 4)))))"))

(define (compiler-typecheck-with-escape-owning-aggregate-source) : String
  (compiler-typecheck-with-arena-source
    "(defstruct EscapePayload
  (name String)
  (items (Array String))
  (cell (Box String)))
(defenum EscapeResult
  (EscapeOk EscapePayload)
  (EscapeNone))
(define (main) : EscapeResult
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch
      (let
        [items : (Array String) (make-array String 2)]
        (begin
          (array-set! items 0 (int->string 1))
          (array-set! items 1 (int->string 2))
          (EscapeOk
            (EscapePayload
              (int->string 3)
              items
              (box (int->string 4)))))))))"))

(define (compiler-typecheck-with-escape-unsupported-result-source) : String
  (compiler-typecheck-with-arena-source
    "(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : (-> i64 i64)
  (let
    [scratch : i64 (arena-make)]
    (with-escape scratch inc)))"))

(define (compiler-typecheck-with-escape-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-escape-scalar-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-escape-string-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-escape-region-strip-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-escape-array-result-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-escape-box-result-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-escape-owning-aggregate-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-escape-bad-arena-source)
        "typecheck: with-escape arena must be i64")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-escape-unsupported-result-source)
        "typecheck: with-escape result type is not clone-supported: (-> i64 i64)")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-in-arena-string-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : String
  (let
    [scratch : i64 (arena-make)]
    (in-arena scratch (int->string 42))))"))

(define (compiler-typecheck-in-arena-array-result-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : (Array i64)
  (let
    [scratch : i64 (arena-make)]
    (in-arena scratch (make-array i64 4))))"))

(define (compiler-typecheck-in-arena-box-result-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : (Box String)
  (let
    [scratch : i64 (arena-make)]
    (in-arena scratch (box (int->string 4)))))"))

(define (compiler-typecheck-in-arena-bad-arena-source) : String
  "(define (main) : i64
  (in-arena true 1))")

(define (compiler-typecheck-in-arena-inner-region-escape-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : String
  (let
    [scratch : i64 (arena-make)]
    (in-arena scratch
      (with-arena inner (int->string 1)))))"))

(define (compiler-typecheck-in-arena-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok? (compiler-typecheck-in-arena-string-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-in-arena-array-result-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-in-arena-box-result-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-in-arena-bad-arena-source)
        "typecheck: in-arena arena must be i64")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-in-arena-inner-region-escape-source)
        "typecheck: region-tagged value cannot escape with-arena 'inner'")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-box-source) : String
  "(define (main) : i64
  (let
    [b : (Box i64) (box 7)]
    (box-get b)))")

(define (compiler-typecheck-box-direct-source) : String
  "(define (main) : i64 (box-get (box 7)))")

(define (compiler-typecheck-box-region-source) : String
  "(define (main) : i64
  (with-arena r
    (let
      [b : (in r (Box i64)) (box 7)]
      (box-get b))))")

(define (compiler-typecheck-box-region-project-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : String
  (with-arena r
    (let
      [b : (in r (Box String)) (box (int->string 41))]
      (box-get b))))"))

(define (compiler-typecheck-box-get-non-box-source) : String
  "(define (main) : i64 (box-get 1))")

(define (compiler-typecheck-box-take-source) : String
  "(define (main) : i64
  (let
    [b : (Box i64) (box 7)]
    (box-take b)))")

(define (compiler-typecheck-box-set-source) : String
  "(define (main) : i64
  (let
    [b : (Box i64) (box 7)]
    (begin
      (set! (box-get b) 9)
      (box-get b))))")

(define (compiler-typecheck-box-set-field-source) : String
  "(defstruct Pair (x i64) (y i64))
(define (main) : i64
  (let
    [b : (Box Pair) (box (Pair 1 2))]
    (begin
      (set! (struct-get (box-get b) x) 9)
      (struct-get (box-get b) x))))")

(define (compiler-typecheck-box-set-mismatch-source) : String
  "(define (main) : unit
  (let
    [b : (Box i64) (box 7)]
    (set! (box-get b) false)))")

(define (compiler-typecheck-box-take-non-box-source) : String
  "(define (main) : i64 (box-take 1))")

(define (compiler-typecheck-box-render-ok?) : bool
  (and
    (string-eq (tc-type-render (ast-ty-box (AstTyI64))) "(Box i64)")
    (tc-type-eq
      (ast-ty-box (ast-ty-region "r" (AstTyI64)))
      (ast-ty-box (AstTyI64)))
    (tc-type-contains-region (ast-ty-box (ast-ty-region "r" (AstTyString))) "r")
    (tc-type-move-only? (ast-ty-box (AstTyI64)))))

(define (compiler-typecheck-box-tests-ok?) : bool
  (and
    (compiler-typecheck-box-render-ok?)
    (compiler-typecheck-ok? (compiler-typecheck-box-source))
    (compiler-typecheck-ok? (compiler-typecheck-box-direct-source))
    (compiler-typecheck-ok? (compiler-typecheck-box-take-source))
    (compiler-typecheck-ok? (compiler-typecheck-box-set-source))
    (compiler-typecheck-ok? (compiler-typecheck-box-set-field-source))
    (compiler-typecheck-ok? (compiler-typecheck-box-region-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-box-region-project-source)
      "typecheck: region-tagged value cannot escape with-arena 'r'")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-box-get-non-box-source)
      "typecheck: box-get requires Box type")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-box-set-mismatch-source)
      "typecheck: box assignment type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-box-take-non-box-source)
      "typecheck: box-take requires Box type")))

(define (compiler-typecheck-init-source) : String
  "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some i64))
(define (main) : i64
  (let
    [n : i64 (init : i64)]
    [flag : bool (init : bool)]
    [text : String (init : String)]
    [items : (Array i64) (init : (Array i64))]
    [tupled : (Tuple i64 bool) (init : (Tuple i64 bool))]
    [fixed : (Array i64 2) (init : (Array i64 2))]
    [point : Point (init : Point)]
    [maybe : Maybe (init : Maybe)]
    [boxed : (Box i64) (init : (Box i64))]
    (+ n (+ (struct-get point x) (+ (tuple-ref tupled 0) (+ (array-ref fixed 0) (box-get boxed)))))))")

(define (compiler-typecheck-contextual-init-source) : String
  "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some i64))
(define zero : i64 (init))
(define (take [n : i64]) : i64 n)
(define (return-init) : i64 (init))
(define (point-x [p : Point]) : i64 (struct-get p x))
(define (main) : i64
  (let
    [n : i64 (init)]
    [items : (Array i64) (init)]
    [fixed : (Array i64 2) (array (init) 5)]
    [point : Point (Point (init) (init))]
    [maybe : Maybe (Some (init))]
    (begin
      (array-set! fixed 0 (init))
      (array-push! items (init))
      (+ zero
        (+ n
          (+ (return-init)
            (+ (take (init))
              (+ (point-x (init))
                (+ (struct-get point x)
                  (+ (array-ref fixed 0)
                    (match maybe [(Some v) v] [(None) 0])))))))))))")

(define (compiler-typecheck-init-function-source) : String
  "(define (main) : (-> i64) (init : (-> i64)))")

(define (compiler-typecheck-contextual-init-function-source) : String
  "(define (main) : (-> i64) (init))")

(define (compiler-typecheck-contextual-init-ambiguous-source) : String
  "(define (main) : i64 (let [n (init)] n))")

(define (compiler-typecheck-init-repr-c-source) : String
  "(defstruct Raw (:repr c) (x i64))
(define (main) : Raw (init : Raw))")

(define (compiler-typecheck-init-reference-source) : String
  "(define (main [n : i64]) : (& n i64) (init : (& n i64)))")

(define (compiler-typecheck-init-cleanup-owning-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main) : FileHandle (init : FileHandle))")

(define (compiler-typecheck-init-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-init-source))
    (compiler-typecheck-ok? (compiler-typecheck-contextual-init-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-init-function-source)
      "typecheck: init unsupported type (->  i64)")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-contextual-init-function-source)
      "typecheck: init unsupported type (->  i64)")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-contextual-init-ambiguous-source)
      "typecheck: contextual init requires an expected type; use (init : T) or add an annotation")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-init-repr-c-source)
      "typecheck: init supports only default-layout structs")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-init-reference-source)
      "typecheck: init unsupported type (& n i64)")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-init-cleanup-owning-source)
      "typecheck: init does not support cleanup-owning aggregate FileHandle")))

(define (compiler-typecheck-region-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-region-builtin-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-region-escape-source)
      "typecheck: region-tagged value cannot escape with-arena 'r'")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-region-user-call-source)
      "typecheck: cannot pass region-tagged value to function parameter; region value would escape")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-region-nested-escape-source)
      "typecheck: region-tagged value cannot escape with-arena 'inner'")
    (compiler-typecheck-ok? (compiler-typecheck-region-outer-in-inner-source))
    (compiler-typecheck-ok? (compiler-typecheck-region-array-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-region-struct-escape-source)
      "typecheck: region-tagged value cannot escape with-arena 'r'")
    (compiler-typecheck-ok? (compiler-typecheck-region-match-source))))

(define (compiler-typecheck-result-try-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read [flag : bool]) : ResultI64
  (if flag (OkI64 41) (ErrI64 \"read failed\")))
(define (step [flag : bool]) : ResultI64
  (OkI64 (try (read flag))))
(define (main [a : bool] [b : bool]) : ResultI64
  (let ([x : i64 (try (step a))]
        [y : i64 0])
    (begin
      (set! y (try (read b)))
      (OkI64 (+ x y)))))")

(define (compiler-typecheck-option-try-source) : String
  "(defenum MaybeI64 (SomeI64 i64) (NoneI64))
(defenum MaybeBool (NoneBool) (SomeBool bool))
(define (read [flag : bool]) : MaybeI64
  (if flag (SomeI64 41) NoneI64))
(define (main [flag : bool]) : MaybeBool
  (let ([x : i64 (try (read flag))])
    (SomeBool (> x 0))))")

(define (compiler-typecheck-result-try-non-result-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (main) : ResultI64
  (OkI64 (try 1)))")

(define (compiler-typecheck-result-try-non-result-return-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read) : ResultI64 (OkI64 1))
(define (main) : i64
  (try (read)))")

(define (compiler-typecheck-result-try-incompatible-error-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(defenum OtherResult (OkOther i64) (ErrOther i64))
(define (read) : OtherResult (ErrOther 7))
(define (main) : ResultI64
  (OkI64 (try (read))))")

(define (compiler-typecheck-option-try-carrier-mismatch-source) : String
  "(defenum MaybeI64 (SomeI64 i64) (NoneI64))
(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (read) : MaybeI64 (SomeI64 1))
(define (main) : ResultI64
  (OkI64 (try (read))))")

(define (compiler-typecheck-option-try-payloadless-some-source) : String
  "(defenum MaybeI64 (SomeI64) (NoneI64))
(define (read) : MaybeI64 SomeI64)
(define (main) : i64
  (try (read)))")

(define (compiler-typecheck-option-try-payloaded-none-source) : String
  "(defenum MaybeI64 (SomeI64 i64) (NoneI64 i64))
(define (read) : MaybeI64 (SomeI64 1))
(define (main) : i64
  (try (read)))")

(define (compiler-typecheck-result-try-panic-source) : String
  (compiler-typecheck-with-io-source
    "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (main [flag : bool]) : ResultI64
  (if flag (panic \"stop\") (OkI64 1)))"))

(define (compiler-typecheck-resource-with-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([a 1 close]
         [b (+ a 1) close])
    (+ a b)))")

(define (compiler-typecheck-resource-with-cleanup-mismatch-source) : String
  "(define (close [h : bool]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    h))")

(define (compiler-typecheck-resource-with-cleanup-return-source) : String
  "(define (close [h : i64]) : i64 h)
(define (main) : i64
  (with ([h 1 close])
    h))")

(define (compiler-typecheck-resource-with-cleanup-expression-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 (close h)])
    h))")

(define (compiler-typecheck-resource-with-nested-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([outer 1 close])
    (with ([inner (+ outer 1) close])
      (+ outer inner))))")

(define (compiler-typecheck-resource-with-let-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([copy h])
      copy)))")

(define (compiler-typecheck-resource-fresh-let-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main) : i64
  (let ([h : FileHandle (FileHandle 1)])
    0))")

(define (compiler-typecheck-resource-with-escape-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    h))")

(define (compiler-typecheck-resource-with-tuple-store-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([t : (Tuple i64 i64) (tuple h 2)])
      0)))")

(define (compiler-typecheck-resource-with-array-store-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([items : (Array i64 2) (array h 2)])
      0)))")

(define (compiler-typecheck-resource-with-struct-store-source) : String
  "(defstruct Box (value i64))
(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([box : Box (Box h)])
      0)))")

(define (compiler-typecheck-resource-with-enum-store-source) : String
  "(defenum Maybe (Some i64))
(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([m : Maybe (Some h)])
      0)))")

(define (compiler-typecheck-resource-with-lambda-capture-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    ((lambda () : i64 h))))")

(define (compiler-typecheck-resource-with-transfer-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close]
         [copy h close])
    copy))")

(define (compiler-typecheck-resource-with-assignment-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (let ([slot : i64 0])
    (with ([h 1 close])
      (set! slot h))))")

(define (compiler-typecheck-resource-with-shadow-source) : String
  "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let ([h : i64 2])
      ((lambda () : i64 h)))))")

(define (compiler-typecheck-resource-with-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-resource-with-source))
    (compiler-typecheck-ok? (compiler-typecheck-resource-with-nested-source))
    (compiler-typecheck-ok? (compiler-typecheck-resource-with-shadow-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-cleanup-mismatch-source)
      "typecheck: with cleanup function type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-cleanup-return-source)
      "typecheck: with cleanup function type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-cleanup-expression-source)
      "typecheck: with cleanup must be a direct function name")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-let-source)
      "typecheck: ordinary let cannot own cleanup-required resource; use with")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-fresh-let-source)
      "typecheck: ordinary let cannot own cleanup-required resource; use with")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-escape-source)
      "typecheck: cleanup-required resource would escape with scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-tuple-store-source)
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-array-store-source)
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-struct-store-source)
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-enum-store-source)
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-lambda-capture-source)
      "typecheck: lambda cannot capture cleanup-required resource; resource value would escape")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-transfer-source)
      "typecheck: cleanup-required resource already has a cleanup owner")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-resource-with-assignment-source)
      "typecheck: cannot store cleanup-required resource in longer-lived binding")))

(define (compiler-typecheck-cleanup-struct-valid-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main [h : FileHandle]) : i64 (struct-get h fd))")

(define (compiler-typecheck-cleanup-struct-nested-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct BufferedFile
  (:cleanup cleanup-buffered-file)
  (handle FileHandle (:owned))
  (size i64))
(define (main [b : BufferedFile]) : i64 (struct-get b size))")

(define (compiler-typecheck-cleanup-struct-imported-cleanup-source) : String
  "(module cleanup)
(define (close-fd [fd : i64]) : unit unit)
(export (value close-fd))
(module main)
(import \"cleanup.tl\" module cleanup :as c)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup c/close-fd)))
(define (main [h : FileHandle]) : i64 (struct-get h fd))")

(define (compiler-typecheck-cleanup-struct-comptime-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(comptime-decl
  (defstruct FileHandle
    (:cleanup cleanup-file-handle)
    (fd i64 (:cleanup close-fd))))
(define (main [h : FileHandle]) : i64 (struct-get h fd))")

(define (compiler-typecheck-cleanup-struct-ordinary-store-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Bad
  (handle FileHandle))")

(define (compiler-typecheck-cleanup-struct-cleanup-mismatch-source) : String
  "(define (close-bool [fd : bool]) : unit unit)
(defstruct Bad
  (:cleanup cleanup-bad)
  (fd i64 (:cleanup close-bool)))")

(define (compiler-typecheck-cleanup-struct-cleanup-return-source) : String
  "(define (close-fd [fd : i64]) : i64 fd)
(defstruct Bad
  (:cleanup cleanup-bad)
  (fd i64 (:cleanup close-fd)))")

(define (compiler-typecheck-cleanup-struct-owned-noncleanup-source) : String
  "(defstruct Bad
  (:cleanup cleanup-bad)
  (n i64 (:owned)))")

(define (compiler-typecheck-cleanup-struct-repr-c-ast-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-def-struct
        "Bad"
        (AstStructReprC)
        (ast-struct-cleanup-fn "cleanup-bad")
        (ast-field-def-cons
          (ast-field-def "fd" (AstTyI64) (AstFieldNoCleanup))
          AstFieldDefNil))
      AstDeclNil)))

(define (compiler-typecheck-cleanup-struct-field-outside-ast-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-def-struct
        "Bad"
        (AstStructReprDefault)
        (AstStructNoCleanup)
        (ast-field-def-cons
          (ast-field-def "fd" (AstTyI64) (ast-field-cleanup-fn "close-fd"))
          AstFieldDefNil))
      AstDeclNil)))

(define (compiler-typecheck-cleanup-struct-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-cleanup-struct-valid-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-cleanup-struct-nested-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-cleanup-struct-imported-cleanup-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-cleanup-struct-comptime-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-cleanup-struct-ordinary-store-source)
        "typecheck: struct Bad field handle stores cleanup-owning type FileHandle without :owned")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-cleanup-struct-cleanup-mismatch-source)
        "typecheck: struct Bad field fd cleanup function close-bool type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-cleanup-struct-cleanup-return-source)
        "typecheck: struct Bad field fd cleanup function close-fd type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-cleanup-struct-owned-noncleanup-source)
        "typecheck: struct Bad field n uses :owned but type i64 is not cleanup-owning")
        unit
        (set! ok false))
      (if (compiler-typecheck-program-error-ok?
        (compiler-typecheck-cleanup-struct-repr-c-ast-program)
        "typecheck: cleanup-owning struct Bad cannot use repr c")
        unit
        (set! ok false))
      (if (compiler-typecheck-program-error-ok?
        (compiler-typecheck-cleanup-struct-field-outside-ast-program)
        "typecheck: struct Bad field fd has cleanup metadata but struct is not cleanup-owning")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-cleanup-enum-valid-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(define (close-code [code : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defenum MaybeHandle
  (:cleanup cleanup-maybe-handle)
  (None)
  (Some FileHandle (:owned))
  (Code i64 (:cleanup close-code)))
(define (main [m : MaybeHandle]) : i64 0)")

(define (compiler-typecheck-cleanup-enum-ordinary-store-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defenum Bad
  (Some FileHandle))")

(define (compiler-typecheck-cleanup-enum-cleanup-mismatch-source) : String
  "(define (close-bool [fd : bool]) : unit unit)
(defenum Bad
  (:cleanup cleanup-bad)
  (A i64 (:cleanup close-bool)))")

(define (compiler-typecheck-cleanup-enum-cleanup-return-source) : String
  "(define (close-fd [fd : i64]) : i64 fd)
(defenum Bad
  (:cleanup cleanup-bad)
  (A i64 (:cleanup close-fd)))")

(define (compiler-typecheck-cleanup-enum-owned-noncleanup-source) : String
  "(defenum Bad
  (:cleanup cleanup-bad)
  (A i64 (:owned)))")

(define (compiler-typecheck-cleanup-enum-payload-outside-ast-program) : AstProgram
  (ast-program
    (ast-decl-cons
      (ast-decl-def-enum
        "Bad"
        (AstEnumNoCleanup)
        (ast-variant-def-cons
          (ast-variant-def
            "A"
            (ast-type-cons (AstTyI64) AstTypeNil)
            (ast-variant-payload-cleanup-cons
              (ast-variant-payload-cleanup-fn "close-fd")
              AstVariantPayloadCleanupNil))
          AstVariantDefNil))
      AstDeclNil)))

(define (compiler-typecheck-cleanup-enum-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-cleanup-enum-valid-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-cleanup-enum-ordinary-store-source)
        "typecheck: enum Bad variant Some stores cleanup-owning type FileHandle without :owned")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-cleanup-enum-cleanup-mismatch-source)
        "typecheck: enum Bad variant A cleanup function close-bool type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-cleanup-enum-cleanup-return-source)
        "typecheck: enum Bad variant A cleanup function close-fd type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-cleanup-enum-owned-noncleanup-source)
        "typecheck: enum Bad variant A uses :owned but type i64 is not cleanup-owning")
        unit
        (set! ok false))
      (if (compiler-typecheck-program-error-ok?
        (compiler-typecheck-cleanup-enum-payload-outside-ast-program)
        "typecheck: enum Bad variant A has payload cleanup metadata but enum is not cleanup-owning")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-result-try-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-result-try-source))
    (compiler-typecheck-ok? (compiler-typecheck-option-try-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-result-try-non-result-source)
      "typecheck: try operand must be Result-like enum")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-result-try-non-result-return-source)
      "typecheck: try requires enclosing Result-like function")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-result-try-incompatible-error-source)
      "typecheck: try error type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-option-try-carrier-mismatch-source)
      "typecheck: try carrier mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-option-try-payloadless-some-source)
      "typecheck: try operand must be Result-like enum")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-option-try-payloaded-none-source)
      "typecheck: try operand must be Result-like enum")
    (compiler-typecheck-ok? (compiler-typecheck-result-try-panic-source))))

(define (compiler-typecheck-move-kind-copyable-tests-ok?) : bool
  (and
    (tc-type-copyable? (AstTyI64))
    (tc-type-copyable? (AstTyI32))
    (tc-type-copyable? (AstTyF64))
    (tc-type-copyable? (AstTyF32))
    (tc-type-copyable? (AstTyBool))
    (tc-type-copyable? (AstTyChar))
    (tc-type-copyable? (AstTyUnit))
    (tc-type-copyable? (AstTyNever))
    (tc-type-copyable? (ast-ty-func AstTypeNil (AstTyI64)))
    (tc-type-copyable? (ast-ty-ptr (ast-ty-region "inner" (AstTyString))))
    (tc-type-copyable? (ast-ty-mut-ptr (ast-ty-dyn-array (AstTyI64))))
    (tc-type-copyable? (ast-ty-ref "r" (AstTyString)))))

(define (compiler-typecheck-move-kind-move-only-tests-ok?) : bool
  (and
    (tc-type-move-only? (AstTyString))
    (tc-type-move-only? (ast-ty-dyn-array (AstTyI64)))
    (tc-type-move-only? (ast-ty-array (AstTyI64) 4))
    (tc-type-move-only?
      (AstTyTuple
        (ast-type-cons (AstTyI64) (ast-type-cons (AstTyBool) AstTypeNil))))
    (tc-type-move-only? (AstTyStruct (intern "Box")))
    (tc-type-move-only? (ast-ty-box (AstTyI64)))
    (tc-type-move-only? (AstTyEnum (intern "ResultI64")))
    (tc-type-move-only? (ast-ty-mut-ref "phase" (AstTyI64)))
    (tc-type-move-only?
      (AstTyTuple
        (ast-type-cons
          (AstTyStruct (intern "Box"))
          (ast-type-cons (ast-ty-dyn-array (AstTyI64)) AstTypeNil))))))

(define (compiler-typecheck-move-kind-region-tests-ok?) : bool
  (and
    (tc-type-copyable? (ast-ty-region "r" (AstTyI64)))
    (tc-type-copyable? (ast-ty-region "r" (ast-ty-ref "inner" (AstTyString))))
    (tc-type-move-only? (ast-ty-region "r" (AstTyString)))
    (tc-type-move-only?
      (ast-ty-region "r" (AstTyTuple (ast-type-cons (AstTyI64) AstTypeNil))))
    (tc-type-move-only? (ast-ty-region "r" (ast-ty-mut-ref "phase" (AstTyI64))))))

(define (compiler-typecheck-move-kind-tests-ok?) : bool
  (and
    (compiler-typecheck-move-kind-copyable-tests-ok?)
    (compiler-typecheck-move-kind-move-only-tests-ok?)
    (compiler-typecheck-move-kind-region-tests-ok?)))

(define (compiler-typecheck-raw-pointer-source) : String
  "(extern (raw-sink [arg0 : (Ptr i64)]) : unit)
(extern (raw-make) : (MutPtr (Ptr u8)))
(define (main [p : (Ptr i64)]) : unit
  (raw-sink p))")

(define (compiler-typecheck-raw-pointer-render-ok?) : bool
  (and
    (string-eq (tc-type-render (ast-ty-ptr (AstTyI64))) "(Ptr i64)")
    (string-eq
      (tc-type-render (ast-ty-mut-ptr (ast-ty-ptr (AstTyU8))))
      "(MutPtr (Ptr u8))")
    (tc-type-eq (ast-ty-ptr (AstTyI64)) (ast-ty-ptr (AstTyI64)))
    (not (tc-type-eq (ast-ty-ptr (AstTyI64)) (ast-ty-mut-ptr (AstTyI64))))
    (tc-type-eq
      (ast-ty-ptr (ast-ty-region "r" (AstTyI64)))
      (ast-ty-ptr (AstTyI64)))))

(define (compiler-typecheck-raw-pointer-ops-source) : String
  "(extern (raw-make) : (MutPtr i64))
(define (main [n : u64]) : u64
  (unsafe
    (let
      [cell : i64 0]
      [local : (MutPtr i64) (ptr-addr-of cell)]
      (begin
        (ptr-write! local 41)
        (ptr-read local)
        (ptr-write! (raw-make) 41)
        (ptr-read (raw-make))
        (ptr->int (ptr-offset (ptr-cast (int->ptr n : (MutPtr i64)) : (Ptr i64)) 1))))))")

(define (compiler-typecheck-raw-pointer-cast-source) : String
  "(define (main [n : u64]) : (Ptr u8)
  (unsafe (ptr-cast (int->ptr n : (MutPtr i64)) : (Ptr u8))))")

(define (compiler-typecheck-raw-pointer-safe-read-source) : String
  "(define (main [p : (Ptr i64)]) : i64 (ptr-read p))")

(define (compiler-typecheck-raw-pointer-safe-addr-of-source) : String
  "(define (main [x : i64]) : (MutPtr i64) (ptr-addr-of x))")

(define (compiler-typecheck-raw-pointer-safe-marker-shadow-source) : String
  "(define (main [p : (Ptr i64)]) : i64
  (let [__tl_unsafe_context : unit unit] (ptr-read p)))")

(define (compiler-typecheck-safe-syscall-source) : String
  "(define (main) : i64 (syscall 39))")

(define (compiler-typecheck-unsafe-syscall-source) : String
  "(define (main) : i64 (unsafe (syscall 39)))")

(define (compiler-typecheck-unsafe-syscall-operand-source) : String
  "(define (main) : i64 (unsafe (syscall true)))")

(define (compiler-typecheck-raw-pointer-write-const-source) : String
  "(define (main [p : (Ptr i64)]) : unit (unsafe (ptr-write! p 1)))")

(define (compiler-typecheck-raw-pointer-write-mismatch-source) : String
  "(define (main [p : (MutPtr i64)]) : unit (unsafe (ptr-write! p true)))")

(define (compiler-typecheck-raw-pointer-offset-bad-source) : String
  "(define (main [p : (Ptr i64)]) : (Ptr i64) (unsafe (ptr-offset p true)))")

(define (compiler-typecheck-raw-pointer-cast-bad-target-source) : String
  "(define (main [p : (Ptr i64)]) : i64 (unsafe (ptr-cast p : i64)))")

(define (compiler-typecheck-raw-pointer-int-to-ptr-bad-source) : String
  "(define (main [b : bool]) : (Ptr i64) (unsafe (int->ptr b : (Ptr i64))))")

(define (compiler-typecheck-raw-pointer-addr-of-global-source) : String
  "(define x : i64 1)
(define (main) : (MutPtr i64) (unsafe (ptr-addr-of x)))")

(define (compiler-typecheck-raw-pointer-addr-of-aggregate-source) : String
  "(define (main [text : String]) : (MutPtr String)
  (unsafe (ptr-addr-of text)))")

(define (compiler-typecheck-atomic-pointer-ops-source) : String
  "(define (main
  [p64 : (MutPtr i64)]
  [q64 : (MutPtr u64)]
  [p32 : (MutPtr i32)]
  [q32 : (MutPtr u32)]) : i64
  (unsafe
    (begin
      (atomic-store! p64 1)
      (atomic-add! p64 2)
      (atomic-fetch-add! p64 3)
      (atomic-cas! p64 6 7)
      (atomic-store! q64 (cast 1 : u64))
      (atomic-add! q64 (cast 2 : u64))
      (atomic-fetch-add! q64 (cast 3 : u64))
      (atomic-cas! q64 (cast 6 : u64) (cast 7 : u64))
      (atomic-store! p32 (cast 1 : i32))
      (atomic-add! p32 (cast 2 : i32))
      (atomic-fetch-add! p32 (cast 3 : i32))
      (atomic-cas! p32 (cast 6 : i32) (cast 7 : i32))
      (atomic-store! q32 (cast 1 : u32))
      (atomic-add! q32 (cast 2 : u32))
      (atomic-fetch-add! q32 (cast 3 : u32))
      (atomic-cas! q32 (cast 6 : u32) (cast 7 : u32))
      (atomic-load p64))))")

(define (compiler-typecheck-atomic-pointer-safe-source) : String
  "(define (main [p : (MutPtr i64)]) : i64
  (atomic-load p))")

(define (compiler-typecheck-atomic-pointer-store-mismatch-source) : String
  "(define (main [p : (MutPtr i64)]) : unit
  (unsafe (atomic-store! p true)))")

(define (compiler-typecheck-atomic-pointer-add-const-source) : String
  "(define (main [p : (Ptr i64)]) : unit
  (unsafe (atomic-add! p 1)))")

(define (compiler-typecheck-atomic-pointer-bad-elem-source) : String
  "(define (main [p : (MutPtr u8)]) : u8
  (unsafe (atomic-load p)))")

(define (compiler-typecheck-raw-pointer-op-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-raw-pointer-ops-source))
    (compiler-typecheck-ok? (compiler-typecheck-raw-pointer-cast-source))
    (compiler-typecheck-ok? (compiler-typecheck-atomic-pointer-ops-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-safe-read-source)
      "typecheck: ptr-read requires unsafe context")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-safe-addr-of-source)
      "typecheck: ptr-addr-of requires unsafe context")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-safe-marker-shadow-source)
      "typecheck: ptr-read requires unsafe context")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-safe-syscall-source)
      "typecheck: syscall requires unsafe context")
    (compiler-typecheck-ok? (compiler-typecheck-unsafe-syscall-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-unsafe-syscall-operand-source)
      "typecheck: syscall operands must be integer")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-write-const-source)
      "typecheck: ptr-write! requires a MutPtr pointer operand")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-write-mismatch-source)
      "typecheck: ptr-write! value type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-offset-bad-source)
      "typecheck: ptr-offset requires an integer offset")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-cast-bad-target-source)
      "typecheck: ptr-cast target must be a raw pointer type")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-int-to-ptr-bad-source)
      "typecheck: int->ptr requires an integer operand")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-addr-of-global-source)
      "typecheck: ptr-addr-of requires a local or parameter name")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-raw-pointer-addr-of-aggregate-source)
      "typecheck: ptr-addr-of supports local scalar cells only")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-atomic-pointer-safe-source)
      "typecheck: atomic-load requires unsafe context")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-atomic-pointer-store-mismatch-source)
      "typecheck: atomic value type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-atomic-pointer-add-const-source)
      "typecheck: atomic-add! requires a MutPtr pointer operand")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-atomic-pointer-bad-elem-source)
      "typecheck: atomic pointer element must be i32, i64, u32, or u64")))

(define (compiler-typecheck-raw-pointer-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-raw-pointer-source))
    (compiler-typecheck-raw-pointer-render-ok?)))

(define (compiler-typecheck-extern-abi-source) : String
  "(defstruct Box (value i64))
(extern (foreign-callback [arg0 : (Ptr i64)] [arg1 : (-> i64 i64)]) : i64 (:abi c) (:symbol \"foreign_callback\") (:link-lib \"ffi_callback\") (:link-search \"native\") (:link-arg \"-Wl,--whole-archive\"))
(extern (foreign-box [arg0 : Box]) : unit (:abi c) (:symbol \"foreign_box\"))")

(define (compiler-typecheck-extern-abi-tuple-source) : String
  "(extern (bad [arg0 : (Tuple i64 i64)]) : i64 (:abi c) (:symbol \"bad_tuple\"))")

(define (compiler-typecheck-extern-abi-array-source) : String
  "(extern (bad [arg0 : (Array i64 2)]) : i64 (:abi c) (:symbol \"bad_array\"))")

(define (compiler-typecheck-extern-abi-f32-source) : String
  "(extern (bad [arg0 : f32]) : f32 (:abi c) (:symbol \"bad_f32\"))")

(define (compiler-typecheck-extern-abi-tag-only-enum-source) : String
  "(defenum Status (Ready) (Done) (Failed))
(extern (status-echo [arg0 : Status]) : Status (:abi c) (:symbol \"status_echo\"))
(extern (status-varargs [arg0 : Status] [arg1 : ...Status]) : i64 (:abi c) (:symbol \"status_varargs\"))
(extern status-echo-ptr (:symbol \"status_echo_ptr\") : (-> Status Status))
(define (main) : i64
  (let
    [copied : (-> Status Status) status-echo-ptr]
    [echoed : Status (status-echo (Ready))]
    [copied-echoed : Status (copied echoed)]
    (status-varargs copied-echoed (Done) (Failed))))")

(define (compiler-typecheck-extern-abi-enum-param-source) : String
  "(defenum ResultI64 (OkI64 i64))
(extern (bad [arg0 : ResultI64]) : i64 (:abi c) (:symbol \"bad_enum_param\"))")

(define (compiler-typecheck-extern-abi-enum-return-source) : String
  "(defenum ResultI64 (OkI64 i64))
(extern (bad [arg0 : i64]) : ResultI64 (:abi c) (:symbol \"bad_enum_return\"))")

(define (compiler-typecheck-extern-abi-enum-args-param-source) : String
  "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))
(extern (bad [arg0 : (RefOption n)]) : i64 (:abi c) (:symbol \"bad_enum_args_param\"))")

(define (compiler-typecheck-extern-abi-enum-args-return-source) : String
  "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))
(extern (bad [arg0 : i64]) : (RefOption n) (:abi c) (:symbol \"bad_enum_args_return\"))")

(define (compiler-typecheck-extern-head-varargs-open-source) : String
  "(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol \"printf\"))
(define (main [fmt : (Ptr u8)]) : i64
  (cast (printf fmt 1 2.0) : i64))")

(define (compiler-typecheck-extern-head-varargs-typed-source) : String
  "(extern (sumf [count : i64] [value : ...f64]) : i32 (:symbol \"sumf\"))
(define (main) : i64
  (cast (sumf 2 1.0 2.0) : i64))")

(define (compiler-typecheck-extern-head-varargs-typed-mismatch-source) : String
  "(extern (sumf [count : i64] [value : ...f64]) : i32 (:symbol \"sumf\"))
(define (main) : i64
  (cast (sumf 1 true) : i64))")

(define (compiler-typecheck-extern-head-varargs-tail-enum-source) : String
  "(defenum ResultI64 (OkI64 i64))
(extern (bad [count : i64] [value : ...ResultI64]) : i64 (:symbol \"bad\"))")

(define (compiler-typecheck-extern-raw-fnptr-to-tl-param-source) : String
  "(extern raw-fn (:symbol \"tl_test_raw_fn\") : (-> i64 i64))
(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64 (f x))
(define (main) : i64
  (let [copied : (-> i64 i64) raw-fn]
    (apply1 copied 41)))")

(define (compiler-typecheck-extern-head-fixed-source) : String
  "(extern (local-add [a : i64] [b : i64]) : i64 (:symbol \"foreign_add_exact\"))
(define (main) : i64
  (local-add 1 2))")

(define (compiler-typecheck-extern-head-varargs-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-extern-head-fixed-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-extern-head-varargs-open-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-extern-head-varargs-typed-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-extern-head-varargs-typed-mismatch-source)
      "typecheck: argument type mismatch")
    (compiler-typecheck-ok?
      (compiler-typecheck-extern-head-varargs-tail-enum-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-extern-raw-fnptr-to-tl-param-source)
      "typecheck: raw C function pointer cannot be used as a TypeLisp function value")))

(define (compiler-typecheck-extern-abi-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-extern-abi-source))
    (compiler-typecheck-extern-head-varargs-tests-ok?)
    (compiler-typecheck-error-ok?
      (compiler-typecheck-extern-abi-tuple-source)
      "typecheck: extern ABI c does not support parameter type (Tuple i64 i64)")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-extern-abi-array-source)
      "typecheck: extern ABI c does not support parameter type (Array i64 2)")
    ;; Scalar `f32` is a supported C ABI extern parameter and return type
    ;; (passed/returned in XMM registers via single-precision `movss`).
    (compiler-typecheck-ok? (compiler-typecheck-extern-abi-f32-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-extern-abi-tag-only-enum-source))
    (compiler-typecheck-ok? (compiler-typecheck-extern-abi-enum-param-source))
    (compiler-typecheck-ok? (compiler-typecheck-extern-abi-enum-return-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-extern-abi-enum-args-param-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-extern-abi-enum-args-return-source))))

(define (compiler-typecheck-reference-local-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (let [r : (& n i64) (& n)]
    (take r)))")

(define (compiler-typecheck-reference-param-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& n)))")

(define (compiler-typecheck-reference-projection-source) : String
  "(defstruct Pair (left i64) (right i64))
(define (take-pair [r : (& p i64)]) : unit unit)
(define (take-tuple [r : (& t i64)]) : unit unit)
(define (take-array [r : (& items i64)]) : unit unit)
(define (main [p : Pair] [t : (Tuple i64 bool)] [items : (Array i64)]) : unit
  (begin
    (take-pair (& (struct-get p left)))
    (take-tuple (& (tuple-ref t 0)))
    (take-array (& (array-ref items 0)))))")

(define (compiler-typecheck-reference-temp-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& (+ n 1))))")

(define (compiler-typecheck-reference-mismatch-source) : String
  "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& other n)))")

(define (compiler-typecheck-reference-return-source) : String
  "(define (main [n : i64]) : (& n i64)
  (& n))")

(define (compiler-typecheck-reference-return-param-ref-source) : String
  "(define (id [r : (& n i64)]) : (& n i64) r)
(define (main [n : i64]) : (& n i64)
  (id (& n)))")

(define (compiler-typecheck-reference-return-untied-source) : String
  "(define (main [n : i64]) : (& other i64)
  (& n))")

(define (compiler-typecheck-reference-return-local-escape-source) : String
  "(define (main [n : i64]) : (& n i64)
  (let [x : i64 1] (& x)))")

(define (compiler-typecheck-reference-struct-field-source) : String
  "(defstruct RefBox (value (& n i64)))
(define (main [n : i64]) : i64
  (let
    [box : RefBox (RefBox (& n))]
    (let [value : (& n i64) (struct-get box value)] 0)))")

(define (compiler-typecheck-reference-enum-payload-source) : String
  "(defenum RefOption (SomeRef (& n i64)) (NoRef))
(define (main [n : i64]) : i64
  (match (SomeRef (& n))
    [(SomeRef value) 0]
    [(NoRef) 1]))")

(define (compiler-typecheck-lifetime-struct-return-source) : String
  "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [value : (& n i64)]) : (RefBox n)
  (RefBox value))")

(define (compiler-typecheck-lifetime-struct-field-source) : String
  "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [n : i64]) : i64
  (let
    [box : (RefBox n) (RefBox (& n))]
    (let [value : (& n i64) (struct-get box value)] 0)))")

(define (compiler-typecheck-lifetime-enum-match-source) : String
  "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))
(define (main [n : i64]) : i64
  (match (SomeRef (& n))
    [(SomeRef value) (let [same : (& n i64) value] 0)]
    [(NoRef) 1]))")

(define (compiler-typecheck-borrowed-enum-match-scalar-source) : String
  "(defenum Maybe (None) (Some i64))
(define (take [v : (& m i64)]) : i64 7)
(define (main [m : Maybe]) : i64
  (+
    (match (& m)
      [(Some v) (let [same : (& m i64) v] (take same))]
      [None 0])
    (match m
      [(Some _) 1]
      [None 0])))")

(define (compiler-typecheck-borrowed-enum-match-str-source) : String
  "(defenum Item (Named String) (Empty))
(define (borrowed-name-length [s : (& item str)]) : i64 (string-length s))
(define (main [item : Item]) : i64
  (match (& item)
    [(Named s) (let [same : (& item str) s] (borrowed-name-length same))]
    [Empty 0]))")

(define (compiler-typecheck-borrowed-enum-match-array-source) : String
  "(defenum Maybe (None) (Some i64))
(define (take [v : (& items i64)]) : i64 7)
(define (main [items : (Array Maybe 2)]) : i64
  (match (& (array-ref items 0))
    [(Some v) (let [same : (& items i64) v] (take same))]
    [None 0]))")

(define (compiler-typecheck-borrowed-enum-match-ref-struct-array-source) : String
  "(defenum Slot (Empty) (Occupied i64))
(defstruct Bag (slots (Array Slot)))
(defenum SlotLookup (:lifetimes bag) (SlotMissing) (SlotFound (& bag i64)))
(define (take [v : (& bag i64)]) : i64 7)
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) (SlotMissing))
(define (slot-found [value : (& bag i64)]) : (SlotLookup bag) (SlotFound value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref (struct-get bag slots) 0))
    [(Occupied v) (let [same : (& bag i64) v] (slot-found same))]
    [Empty (slot-missing bag)]))
(define (score [bag : (& bag Bag)]) : i64
  (match (& (array-ref (struct-get bag slots) 0))
    [(Occupied v) (let [same : (& bag i64) v] (take same))]
    [Empty 0]))
(define (main [bag : Bag]) : i64
  (+ (score (& bag))
    (match (lookup (& bag))
      [(SlotFound v) (take v)]
      [SlotMissing 0])))")

(define (compiler-typecheck-borrowed-enum-match-nested-source) : String
  "(defenum Inner (A i64) (B i64))
(defenum Outer (Wrap Inner) (Empty))
(define (take [v : (& o i64)]) : i64 7)
(define (main [o : Outer]) : i64
  (match (& o)
    [(Wrap (A 0)) 10]
    [(Wrap (A n)) (take n)]
    [(Wrap _) 1]
    [Empty 0]))")

(define (compiler-typecheck-borrowed-enum-match-temp-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main) : i64
  (match (& (Some 1))
    [(Some _) 1]
    [None 0]))")

(define (compiler-typecheck-borrowed-enum-match-escape-source) : String
  (compiler-typecheck-with-io-source
    "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : (& other i64)
  (match (& m)
    [(Some v) v]
    [None (panic \"none\")]))"))

(define (compiler-typecheck-returned-borrowed-lookup-assign-source) : String
  "(defenum Slot (Empty) (Occupied i64))
(defstruct Bag (slots (Array Slot)))
(defenum SlotLookup (:lifetimes bag) (SlotMissing) (SlotFound (& bag i64)))
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) (SlotMissing))
(define (slot-found [value : (& bag i64)]) : (SlotLookup bag) (SlotFound value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref (struct-get bag slots) 0))
    [(Occupied v) (slot-found v)]
    [Empty (slot-missing bag)]))
(define (bad [bag : Bag]) : unit
  (match (lookup (& bag))
    [(SlotFound value) (set! bag (Bag (make-array Slot 1)))]
    [SlotMissing unit]))")

(define (compiler-typecheck-returned-borrowed-lookup-array-set-source) : String
  "(defenum Slot (Empty) (Occupied i64))
(defstruct Bag (slots (Array Slot)))
(defenum SlotLookup (:lifetimes bag) (SlotMissing) (SlotFound (& bag i64)))
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) (SlotMissing))
(define (slot-found [value : (& bag i64)]) : (SlotLookup bag) (SlotFound value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref (struct-get bag slots) 0))
    [(Occupied v) (slot-found v)]
    [Empty (slot-missing bag)]))
(define (bad [bag : Bag]) : unit
  (match (lookup (& bag))
    [(SlotFound value) (array-set! (struct-get bag slots) 0 Empty)]
    [SlotMissing unit]))")

(define (compiler-typecheck-regular-call-lifetime-subst-source) : String
  "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (ref-id [value : (& a i64)]) : (& a i64) value)
(define (box-id [value : (& a i64)]) : (RefBox a) (RefBox value))
(define (main [n : i64]) : i64
  (let
    [direct : (& n i64) (ref-id (& n))]
    [box : (RefBox n) (box-id (& n))]
    (let [value : (& n i64) (struct-get box value)] 0)))")

(define (compiler-typecheck-regular-call-lifetime-conflict-source) : String
  "(define (same-owner [a : (& source i64)] [b : (& source i64)]) : i64 0)
(define (main [n : i64]) : i64
  (let [other : i64 1] (same-owner (& n) (& other))))")

(define (compiler-typecheck-lifetime-duplicate-source) : String
  "(defstruct RefBox (:lifetimes a a) (value (& a i64)))")

(define (compiler-typecheck-lifetime-missing-args-source) : String
  "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [box : RefBox]) : unit unit)")

(define (compiler-typecheck-lifetime-arity-source) : String
  "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [box : (RefBox n extra)]) : unit unit)")

(define (compiler-typecheck-lifetime-unknown-decl-source) : String
  "(defstruct RefBox (:lifetimes a) (value (& b i64)))")

(define (compiler-typecheck-lifetime-untied-return-source) : String
  "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [n : i64]) : (RefBox other)
  (RefBox (& n)))")

(define (compiler-typecheck-lifetime-local-escape-source) : String
  "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [n : i64]) : (RefBox n)
  (let [x : i64 1] (RefBox (& x))))")

(define (compiler-typecheck-reference-array-stored-source) : String
  "(define (main [n : i64]) : i64
  (let
    [items : (Array (& n i64) 1) (array (& n))]
    (let [value : (& n i64) (array-ref items 0)] 0)))")

(define (compiler-typecheck-reference-struct-return-source) : String
  "(defstruct RefBox (value (& n i64)))
(define (main [n : i64]) : RefBox
  (RefBox (& n)))")

(define (compiler-typecheck-reference-struct-local-escape-source) : String
  "(defstruct RefBox (value (& x i64)))
(define (main) : RefBox
  (let [x : i64 1] (RefBox (& x))))")

(define (compiler-typecheck-reference-lambda-return-source) : String
  "(define (main [n : i64]) : i64
  (begin
    (lambda ([x : i64]) : (& x i64) (& x))
    n))")

(define (compiler-typecheck-reference-mut-source) : String
  "(define (main [n : (&mut phase i64)]) : unit unit)")

(define (compiler-typecheck-reference-mut-borrow-source) : String
  "(define (take [r : (&mut n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (&mut n)))")

(define (compiler-typecheck-reference-mut-array-set-source) : String
  "(define (put [items : (&mut items (Array i64))] [v : i64]) : unit
  (array-set! items 0 v))
(define (main [items : (Array i64)]) : unit
  (put (&mut items) 7))")

(define (compiler-typecheck-reference-mut-array-push-source) : String
  "(define (grow [items : (&mut items (Array i64))] [v : i64]) : unit
  (array-push! items v))
(define (main [items : (Array i64)]) : unit
  (grow (&mut items) 7))")

(define (compiler-typecheck-reference-immut-array-set-source) : String
  "(define (bad [items : (& items (Array i64))]) : unit
  (array-set! items 0 7))")

(define (compiler-typecheck-reference-str-source) : String
  "(define (take [s : (& text str)]) : unit unit)
(define (main [text : String]) : unit
  (let [view : (& text str) (& text)]
    (take view)))")

(define (compiler-typecheck-reference-str-auto-borrow-source) : String
  "(define (take [s : (& text str)]) : unit unit)
(define (main [text : String]) : unit
  (take text))")

(define (compiler-typecheck-reference-str-region-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (take [s : (& r str)]) : unit unit)
(define (main) : unit
  (with-arena r
    (let [text : String (int->string 41)]
      (take (& r text)))))"))

(define (compiler-typecheck-str-value-source) : String
  "(define (main [s : str]) : unit unit)")

(define (compiler-typecheck-str-return-source) : String
  "(define (main) : str \"x\")")

(define (compiler-typecheck-str-local-source) : String
  "(define (main) : unit (let [s : str \"x\"] unit))")

(define (compiler-typecheck-str-global-source) : String
  "(define bad : str \"x\")")

(define (compiler-typecheck-str-field-source) : String
  "(defstruct Bad (s str))")

(define (compiler-typecheck-str-variant-source) : String
  "(defenum Bad (S str))")

(define (compiler-typecheck-str-mut-ref-source) : String
  "(define (main [s : (&mut text str)]) : unit unit)")

(define (compiler-typecheck-owner-stack-local-source) : String
  "(define (main) : i64
  (let
    [x : i64 1]
    (let [r : (& x i64) (& x)] x)))")

(define (compiler-typecheck-owner-stack-local-escape-source) : String
  "(define (main [n : i64]) : (& n i64)
  (let [x : i64 1] (& x)))")

(define (compiler-typecheck-owner-default-arena-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : String
  (let
    [text : String (int->string 42)]
    (with-arena phase
      (let [n : i64 (string-length text)] text))))"))

(define (compiler-typecheck-owner-scoped-arena-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : i64
  (with-arena phase
    (let
      [text : String (int->string 42)]
      (string-length text))))"))

(define (compiler-typecheck-owner-scoped-arena-escape-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : String
  (with-arena phase (int->string 42)))"))

(define (compiler-typecheck-channel-atomic-string-send-source) : String
  (compiler-typecheck-with-arena-source
    "(extern (tl_arena_make_atomic) : i64)
(define (arena-make-atomic) : i64 (tl_arena_make_atomic))
(defstruct ChannelString (raw i64))
(defenum ChannelStringSendResult
  (ChannelStringSendOk)
  (ChannelStringSendErr String))
(define (channel-string-send
  [channel : ChannelString]
  [message : String]) : ChannelStringSendResult
  (ChannelStringSendOk))
(define (main) : i64
  (let
    [owner : i64 (arena-make-atomic)]
    [channel : ChannelString (ChannelString 0)]
    [message (in-arena owner (string-append \"atom\" \"ic\"))]
    [sent : ChannelStringSendResult (channel-string-send channel message)]
    42))"))

(define (compiler-typecheck-channel-ordinary-string-send-source) : String
  (compiler-typecheck-with-arena-source
    "(defstruct ChannelString (raw i64))
(defenum ChannelStringSendResult
  (ChannelStringSendOk)
  (ChannelStringSendErr String))
(define (channel-string-send
  [channel : ChannelString]
  [message : String]) : ChannelStringSendResult
  (ChannelStringSendOk))
(define (main) : i64
  (let
    [owner : i64 (arena-make)]
    [channel : ChannelString (ChannelString 0)]
    [message (in-arena owner (string-append \"ordinary\" \"arena\"))]
    [sent : ChannelStringSendResult (channel-string-send channel message)]
    42))"))

(define (compiler-typecheck-owner-model-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-owner-stack-local-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-owner-stack-local-escape-source)
      "typecheck: reference value would escape lexical scope")
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-return-param-ref-source))
    (compiler-typecheck-ok? (compiler-typecheck-owner-default-arena-source))
    (compiler-typecheck-ok? (compiler-typecheck-owner-scoped-arena-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-owner-scoped-arena-escape-source)
      "typecheck: region-tagged value cannot escape with-arena 'phase'")
    (compiler-typecheck-ok?
      (compiler-typecheck-channel-atomic-string-send-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-channel-ordinary-string-send-source)
      "typecheck: channel-string-send cannot send value of type String; owned heap storage needs a static/program or spanning atomic owner proof")
    (compiler-typecheck-ok? (compiler-typecheck-with-escape-string-source))))

(define (compiler-typecheck-reference-render-ok?) : bool
  (let
    [string-ref-render-ok : bool
      (string-eq (tc-type-render (ast-ty-ref "r" (AstTyString))) "(& r String)")]
    [str-ref-render-ok : bool
      (string-eq (tc-type-render (ast-ty-ref "r" (AstTyStr))) "(& r str)")]
    [bytes-ref-render-ok : bool
      (string-eq (tc-type-render (ast-ty-ref "r" (AstTyBytes))) "(& r bytes)")]
    [bytes-mut-ref-render-ok : bool
      (string-eq
        (tc-type-render (ast-ty-mut-ref "r" (AstTyBytes)))
        "(&mut r bytes)")]
    [mut-ref-render-ok : bool
      (string-eq
        (tc-type-render (ast-ty-mut-ref "phase" (ast-ty-dyn-array (AstTyI64))))
        "(&mut phase (Array i64))")]
    [nominal-lifetime-render-ok : bool
      (string-eq
        (tc-type-render
          (AstTyStructArgs
            (intern "RefBox")
            (ast-lifetime-cons "n" AstLifetimeNil)))
        "(RefBox n)")]
    [str-eq-ok : bool (tc-type-eq (AstTyStr) (AstTyStr))]
    [str-distinct-ok : bool (not (tc-type-eq (AstTyStr) (AstTyString)))]
    [bytes-eq-ok : bool (tc-type-eq (AstTyBytes) (AstTyBytes))]
    [bytes-distinct-ok : bool (not (tc-type-eq (AstTyBytes) (AstTyStr)))]
    [nominal-lifetime-distinct-ok : bool
      (not
        (tc-type-eq
          (AstTyStructArgs
            (intern "RefBox")
            (ast-lifetime-cons "n" AstLifetimeNil))
          (AstTyStructArgs
            (intern "RefBox")
            (ast-lifetime-cons "m" AstLifetimeNil))))]
    [str-move-kind-ok : bool (tc-type-move-only? (AstTyStr))]
    [bytes-move-kind-ok : bool (tc-type-move-only? (AstTyBytes))]
    [str-ref-move-kind-ok : bool
      (tc-type-copyable? (ast-ty-ref "r" (AstTyStr)))]
    [bytes-ref-move-kind-ok : bool
      (tc-type-copyable? (ast-ty-ref "r" (AstTyBytes)))]
    [region-erased-eq-ok : bool
      (tc-type-eq
        (ast-ty-ref "r" (ast-ty-region "inner" (AstTyI64)))
        (ast-ty-ref "r" (AstTyI64)))]
    [region-distinct-ok : bool
      (not (tc-type-eq (ast-ty-ref "r" (AstTyI64)) (ast-ty-ref "s" (AstTyI64))))]
    [mut-distinct-ok : bool
      (not
        (tc-type-eq (ast-ty-ref "r" (AstTyI64)) (ast-ty-mut-ref "r" (AstTyI64))))]
    [region-contains-ok : bool
      (tc-type-contains-region (ast-ty-ref "r" (AstTyI64)) "r")]
    [inner-region-contains-ok : bool
      (tc-type-contains-region
        (ast-ty-mut-ref "phase" (ast-ty-region "inner" (AstTyString)))
        "inner")]
    (and
      string-ref-render-ok
      str-ref-render-ok
      bytes-ref-render-ok
      bytes-mut-ref-render-ok
      mut-ref-render-ok
      str-eq-ok
      str-distinct-ok
      bytes-eq-ok
      bytes-distinct-ok
      nominal-lifetime-render-ok
      nominal-lifetime-distinct-ok
      str-move-kind-ok
      bytes-move-kind-ok
      str-ref-move-kind-ok
      bytes-ref-move-kind-ok
      region-erased-eq-ok
      region-distinct-ok
      mut-distinct-ok
      region-contains-ok
      inner-region-contains-ok)))

(define (compiler-typecheck-reference-tests-ok?) : bool
  (let
    [render-ok : bool (compiler-typecheck-reference-render-ok?)]
    [local-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-local-source))]
    [param-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-param-source))]
    [projection-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-projection-source))]
    [str-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-str-source))]
    [str-auto-borrow-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-str-auto-borrow-source))]
    [str-region-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-str-region-source))]
    [temp-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-temp-source)
        "typecheck: borrow requires a local, parameter, or aggregate place")]
    [mismatch-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-mismatch-source)
        "typecheck: borrow lifetime mismatch")]
    [return-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-return-source))]
    [return-param-ref-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-return-param-ref-source))]
    [return-untied-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-return-untied-source)
        "typecheck: returned reference lifetime must be tied to a parameter")]
    [return-local-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-return-local-escape-source)
        "typecheck: reference value would escape lexical scope")]
    [struct-field-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-struct-field-source))]
    [enum-payload-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-enum-payload-source))]
    [lifetime-struct-return-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-lifetime-struct-return-source))]
    [lifetime-struct-field-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-lifetime-struct-field-source))]
    [lifetime-enum-match-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-lifetime-enum-match-source))]
    [borrowed-enum-match-scalar-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-borrowed-enum-match-scalar-source))]
    [borrowed-enum-match-str-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-borrowed-enum-match-str-source))]
    [borrowed-enum-match-array-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-borrowed-enum-match-array-source))]
    [borrowed-enum-match-ref-struct-array-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-borrowed-enum-match-ref-struct-array-source))]
    [borrowed-enum-match-nested-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-borrowed-enum-match-nested-source))]
    [borrowed-enum-match-temp-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-borrowed-enum-match-temp-source)
        "typecheck: borrow requires a local, parameter, or aggregate place")]
    [borrowed-enum-match-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-borrowed-enum-match-escape-source)
        "typecheck: returned reference lifetime must be tied to a parameter")]
    [returned-borrowed-lookup-assign-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-returned-borrowed-lookup-assign-source)
        "typecheck: cannot assign to borrowed place `bag`")]
    [returned-borrowed-lookup-array-set-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-returned-borrowed-lookup-array-set-source)
        "typecheck: cannot assign to borrowed place `bag.slots.#array.0`")]
    [regular-call-lifetime-subst-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-regular-call-lifetime-subst-source))]
    [regular-call-lifetime-conflict-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-regular-call-lifetime-conflict-source)
        "typecheck: constructor lifetime mismatch")]
    [lifetime-duplicate-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-lifetime-duplicate-source)
        "typecheck: duplicate lifetime parameter")]
    [lifetime-missing-args-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-lifetime-missing-args-source)
        "typecheck: missing nominal lifetime arguments")]
    [lifetime-arity-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-lifetime-arity-source)
        "typecheck: nominal lifetime argument arity mismatch")]
    [lifetime-unknown-decl-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-lifetime-unknown-decl-source)
        "typecheck: unknown aggregate lifetime parameter")]
    [lifetime-untied-return-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-lifetime-untied-return-source)
        "typecheck: returned reference lifetime must be tied to a parameter")]
    [lifetime-local-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-lifetime-local-escape-source)
        "typecheck: reference value would escape lexical scope")]
    [array-stored-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-array-stored-source))]
    [struct-return-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-struct-return-source)
        "typecheck: cannot store region-tagged value into return value; region value would escape")]
    [struct-local-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-struct-local-escape-source)
        "typecheck: reference value would escape lexical scope")]
    [lambda-return-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-lambda-return-source)
        "typecheck: returning references requires lifetime support (#804)")]
    [mut-ref-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-mut-source))]
    [mut-borrow-ok : bool
      (compiler-typecheck-ok? (compiler-typecheck-reference-mut-borrow-source))]
    [mut-array-set-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-mut-array-set-source))]
    [mut-array-push-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-mut-array-push-source))]
    [immut-array-set-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-reference-immut-array-set-source)
        "typecheck: array-set! requires mutable array access")]
    [str-value-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-value-source)
        (tc-source-str-value-policy-message))]
    [str-return-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-return-source)
        (tc-source-str-value-policy-message))]
    [str-local-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-local-source)
        (tc-source-str-value-policy-message))]
    [str-global-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-global-source)
        (tc-source-str-value-policy-message))]
    [str-field-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-field-source)
        (tc-source-str-value-policy-message))]
    [str-variant-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-variant-source)
        (tc-source-str-value-policy-message))]
    [str-mut-ref-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-str-mut-ref-source)
        (tc-source-str-mut-ref-policy-message))]
    [ok : bool true]
    (begin
      (if render-ok
        unit
        (set! ok false))
      (if local-ok
        unit
        (set! ok false))
      (if param-ok
        unit
        (set! ok false))
      (if projection-ok
        unit
        (set! ok false))
      (if str-ok
        unit
        (set! ok false))
      (if str-auto-borrow-ok
        unit
        (set! ok false))
      (if str-region-ok
        unit
        (set! ok false))
      (if temp-error-ok
        unit
        (set! ok false))
      (if mismatch-error-ok
        unit
        (set! ok false))
      (if return-ok
        unit
        (set! ok false))
      (if return-param-ref-ok
        unit
        (set! ok false))
      (if return-untied-error-ok
        unit
        (set! ok false))
      (if return-local-escape-error-ok
        unit
        (set! ok false))
      (if struct-field-ok
        unit
        (set! ok false))
      (if enum-payload-ok
        unit
        (set! ok false))
      (if lifetime-struct-return-ok
        unit
        (set! ok false))
      (if lifetime-struct-field-ok
        unit
        (set! ok false))
      (if lifetime-enum-match-ok
        unit
        (set! ok false))
      (if borrowed-enum-match-scalar-ok
        unit
        (set! ok false))
      (if borrowed-enum-match-str-ok
        unit
        (set! ok false))
      (if borrowed-enum-match-array-ok
        unit
        (set! ok false))
      (if borrowed-enum-match-ref-struct-array-ok
        unit
        (set! ok false))
      (if borrowed-enum-match-nested-ok
        unit
        (set! ok false))
      (if borrowed-enum-match-temp-error-ok
        unit
        (set! ok false))
      (if borrowed-enum-match-escape-error-ok
        unit
        (set! ok false))
      (if returned-borrowed-lookup-assign-error-ok
        unit
        (set! ok false))
      (if returned-borrowed-lookup-array-set-error-ok
        unit
        (set! ok false))
      (if regular-call-lifetime-subst-ok
        unit
        (set! ok false))
      (if regular-call-lifetime-conflict-error-ok
        unit
        (set! ok false))
      (if lifetime-duplicate-error-ok
        unit
        (set! ok false))
      (if lifetime-missing-args-error-ok
        unit
        (set! ok false))
      (if lifetime-arity-error-ok
        unit
        (set! ok false))
      (if lifetime-unknown-decl-error-ok
        unit
        (set! ok false))
      (if lifetime-untied-return-error-ok
        unit
        (set! ok false))
      (if lifetime-local-escape-error-ok
        unit
        (set! ok false))
      (if array-stored-ok
        unit
        (set! ok false))
      (if struct-return-error-ok
        unit
        (set! ok false))
      (if struct-local-escape-error-ok
        unit
        (set! ok false))
      (if lambda-return-error-ok
        unit
        (set! ok false))
      (if mut-ref-ok
        unit
        (set! ok false))
      (if mut-borrow-ok
        unit
        (set! ok false))
      (if mut-array-set-ok
        unit
        (set! ok false))
      (if mut-array-push-ok
        unit
        (set! ok false))
      (if immut-array-set-error-ok
        unit
        (set! ok false))
      (if str-value-error-ok
        unit
        (set! ok false))
      (if str-return-error-ok
        unit
        (set! ok false))
      (if str-local-error-ok
        unit
        (set! ok false))
      (if str-global-error-ok
        unit
        (set! ok false))
      (if str-field-error-ok
        unit
        (set! ok false))
      (if str-variant-error-ok
        unit
        (set! ok false))
      (if str-mut-ref-error-ok
        unit
        (set! ok false))
      ok)))

;; A type error whose offending expression (`missing`) is on source line 2, so
;; the diagnostic must locate it there (not at the 1:1 fallback), proving the
;; typechecker carries the nearest declaration-body `AstExprSpanned` span (#681).
(define (compiler-typecheck-located-fn-source) : String
  "(define (main) : i64
  missing)")

(define (compiler-typecheck-located-value-source) : String
  "(define bad : i64
  missing)")

(define (compiler-typecheck-call-arity-located-source) : String
  "(define (need3 [a : i64] [b : i64] [c : i64]) : i64 a)
(define (main) : i64
  (let
    [x : i64 1]
    [y : i64 2]
    [z : i64 3]
    (begin
      (+ x y)
      (need3 x y))))")

(define (compiler-typecheck-located-source-ok? [src : String]) : bool
  (match (typecheck-compiler-source src)
    [(ErrCompilerTypecheck diag)
      (if (= (compiler-diagnostic-line diag) 2)
        (if (> (compiler-diagnostic-col diag) 0)
          (string-eq
            (compiler-diagnostic-message diag)
            "typecheck: unbound name missing")
          false)
        false)]
    [(OkCompilerTypecheck _) false]))

(define (compiler-typecheck-located-ok?) : bool
  (and
    (compiler-typecheck-located-source-ok?
      (compiler-typecheck-located-fn-source))
    (compiler-typecheck-located-source-ok?
      (compiler-typecheck-located-value-source))
    (match (typecheck-compiler-source
      (compiler-typecheck-call-arity-located-source))
      [(ErrCompilerTypecheck diag)
        (and
          (string-eq
            (compiler-diagnostic-message diag)
            "typecheck: call arity mismatch: need3 expected 3 arguments, got 2 arguments")
          (= (compiler-diagnostic-line diag) 9)
          (= (compiler-diagnostic-col diag) 7))]
      [(OkCompilerTypecheck _) false])))

;; Statement and control-flow type rules (#1042): if/while conditions, the
;; while-body unit rule, set!/let annotation mismatches, and `ann` mismatch,
;; plus an accepting program exercising the same forms. Migrated from
;; src/typechecker.rs unit coverage.
(define (compiler-typecheck-stmt-if-cond-source) : String
  "(define (main) : i64 (if 1 2 3))")

(define (compiler-typecheck-stmt-while-cond-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while i (set! i (- i 1)))))")

(define (compiler-typecheck-stmt-while-body-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while (> i 0) i)))")

(define (compiler-typecheck-stmt-set-mismatch-source) : String
  "(define (main) : i64
  (let [x : i64 0] (begin (set! x true) x)))")

(define (compiler-typecheck-stmt-let-mismatch-source) : String
  "(define (main) : i64 (let [x : i64 true] x))")

(define (compiler-typecheck-stmt-ann-mismatch-source) : String
  "(define (main) : i64 (ann true : i64))")

(define (compiler-typecheck-stmt-ok-while-source) : String
  "(define (main [n : i64]) : unit
  (let [i : i64 n] (while (> i 0) (set! i (- i 1)))))")

(define (compiler-typecheck-stmt-ok-if-set-source) : String
  "(define (main [flag : bool]) : i64
  (let [x : i64 0] (begin (set! x 5) (if flag x 0))))")

(define (compiler-typecheck-stmt-ok-cast-ann-source) : String
  "(define (main [c : char]) : i64 (ann (cast c : i64) : i64))")

(define (compiler-typecheck-statement-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-if-cond-source)
      "typecheck: if condition must be bool")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-while-cond-source)
      "typecheck: while condition must be bool")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-while-body-source)
      "typecheck: while body must be unit")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-set-mismatch-source)
      "typecheck: assignment type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-let-mismatch-source)
      "typecheck: let binding type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-ann-mismatch-source)
      "typecheck: annotation type mismatch")
    (compiler-typecheck-ok? (compiler-typecheck-stmt-ok-while-source))
    (compiler-typecheck-ok? (compiler-typecheck-stmt-ok-if-set-source))
    (compiler-typecheck-ok? (compiler-typecheck-stmt-ok-cast-ann-source))))

;; Operator and call type rules (#1042): equality/comparison/integer operato
;; operand matching and call arity, plus accepting arithmetic/comparison/call
;; programs. Migrated from src/typechecker.rs unit coverage.
(define (compiler-typecheck-op-eq-mismatch-source) : String
  "(define (main) : bool (= 1 true))")

(define (compiler-typecheck-op-int-mismatch-source) : String
  "(define (main) : i64 (+ 1 true))")

(define (compiler-typecheck-op-cmp-mismatch-source) : String
  "(define (main) : bool (< 1 true))")

(define (compiler-typecheck-op-arity-many-source) : String
  "(define (f [x : i64]) : i64 x)
(define (main) : i64 (f 1 2))")

(define (compiler-typecheck-op-arity-few-source) : String
  "(define (f [x : i64] [y : i64]) : i64 (+ x y))
(define (main) : i64 (f 1))")

(define (compiler-typecheck-op-ok-arith-source) : String
  "(define (main) : i64 (+ (* 2 3) (- 10 4)))")

(define (compiler-typecheck-op-ok-cmp-eq-source) : String
  "(define (main) : bool (if (< 1 2) (= 3 3) false))")

(define (compiler-typecheck-op-ok-shift-count-source) : String
  "(define (main) : u64 (shr (cast -1 : u64) 63))")

(define (compiler-typecheck-op-shift-count-bad-source) : String
  "(define (main) : i64 (shl 1 true))")

(define (compiler-typecheck-op-shift-left-bad-source) : String
  "(define (main) : i64 (shl true 1))")

(define (compiler-typecheck-op-bitwise-mismatch-source) : String
  "(define (main [n : i64]) : u64 (bit-and (cast -1 : u64) n))")

(define (compiler-typecheck-op-ok-call-source) : String
  "(define (add [a : i64] [b : i64]) : i64 (+ a b))
(define (main) : i64 (add 2 3))")

(define (compiler-typecheck-operator-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-eq-mismatch-source)
      "typecheck: equality operands must match")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-int-mismatch-source)
      "typecheck: integer operator expects matching integer operands")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-cmp-mismatch-source)
      "typecheck: comparison expects matching ordered scalar operands")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-arity-many-source)
      "typecheck: call arity mismatch: f expected 1 argument, got 2 arguments")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-arity-few-source)
      "typecheck: call arity mismatch: f expected 2 arguments, got 1 argument")
    (compiler-typecheck-ok? (compiler-typecheck-op-ok-arith-source))
    (compiler-typecheck-ok? (compiler-typecheck-op-ok-cmp-eq-source))
    (compiler-typecheck-ok? (compiler-typecheck-op-ok-shift-count-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-shift-count-bad-source)
      "typecheck: shift count must be integer")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-shift-left-bad-source)
      "typecheck: shift left operand must be integer")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-bitwise-mismatch-source)
      "typecheck: integer operator expects matching integer operands")
    (compiler-typecheck-ok? (compiler-typecheck-op-ok-call-source))))

;; Scalar/bool/float/cast parity (#1541): remaining Rust typechecker unit
;; coverage for bool not/equality, cond condition typing, narrow intege
;; literal match rules, contextual f32 literals, f32 arithmetic/comparison, and
;; f64<->f32-only float casts.
(define (compiler-typecheck-scalar-bool-ok-source) : String
  "(define (both [a : bool] [b : bool]) : bool
  (if (not a)
    (if a true b)
    false))
(define (eq [a : bool] [b : bool]) : bool (= a b))
(define (main [a : bool] [b : bool]) : bool
  (if (both a b) true (eq a b)))")

(define (compiler-typecheck-scalar-not-bad-source) : String
  "(define (main) : bool (not 5))")

(define (compiler-typecheck-scalar-bool-eq-bad-source) : String
  "(define (main [a : bool]) : bool (= a 1))")

(define (compiler-typecheck-scalar-cond-ok-source) : String
  "(defmacro (cond [arm : ExprClause] [fallback : ExprClause]) : Expr
  `(if ,(expr-clause-first arm)
    ,(expr-clause-second arm)
    ,(expr-clause-second fallback)))
(define (main [x : i64]) : i64 (cond [(= x 0) 1] [else 2]))")

(define (compiler-typecheck-scalar-cond-bad-source) : String
  "(defmacro (cond [arm : ExprClause] [fallback : ExprClause]) : Expr
  `(if ,(expr-clause-first arm)
    ,(expr-clause-second arm)
    ,(expr-clause-second fallback)))
(define (main) : i64 (cond [1 2] [else 3]))")

(define (compiler-typecheck-scalar-narrow-match-source) : String
  "(define (narrow-u8 [n : u8]) : i64 (match n [0 1] [_ 0]))
(define (narrow-i16 [n : i16]) : i64 (match n [0 1] [_ 0]))
(define (main [n : u8]) : i64 (narrow-u8 n))")

(define (compiler-typecheck-scalar-narrow-match-bad-source) : String
  "(define (main [n : u8]) : i64 (match n [true 1] [_ 0]))")

(define (compiler-typecheck-scalar-integer-context-source) : String
  "(defstruct Color (r u8) (g u8) (b u8) (a u8))
(defenum Tone (Tone u8) (Silent))
(extern (ffi-take-i32 [x : i32]) : i32)
(define global-u8 : u8 255)
(define (take-i16 [x : i16]) : i16 x)
(define (take-u32 [x : u32]) : u32 x)
(define (make-color) : Color (Color 135 206 235 255))
(define (make-tone) : Tone (Tone 64))
(define (array-first) : u8
  (let
    [items : (Array u8 4) (array 1 2 3 4)]
    (array-ref items 0)))
(define (tuple-first) : u16
  (tuple-ref (ann (tuple 65535 -8) : (Tuple u16 i8)) 0))
(define (assign-local) : u8
  (let
    [n : u8 0]
    (begin (set! n 42) n)))
(define (assign-field) : u8
  (let
    [c : Color (Color 0 0 0 0)]
    (begin
      (set! (struct-get c r) 135)
      (struct-get c r))))
(define (return-u32) : u32 4294967295)
(define (return-u64) : u64 9223372036854775807)
(define (return-u64-full-dec) : u64 18446744073709551615)
(define (return-u64-full-hex) : u64 0xffffffffffffffff)
(define (return-u64-full-bin) : u64 0b1111111111111111111111111111111111111111111111111111111111111111)
(define (return-u64-high-bit) : u64 9223372036854775808)
(define (call-i16) : i16 (take-i16 -32768))
(define (call-u32) : u32 (take-u32 2147483648))
(define (ffi-call) : i32 (ffi-take-i32 2147483647))
(define (bin-left [x : u8]) : u8 (+ 1 x))
(define (bin-right [x : u16]) : u16 (+ x 1))
(define (two-literals) : i32 (+ 1 2))
(define (contextual-binary-literals) : i64 (- 0 1))
(define (contextual-unary-literal) : i64 (neg 1))
(define (contextual-let-binary-literals) : i64
  (let
    [x : i64 (- 0 1)]
    x))
(define (main) : i64 0)")

(define (compiler-typecheck-scalar-unconstrained-int-default-source) : String
  "(define (main) : i32
  (let
    [x (+ 1 2)]
    x))")

(define (compiler-typecheck-scalar-int-i8-overflow-source) : String
  "(define (main) : i8 128)")

(define (compiler-typecheck-scalar-int-u8-overflow-source) : String
  "(define (main) : u8 256)")

(define (compiler-typecheck-scalar-int-unsigned-negative-source) : String
  "(define (main) : u8 -1)")

(define (compiler-typecheck-scalar-int-u64-overflow-source) : String
  "(define (main) : u64 18446744073709551616)")

(define (compiler-typecheck-scalar-int-u64-based-overflow-source) : String
  "(define (main) : u64 0x10000000000000000)")

(define (compiler-typecheck-scalar-int-u64-negative-source) : String
  "(define (main) : u64 -1)")

(define (compiler-typecheck-scalar-int-binop-overflow-source) : String
  "(define (main [x : i8]) : i8 (+ 128 x))")

(define (compiler-typecheck-scalar-f32-context-source) : String
  "(define gx : f32 1.0)
(define (id [x : f32]) : f32 x)
(define (ret) : f32 1.0)
(define (annotated) : f32 (ann 1.0 : f32))
(define (call) : f32 (id 2.0))
(define (array-first) : f32
  (let
    [a : (Array f32 2) (array 1.0 2.0)]
    (array-ref a 0)))")

(define (compiler-typecheck-scalar-f32-to-f64-source) : String
  "(define (ret [x : f32]) : f64 x)
(define (arg [x : f64]) : f64 x)
(define (call [x : f32]) : f64 (arg x))
(define (branch [x : f32] [flag : bool]) : f64 (if flag x 2.0))")

(define (compiler-typecheck-scalar-f64-to-f32-bad-source) : String
  "(define (main [x : f64]) : f32 x)")

(define (compiler-typecheck-scalar-f32-arithmetic-source) : String
  "(define (compute [a : f32] [b : f32]) : bool
  (let
    [sum : f32 (+ a 1.0)]
    [literal-first-sum : f32 (+ 1.0 a)]
    [diff : f32 (- a b)]
    [prod : f32 (* a b)]
    [quot : f32 (/ a b)]
    (if (< 1.0 b)
      (< (+ literal-first-sum (+ sum (+ diff (+ prod quot)))) b)
      false)))")

(define (compiler-typecheck-scalar-f64-to-f32-cast-source) : String
  "(define (main) : f32 (cast 3.5 : f32))")

(define (compiler-typecheck-scalar-f32-to-f64-cast-source) : String
  "(define (main [x : f32]) : f64 (cast x : f64))")

(define (compiler-typecheck-scalar-float-cast-bad-source) : String
  "(define (main) : i64 (cast 3.5 : i64))")

(define (compiler-typecheck-scalar-bool-cast-bad-source) : String
  "(define (main) : i64 (cast true : i64))")

;; Contextual scalar literals also flow through tuple element types (#1626):
;; the float literals resolve to f32 against the declared tuple element types.
(define (compiler-typecheck-scalar-tuple-context-source) : String
  "(define (pair) : (Tuple f32 bool) (tuple 1.0 true))
(define (first) : f32
  (tuple-ref (ann (tuple 1.0 true) : (Tuple f32 bool)) 0))")

;; ... and through a begin's final expression (#1626): the tail float literal
;; resolves to f32 against the function return type.
(define (compiler-typecheck-scalar-begin-context-source) : String
  "(define (f) : f32 (begin 1 1.0))")

(define (compiler-typecheck-scalar-parity-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok? (compiler-typecheck-scalar-bool-ok-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-not-bad-source)
            "typecheck: not expects bool")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-bool-eq-bad-source)
            "typecheck: equality operands must match")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok? (compiler-typecheck-scalar-cond-ok-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-cond-bad-source)
            "typecheck: if condition must be bool")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-narrow-match-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-narrow-match-bad-source)
            "typecheck: literal pattern type mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-integer-context-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-unconstrained-int-default-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-int-i8-overflow-source)
            "typecheck: integer literal 128 does not fit expected type i8")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-int-u8-overflow-source)
            "typecheck: integer literal 256 does not fit expected type u8")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-int-unsigned-negative-source)
            "typecheck: integer literal -1 does not fit expected type u8")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-int-u64-overflow-source)
            "typecheck: integer literal 18446744073709551616 does not fit expected type u64")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-int-u64-based-overflow-source)
            "typecheck: integer literal 0x10000000000000000 does not fit expected type u64")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-int-u64-negative-source)
            "typecheck: integer literal -1 does not fit expected type u64")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-int-binop-overflow-source)
            "typecheck: integer literal 128 does not fit expected type i8")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-f32-context-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok? (compiler-typecheck-scalar-f32-to-f64-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-f64-to-f32-bad-source)
            "typecheck: return type mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-f32-arithmetic-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-f64-to-f32-cast-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-f32-to-f64-cast-source))))
      ;; Float -> int casts now truncate toward zero under the full numeric cast
      ;; matrix (#1576), so `(cast 3.5 : i64)` is accepted rather than rejected.
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-float-cast-bad-source))))
      ;; A non-numeric (bool) cast source is still rejected, with the cast-matrix
      ;; diagnostic.
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-scalar-bool-cast-bad-source)
            "typecheck: cast requires scalar numeric (integer/char/float) source and target")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-tuple-context-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-scalar-begin-context-source))))
      ok)))

;; Match / pattern type rules (#1042/#1538): Rust inline coverage migrated to
;; selfhost-owned parser+typechecker fixtures.
(define (compiler-typecheck-match-arm-mismatch-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(B) true]))")

(define (compiler-typecheck-match-unknown-variant-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(C) 2]))")

(define (compiler-typecheck-match-bare-nullary-source) : String
  "(defenum Color (Red) (Green))
(define (main [c : Color]) : i64 (match c [Red 1] [Green 2]))")

(define (compiler-typecheck-match-bare-unknown-source) : String
  "(defenum Color (Red) (Green))
(define (main [c : Color]) : i64 (match c [other 1] [_ 0]))")

(define (compiler-typecheck-match-ok-wildcard-enum-source) : String
  "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [_ 0]))")

(define (compiler-typecheck-match-ok-nullary-call-source) : String
  "(defenum Shape (Circle i64) (Square i64) (Nothing))
(define (main) : i64
  (match (Nothing) [(Circle r) r] [(Square w) w] [(Nothing) 0]))")

(define (compiler-typecheck-match-bad-nullary-call-arity-source) : String
  "(defenum Shape (Circle i64) (Square i64) (Nothing))
(define (main) : i64
  (match (Nothing 1) [(Circle r) r] [(Square w) w] [(Nothing) 0]))")

(define (compiler-typecheck-match-bad-nullary-call-shadow-source) : String
  "(defenum Shape (Nothing))
(defenum Other (OtherV))
(define (main [Nothing : Other]) : Other (Nothing))")

(define (compiler-typecheck-match-ok-payload-source) : String
  "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [(B) 0]))")

(define (compiler-typecheck-match-ok-string-payload-source) : String
  "(defenum Token (TIdent String) (TEnd))
(define (main [t : Token]) : i64
  (match t [(TIdent s) (string-length s)] [(TEnd) 0]))")

(define (compiler-typecheck-match-bad-string-payload-source) : String
  "(defenum Token (TIdent String) (TEnd))
(define (main [t : Token]) : i64
  (match t [(TIdent s) s] [(TEnd) 0]))")

(define (compiler-typecheck-match-ok-struct-payload-source) : String
  "(defstruct Pos (line i64) (col i64))
(defenum Tok (TPos Pos) (TEnd))
(define (main [t : Tok]) : i64
  (match t [(TPos p) (struct-get p line)] [(TEnd) -1]))")

(define (compiler-typecheck-match-ok-nested-source) : String
  "(defenum SexprAtom (SInt i64) (SSym String) (SNil))
(defenum Sexpr (SAtom SexprAtom) (SCons SexprAtom SexprAtom))
(define (main [s : Sexpr]) : i64
  (match s [(SCons (SSym op) rest) (string-length op)] [_ 0]))")

(define (compiler-typecheck-match-ok-nested-rest-source) : String
  "(defenum Sexpr (SInt i64) (SSym String) (SNil) (SCons (Box Sexpr) (Box Sexpr)))
(define (depth [s : Sexpr]) : i64
  (match s
    [(SCons head rest)
      (match (box-get head)
        [(SSym op) (+ 1 (depth (box-get rest)))]
        [_ 0])]
    [_ 0]))")

(define (compiler-typecheck-match-bad-nested-field-use-source) : String
  "(defenum SexprAtom (SInt i64) (SSym String) (SNil))
(defenum Sexpr (SAtom SexprAtom) (SCons SexprAtom SexprAtom))
(define (main [s : Sexpr]) : i64
  (match s [(SCons (SInt n) rest) (string-length n)] [_ 0]))")

(define (compiler-typecheck-match-bad-nested-non-enum-source) : String
  "(defenum Sexpr (SInt i64) (SNil))
(define (main [s : Sexpr]) : i64 (match s [(SInt (SNil)) 1] [_ 0]))")

(define (compiler-typecheck-match-ok-nested-literal-source) : String
  "(defenum SexprAtom (SInt i64) (SNil))
(defenum Sexpr (SAtom SexprAtom) (SCons SexprAtom SexprAtom))
(define (main [s : Sexpr]) : i64
  (match s [(SCons (SInt 0) rest) 1] [_ 0]))")

(define (compiler-typecheck-match-bad-nested-literal-source) : String
  "(defenum SexprAtom (SInt i64) (SNil))
(defenum Sexpr (SAtom SexprAtom) (SCons SexprAtom SexprAtom))
(define (main [s : Sexpr]) : i64
  (match s [(SCons (SInt true) rest) 1] [_ 0]))")

(define (compiler-typecheck-match-bad-flat-exhaustiveness-source) : String
  "(defenum Sexpr (SInt i64) (SSym String) (SNil) (SCons i64 i64))
(define (main [s : Sexpr]) : i64
  (match s [(SInt n) n] [(SSym x) 0] [(SNil) 0]))")

(define (compiler-typecheck-match-bad-refutable-nested-source) : String
  "(defenum Inner (Left i64) (Right i64))
(defenum Outer (Outer Inner))
(define (main [o : Outer]) : i64 (match o [(Outer (Left n)) n]))")

(define (compiler-typecheck-match-ok-nested-fallback-source) : String
  "(defenum Inner (Left i64) (Right i64))
(defenum Outer (Outer Inner))
(define (main [o : Outer]) : i64
  (match o [(Outer (Left n)) n] [(Outer _) 0]))")

(define (compiler-typecheck-match-ok-bool-source) : String
  "(define (main [b : bool]) : i64 (match b [true 1] [false 0]))")

(define (compiler-typecheck-match-ok-wildcard-source) : String
  "(define (main) : i64 (match 1 [_ 0]))")

(define (compiler-typecheck-match-ok-int-literals-source) : String
  "(define (main [n : i64]) : i64 (match n [0 100] [1 200] [_ 0]))")

(define (compiler-typecheck-match-ok-string-literals-source) : String
  "(define (main [s : String]) : i64
  (match s [\"if\" 10] [\"let\" 20] [_ 0]))")

(define (compiler-typecheck-match-bad-string-exhaustive-source) : String
  "(define (main [s : String]) : i64 (match s [\"if\" 10]))")

(define (compiler-typecheck-match-bad-bool-exhaustive-source) : String
  "(define (main [b : bool]) : i64 (match b [true 1]))")

(define (compiler-typecheck-match-ok-bool-wildcard-source) : String
  "(define (main [b : bool]) : i64 (match b [true 1] [_ 0]))")

(define (compiler-typecheck-match-bad-scalar-exhaustive-source) : String
  "(define (main [n : i64]) : i64 (match n [0 1] [1 2]))")

(define (compiler-typecheck-match-bad-literal-type-source) : String
  "(define (main [n : i64]) : i64 (match n [true 1] [_ 0]))")

(define (compiler-typecheck-match-bad-scalar-arm-source) : String
  "(define (main [n : i64]) : i64 (match n [0 1] [_ true]))")

(define (compiler-typecheck-match-bad-lifetime-result-source) : String
  "(defenum Choice (Left) (Right))
(defenum SlotLookup (:lifetimes bag) (SlotMissing) (SlotFound (& bag i64)))
(define (slot-found [value : (& bag i64)]) : (SlotLookup bag) (SlotFound value))
(define (slot-found-other [value : (& other i64)]) : (SlotLookup other) (SlotFound value))
(define (main [bag : i64] [other : i64] [choice : Choice]) : i64
  (let
    [probe
      (match choice
        [(Left) (slot-found (& bag))]
        [(Right) (slot-found-other (& other))])]
    0))")

(define (compiler-typecheck-match-bad-unreachable-source) : String
  "(define (main [n : i64]) : i64 (match n [_ 0] [1 2]))")

(define (compiler-typecheck-match-ok-narrow-int-source) : String
  "(define (main [n : u8]) : i64 (match n [0 1] [_ 0]))")

(define (compiler-typecheck-match-bad-binding-arity-source) : String
  "(defenum Shape (Circle i64) (Square i64))
(define (main [s : Shape]) : i64 (match s [(Circle a b) 0] [_ 1]))")

(define (compiler-typecheck-match-bad-maybe-exhaustive-source) : String
  "(defenum MaybeI64 (NoneI64) (SomeI64 i64))
(define (main [m : MaybeI64]) : i64 (match m [(SomeI64 v) v]))")

(define (compiler-typecheck-match-bad-result-exhaustive-source) : String
  "(defenum ResultI64 (OkI64 i64) (ErrI64 String))
(define (main [r : ResultI64]) : i64 (match r [(OkI64 v) v]))")

(define (compiler-typecheck-match-ok-recursive-list-source) : String
  "(defenum List (Cons i64 (Box List)) (Nil))
(define (main [l : List]) : i64 (match l [(Cons n rest) n] [(Nil) 0]))")

(define (compiler-typecheck-match-ok-recursive-expr-source) : String
  "(defenum Expr (ENum i64) (EAdd (Box Expr) (Box Expr)))
(define (eval [e : Expr]) : i64
  (match e [(ENum n) n] [(EAdd l r) (+ (eval (box-get l)) (eval (box-get r)))]))
(define (main [e : Expr]) : i64 (eval e))")

(define (compiler-typecheck-match-bad-recursive-tuple-source) : String
  "(defenum Bad (V (Tuple Bad i64)) (Nil))
(define (main [b : Bad]) : i64 0)")

(define (compiler-typecheck-match-bad-recursive-array-source) : String
  "(defenum Bad (V (Array Bad 2)) (Nil))
(define (main [b : Bad]) : i64 0)")

;; A diverging arm (panic : never) must unify with a value arm rather than
;; being reported as a disagreement; mirrors never-in-if branch handling.
(define (compiler-typecheck-match-ok-never-arm-source) : String
  (compiler-typecheck-with-io-source
    "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(B) (panic \"no\")]))"))

(define (compiler-typecheck-match-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-arm-mismatch-source)
            "typecheck: match arm result type mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-unknown-variant-source)
            "typecheck: unknown variant C")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-bare-nullary-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bare-unknown-source)
            "typecheck: unknown variant other")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-wildcard-enum-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-nullary-call-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-nullary-call-arity-source)
            "typecheck: arity mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-nullary-call-shadow-source)
            "typecheck: call target is not a function")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok? (compiler-typecheck-match-ok-payload-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-string-payload-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-string-payload-source)
            "typecheck: match arm result type mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-struct-payload-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok? (compiler-typecheck-match-ok-nested-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-nested-rest-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-nested-field-use-source)
            "typecheck: argument type mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-nested-non-enum-source)
            "typecheck: nested variant pattern requires enum field")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-nested-literal-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-nested-literal-source)
            "typecheck: literal pattern type mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-flat-exhaustiveness-source)
            "typecheck: match missing arm for variant SCons")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-refutable-nested-source)
            "typecheck: non-exhaustive match")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-nested-fallback-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok? (compiler-typecheck-match-ok-bool-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok? (compiler-typecheck-match-ok-wildcard-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-int-literals-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-string-literals-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-string-exhaustive-source)
            "typecheck: non-exhaustive match")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-bool-exhaustive-source)
            "typecheck: match missing arm for false")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-bool-wildcard-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-scalar-exhaustive-source)
            "typecheck: non-exhaustive match")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-literal-type-source)
            "typecheck: literal pattern type mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-scalar-arm-source)
            "typecheck: match arm result type mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-lifetime-result-source)
            "typecheck: match arms must agree: previous arm type (SlotLookup bag), current arm type (SlotLookup other)")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-unreachable-source)
            "typecheck: unreachable match arm after wildcard `_`")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-narrow-int-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-binding-arity-source)
            "typecheck: pattern arity mismatch")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-maybe-exhaustive-source)
            "typecheck: match missing arm for variant NoneI64")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-result-exhaustive-source)
            "typecheck: match missing arm for variant ErrI64")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-recursive-list-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-recursive-expr-source))))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-recursive-tuple-source)
            "typecheck: inline aggregate layout cycle Bad -> Bad; insert (Box Bad) at the recursive edge")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-error-ok?
            (compiler-typecheck-match-bad-recursive-array-source)
            "typecheck: inline aggregate layout cycle Bad -> Bad; insert (Box Bad) at the recursive edge")))
      (set!
        ok
        (and
          ok
          (compiler-typecheck-ok?
            (compiler-typecheck-match-ok-never-arm-source))))
      ok)))

(define (compiler-typecheck-string-builtin-ok-length-source) : String
  "(define (main) : i64 (string-length \"hi\"))")

(define (compiler-typecheck-string-builtin-ok-eq-source) : String
  "(define (f) : bool (string-eq \"a\" \"b\"))")

(define (compiler-typecheck-string-helper-source-defined-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (f [s : String]) : String
  (string-concat
    (string-append (substring s 0 1) (string-slice s 1 1))
    (int->string (string->int \"7\"))))"))

(define (compiler-typecheck-string-builtin-borrowed-source) : String
  "(define (main [text : String] [other : String]) : i64
  (begin
    (+ (string-length (& text))
      (+ (length (& text))
        (+ (cast (string-ref (& text) 0) : i64)
          (+ (if (string-eq (& text) (& other)) 1 0)
             (string->int (& text))))))))")

(define (compiler-typecheck-string-builtin-no-default-int-source) : String
  "(define (main) : String (int->string 1))")

(define (compiler-typecheck-string-builtin-no-default-append-source) : String
  "(define (main) : String (string-append \"a\" \"b\"))")

(define (compiler-typecheck-string-builtin-no-default-substring-source) : String
  "(define (main) : String (substring \"abc\" 0 1))")

(define (compiler-typecheck-string-builtin-no-default-slice-source) : String
  "(define (main) : String (string-slice \"abc\" 0 1))")

(define (compiler-typecheck-string-builtin-no-default-concat-source) : String
  "(define (main) : String (string-concat \"a\" \"b\"))")

(define (compiler-typecheck-string-builtin-borrowed-alloc-source) : String
  "(define (main [left : String] [right : String]) : String
  (let
    [joined : String (string-append (& left) (& right))]
    [slice : String (substring (& joined) 0 1)]
    (string-concat (& slice) (string-slice (& right) 0 1))))")

(define (compiler-typecheck-string-builtin-bad-arg-source) : String
  "(define (main) : i64 (string-length 5))")

(define (compiler-typecheck-string-builtin-bad-array-source) : String
  "(define (main [items : (Array i64)]) : i64 (string-length items))")

(define (compiler-typecheck-string-builtin-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-string-builtin-ok-length-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-string-builtin-ok-eq-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-string-helper-source-defined-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-string-builtin-borrowed-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-string-builtin-no-default-int-source)
        "typecheck: unbound name int->string")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-string-builtin-no-default-append-source)
        "typecheck: unbound name string-append")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-string-builtin-no-default-substring-source)
        "typecheck: unbound name substring")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-string-builtin-no-default-slice-source)
        "typecheck: unbound name string-slice")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-string-builtin-no-default-concat-source)
        "typecheck: unbound name string-concat")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-string-builtin-borrowed-alloc-source)
        "typecheck: unbound name string-append")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-string-builtin-bad-arg-source)
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-string-builtin-bad-array-source)
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      ok)))

;; Stdlib argv helper signature rules (#1042, #1893): `arg-count` returns i64
;; and `arg` accepts an i64 index and returns String. User declarations may
;; still define the same source-level names when no stdlib import brings them
;; into scope.
(define (compiler-typecheck-argv-builtin-ok-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64
  (+ (arg-count) (string-length (arg 0))))"))

(define (compiler-typecheck-argv-builtin-bad-index-source) : String
  (compiler-typecheck-with-io-source "(define (main) : String (arg \"0\"))"))

(define (compiler-typecheck-argv-builtin-bad-arg-arity-source) : String
  (compiler-typecheck-with-io-source "(define (main) : String (arg 0 1))"))

(define (compiler-typecheck-argv-builtin-bad-count-arity-source) : String
  (compiler-typecheck-with-io-source "(define (main) : i64 (arg-count 0))"))

(define (compiler-typecheck-argv-builtin-shadow-source) : String
  "(define (arg-count) : i64 9)
(define (arg [n : i64]) : i64 n)
(define (main) : i64 (+ (arg-count) (arg 1)))")

(define (compiler-typecheck-argv-no-import-count-source) : String
  "(define (main) : i64 (arg-count))")

(define (compiler-typecheck-argv-no-import-arg-source) : String
  "(define (main) : String (arg 0))")

(define (compiler-typecheck-argv-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-argv-builtin-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-argv-builtin-bad-index-source)
      "typecheck: argument type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-argv-builtin-bad-arg-arity-source)
      "typecheck: call arity mismatch: arg expected 1 argument, got 2 arguments")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-argv-builtin-bad-count-arity-source)
      "typecheck: call arity mismatch: arg-count expected 0 arguments, got 1 argument")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-argv-no-import-count-source)
      "typecheck: unbound name arg-count")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-argv-no-import-arg-source)
      "typecheck: unbound name arg")
    (compiler-typecheck-ok? (compiler-typecheck-argv-builtin-shadow-source))))

(define (compiler-typecheck-lambda-ok-typed-source) : String
  "(define (main) : i64 (let [f : (-> i64 i64) (lambda ([x : i64]) : i64 x)] (f 5)))")

(define (compiler-typecheck-lambda-ok-nullary-source) : String
  "(define (main) : i64 (let [g : (-> i64) (lambda () : i64 42)] (g)))")

(define (compiler-typecheck-lambda-ok-inferred-ret-source) : String
  "(define (main) : i64 (let [h : (-> i64 i64) (lambda ([x : i64]) (+ x 1))] (h 7)))")

(define (compiler-typecheck-lambda-bad-ret-source) : String
  "(define (main) : i64 (begin (lambda ([x : i64]) : bool x) 0))")

;; Closure capture typing (#1542, migrated from src/typechecker.rs): a lambda
;; that reads outer locals/params type-checks like its declared `(-> ...)` type.
;; Covers scalar, multi-scalar, String, struct capture, and aggregate-returning
;; lambdas - the capture shapes the selfhost typechecker currently accepts.
(define (compiler-typecheck-lambda-capture-scalar-source) : String
  "(define (main) : i64 (let [n : i64 7] (let [g : (-> i64) (lambda () : i64 n)] (g))))")

(define (compiler-typecheck-lambda-capture-multi-source) : String
  "(define (main) : i64
  (let [a : i64 3] (let [b : i64 4]
    (let [g : (-> i64) (lambda () : i64 (+ a b))] (g)))))")

(define (compiler-typecheck-lambda-capture-string-source) : String
  "(define (main) : i64
  (let [s : String \"hi\"]
    (let [g : (-> i64) (lambda () : i64 (string-length s))] (g))))")

(define (compiler-typecheck-lambda-capture-struct-source) : String
  "(defstruct P (a i64))
(define (main) : i64
  (let [p : P (P 9)] (let [g : (-> P) (lambda () : P p)] (struct-get (g) a))))")

(define (compiler-typecheck-lambda-capture-dyn-array-source) : String
  "(define (main [n : i64]) : i64
  (let
    [items : (Array i64) (make-array i64 n)]
    (begin
      (array-push! items 5)
      (let [g : (-> i64) (lambda () : i64 (array-length items))] (g)))))")

(define (compiler-typecheck-lambda-capture-enum-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (let
    [g : (-> i64) (lambda () : i64 (match m [(Some v) v] [None 0]))]
    (g)))")

(define (compiler-typecheck-lambda-capture-tuple-source) : String
  "(define (main) : i64
  (let
    [t : (Tuple i64 bool) (tuple 7 true)]
    (let [g : (-> i64) (lambda () : i64 (tuple-ref t 0))] (g))))")

(define (compiler-typecheck-lambda-capture-fixed-array-source) : String
  "(define (main) : i64
  (let
    [items : (Array i64 2) (array 4 5)]
    (let [g : (-> i64) (lambda () : i64 (array-ref items 1))] (g))))")

(define (compiler-typecheck-lambda-captured-set-source) : String
  "(define (main) : i64
  (let
    [n : i64 0]
    (let
      [g : (-> unit) (lambda () : unit (set! n 1))]
      (begin (g) n))))")

(define (compiler-typecheck-lambda-captured-set-with-escape-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : i64
  (let
    [scratch : i64 (arena-make)]
    (let
      [n : i64 0]
      (let
        [g : (-> unit) (lambda () : unit (with-escape scratch (set! n 1)))]
        (begin (g) n)))))"))

(define (compiler-typecheck-lambda-param-set-source) : String
  "(define (main) : i64
  (let
    [g : (-> i64 i64)
      (lambda ([n : i64]) : i64 (begin (set! n (+ n 1)) n))]
    (g 1)))")

(define (compiler-typecheck-lambda-shadowed-local-set-source) : String
  "(define (main) : i64
  (let
    [n : i64 0]
    (let
      [g : (-> i64)
        (lambda () : i64
          (let
            [n : i64 1]
            (begin (set! n (+ n 1)) n)))]
      (g))))")

(define (compiler-typecheck-lambda-aggregate-return-source) : String
  "(defstruct P (a i64))
(define (main) : i64
  (let [mk : (-> P) (lambda () : P (P 5))] (struct-get (mk) a)))")

(define (compiler-typecheck-lambda-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-lambda-ok-typed-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-ok-nullary-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-ok-inferred-ret-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-lambda-bad-ret-source)
      "typecheck: lambda return type mismatch")
    (compiler-typecheck-ok? (compiler-typecheck-lambda-capture-scalar-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-capture-multi-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-capture-string-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-capture-struct-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-lambda-capture-dyn-array-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-capture-enum-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-capture-tuple-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-lambda-capture-fixed-array-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-lambda-captured-set-source)
      "typecheck: lambda cannot assign captured binding")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-lambda-captured-set-with-escape-source)
      "typecheck: lambda cannot assign captured binding")
    (compiler-typecheck-ok? (compiler-typecheck-lambda-param-set-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-lambda-shadowed-local-set-source))
    (compiler-typecheck-ok? (compiler-typecheck-lambda-aggregate-return-source))))

(define (compiler-typecheck-cast-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (f [x : i32]) : i64 (cast x : i64))")
    (compiler-typecheck-ok? "(define (f [x : i64]) : u8 (cast x : u8))")
    (compiler-typecheck-ok? "(define (f [x : i64]) : char (cast x : char))")
    (compiler-typecheck-ok? "(define (f [c : char]) : i64 (cast c : i64))")
    (compiler-typecheck-ok? "(define (f [x : f64]) : i64 (cast x : i64))")
    (compiler-typecheck-ok? "(define (f [x : i64]) : f64 (cast x : f64))")
    (compiler-typecheck-ok? "(define (f [x : f64]) : f32 (cast x : f32))")
    (compiler-typecheck-ok? "(define (f [x : f32]) : f64 (cast x : f64))")
    (compiler-typecheck-ok?
      "(define (inc [x : i64]) : i64 (+ x 1))
(define (f) : u64 (unsafe (cast inc : u64)))")
    (compiler-typecheck-error-ok?
      "(define (inc [x : i64]) : i64 (+ x 1))
(define (f) : u64 (cast inc : u64))"
      "typecheck: function-to-integer cast requires unsafe context")
    (compiler-typecheck-error-ok?
      "(define (f [b : bool]) : i64 (cast b : i64))"
      "typecheck: cast requires scalar numeric (integer/char/float) source and target")))

;; spmd-reduce operator/type rules (#1011, SPEC 5.15): `sum` accepts i32/i64/f64,
;; `min`/`max` accept i32/i64, `all`/`any` accept bool. (The varying-value
;; purity/effect rules are a separate slice.)
(define (compiler-typecheck-spmd-reduce-op-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (compiler-typecheck-ok?
      "(define (main [bs : (Array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref bs i)))")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce all ([i : i64 0 n]) 0 (array-ref xs i)))"
      "typecheck: spmd-reduce all requires a bool type")
    (compiler-typecheck-error-ok?
      "(define (main [bs : (Array bool)] [n : i64]) : bool (spmd-reduce sum ([i : i64 0 n]) true (array-ref bs i)))"
      "typecheck: spmd-reduce sum requires an i32, i64, or f64 type")))

;; spmd-reduce purity rules (#1011, SPEC.md 5.15): the per-lane value
;; expression accepts pure arithmetic over dynamic-array reads and the varying
;; index, but rejects writes (`array-set!`), function calls (also covers
;; `print*`/`panic`/file I/O and varying-argument user calls), varying control
;; flow (`if`/`while`/`match`), and indirect/gather array indexing.
(define (compiler-typecheck-spmd-reduce-purity-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (+ (array-ref xs i) 1)))")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-set! xs i 1)))"
      "`array-set!` is not allowed inside a spmd-reduce value expression; the value expression must be free of writes and other side effects (SPEC.md 5.15)")
    (compiler-typecheck-error-ok?
      "(define (helper [x : i64]) : i64 x) (define (main [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (helper i)))"
      "function calls are not allowed inside a spmd-reduce value expression; side-effecting builtins and user calls with varying arguments are deferred in the first slice (SPEC.md 5.15)")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (if (< (array-ref xs i) 0) 0 1)))"
      "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md 5.15)")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (Array i64)] [ys : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs (array-ref ys i))))"
      "indirect array indexing is not allowed inside a spmd-reduce value expression; gather/scatter is deferred in the first slice (SPEC.md 5.15)")))

(define (compiler-typecheck-spmd-broadcast-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-typecheck-ok?
      "(define (main [xs : (Array u64)] [out : (Array u64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-typecheck-ok?
      "(define (main [xs : (Array u32)] [out : (Array u32)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (spmd-broadcast (array-ref xs i) 0)))")
    (compiler-typecheck-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : unit (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (array-ref xs i) (array-set! out i (spmd-broadcast prefix 0))))")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (spmd-broadcast 1 0))"
      "typecheck: spmd-broadcast is only valid inside a foreach body, spmd-reduce value expression, or spmd-scan body")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (Array i64)] [n : i64]) : unit (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (spmd-broadcast (array-ref xs i) 0) unit))"
      "typecheck: spmd-broadcast is only valid inside a foreach body, spmd-reduce value expression, or spmd-scan body")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref xs i) i))) 0))"
      "typecheck: spmd-broadcast lane must be uniform")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (Array i64)] [out : (Array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref xs i) true))) 0))"
      "typecheck: spmd-broadcast lane must have type i64")
    (compiler-typecheck-error-ok?
      "(define (main [bs : (Array bool)] [out : (Array bool)] [n : i64]) : bool (begin (foreach ([i : i64 0 n]) (array-set! out i (spmd-broadcast (array-ref bs i) 0))) true))"
      "typecheck: spmd-broadcast value must have type i32, u32, i64, u64, f32, or f64; bool broadcast remains deferred")))

;; array-builtin signature rules (#1042): make-array length, array-ref array/index
;; types, array-set! value-type agreement, and array-push! dynamic-array
;; restrictions, with valid accepts.
(define (compiler-typecheck-array-builtin-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        "(define (f [a : (Array i64)]) : i64 (begin (array-set! a 0 5) (array-ref a 0)))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f) : i64 (let [a : (Array i64) (make-array i64 4)] (array-length a)))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f) : i64
  (let
    [a : (Array i64) (make-array i64 0)]
    (begin
      (array-push! a 5)
      (array-length a))))")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [a : (Array i64)]) : i64 (array-ref a true))"
        "typecheck: array index must be integer")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : i64 (make-array i64 true))"
        "typecheck: make-array length must be integer")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [a : (Array i64)]) : unit (array-set! a 0 true))"
        "typecheck: array-set! value type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [a : (Array i64)]) : unit (array-push! a true))"
        "typecheck: array-push! value type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [a : (Array i64 2)]) : unit (array-push! a 5))"
        "typecheck: array-push! requires dynamic array type")
        unit
        (set! ok false))
      ok)))

;; comptime typecheck rules (#1042): a `(comptime ...)` form is typed by its
;; inner expression and flows that type to the use site (so an `i64` body is an
;; `i64`, a `bool` comparison is a `bool`, and a `let`/`if` body keeps its type);
;; `comptime` cannot reference a runtime variable, and a comptime result that
;; disagrees with the surrounding type is rejected like any other mismatch.
;; Type-literal and comptime-parameter rules (#1540, migrated from
;; src/typechecker.rs): scalar `comptime` parameters type-check/specialize,
;; `(type ...)` literals are compile-time only, source-level `type` positions
;; stay rejected, and type-valued comptime parameters specialize through
;; reflection when called with a type literal.
(define (compiler-typecheck-unknown-type-policy-message [name : String]) : String
  (string-append
    "typecheck: unknown type "
    (string-append
      name
      "; TypeLisp has no source-level type parameters; use comptime-generated concrete declarations instead (#893/#913/#970/#902)")))

(define (compiler-typecheck-type-valued-comptime-source) : String
  "(defstruct Point (x i64))
(define (field-count [comptime T : type]) : i64
  (comptime (struct-field-count (type T))))
(define (main) : i64 (field-count (type Point)))")

(define (compiler-typecheck-type-valued-comptime-scalar-arg-source) : String
  "(defstruct Point (x i64))
(define (field-count [comptime T : type]) : i64
  (comptime (struct-field-count (type T))))
(define (main) : i64 (field-count 1))")

(define (compiler-typecheck-type-literal-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (twice [comptime n : i64]) : i64 (* n 2))
(define (main) : i64 (twice 21))")
    (compiler-typecheck-ok? (compiler-typecheck-type-valued-comptime-source))
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (type i64) 0))"
      "type value i64 is compile-time only")
    (compiler-typecheck-error-ok?
      "(define (main) : type (type i64))"
      (compiler-typecheck-unknown-type-policy-message "type"))
    (compiler-typecheck-error-ok?
      "(define (f [value : type]) : i64 0)"
      (compiler-typecheck-unknown-type-policy-message "type"))
    (compiler-typecheck-error-ok?
      "(define value : type (type i64))"
      (compiler-typecheck-unknown-type-policy-message "type"))
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (type Missing) 0))"
      (compiler-typecheck-unknown-type-policy-message "Missing"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-type-valued-comptime-scalar-arg-source)
      "comptime argument 'T' for function 'field-count' must be a type value such as `(type i64)`")))

(define (compiler-typecheck-stdlib-comptime-expr-decl-source) : String
  "(comptime-decl (:generated stdlib/comptime-well-known Expr \"v0\")
  (defenum Expr
    (ExprBool bool)
    (ExprInt i64)
    (ExprVar String)
    (ExprSplice (Box Expr))
    (ExprIf (Box Expr) (Box Expr) (Box Expr))
    (ExprCall (Box Expr) ExprList)
    (ExprBegin ExprList)
    (ExprQuote (Box Expr))
    (ExprQuasiquote (Box Expr))
    (ExprUnquote (Box Expr))
    (ExprUnquoteSplicing (Box Expr))))")

(define (compiler-typecheck-stdlib-comptime-bad-expr-source) : String
  "(module stdlib.comptime)
(comptime-decl (:generated stdlib/comptime-well-known Expr \"v0\")
  (defenum Expr
    (ExprInt i64)))")

(define (compiler-typecheck-stdlib-comptime-bad-expr-list-source) : String
  (str-cat
    "(module stdlib.comptime)\n"
    (compiler-typecheck-stdlib-comptime-expr-decl-source)
    "\n(comptime-decl (:generated stdlib/comptime-well-known ExprList \"v0\")
  (defenum ExprList
    (ExprListNil)
    (ExprListCons Expr (Box ExprList))))"))

(define (compiler-typecheck-stdlib-comptime-plain-expr-source) : String
  "(module stdlib.comptime)
(defenum Expr
  (ExprBool bool)
  (ExprInt i64)
  (ExprVar String)
  (ExprSplice (Box Expr))
  (ExprIf (Box Expr) (Box Expr) (Box Expr))
  (ExprCall (Box Expr) ExprList)
  (ExprBegin ExprList)
  (ExprQuote (Box Expr))
  (ExprQuasiquote (Box Expr))
  (ExprUnquote (Box Expr))
  (ExprUnquoteSplicing (Box Expr)))")

(define (compiler-typecheck-stdlib-comptime-stale-expr-source) : String
  "(module stdlib.comptime)
(comptime-decl (:generated stdlib/comptime-well-known Expr \"v1\")
  (defenum Expr
    (ExprBool bool)
    (ExprInt i64)
    (ExprVar String)
    (ExprSplice (Box Expr))
    (ExprIf (Box Expr) (Box Expr) (Box Expr))
    (ExprCall (Box Expr) ExprList)
    (ExprBegin ExprList)
    (ExprQuote (Box Expr))
    (ExprQuasiquote (Box Expr))
    (ExprUnquote (Box Expr))
    (ExprUnquoteSplicing (Box Expr))))")

(define (compiler-typecheck-stdlib-comptime-surface-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stdlib-comptime-bad-expr-source)
      "typecheck: stdlib well-known type mismatch for stdlib.comptime.Expr: expected variant ExprBool at index 0")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stdlib-comptime-bad-expr-list-source)
      "typecheck: stdlib well-known type mismatch for stdlib.comptime.ExprList: expected defstruct")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stdlib-comptime-plain-expr-source)
      "typecheck: stdlib well-known type mismatch for stdlib.comptime.Expr: expected comptime-decl generated metadata stdlib/comptime-well-known \"v0\"")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stdlib-comptime-stale-expr-source)
      "typecheck: stdlib well-known type mismatch for stdlib.comptime.Expr: expected comptime-decl generated metadata stdlib/comptime-well-known \"v0\"")))

(define (compiler-typecheck-comptime-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (main) : i64 (comptime (+ 1 2)))")
    (compiler-typecheck-ok? "(define (main) : bool (comptime (< 1 2)))")
    (compiler-typecheck-ok? "(define (main) : f32 (comptime 1.5))")
    (compiler-typecheck-ok?
      "(define (main) : f32 (comptime (cast 1.00000001 : f32)))")
    (compiler-typecheck-ok?
      "(define (main) : i64 (comptime (let [a : i64 1] (if (< a 2) a 0))))")
    (compiler-typecheck-ok? "(define (main) : i64 (+ (comptime (* 6 7)) 0))")
    (compiler-typecheck-ok?
      "(define (mk) : Expr (comptime (expr-if (expr-bool true) (expr-splice (expr-bool false)) (expr-bool true))))")
    (compiler-typecheck-ok?
      "(define (mk) : bool (comptime (expr-if? (expr-if (expr-bool true) (expr-bool false) (expr-bool true)))))")
    (compiler-typecheck-error-ok?
      "(define (mk) : Expr (comptime (expr-if true (expr-bool true) (expr-bool false))))"
      "expr-if condition expects Expr")
    (compiler-typecheck-error-ok?
      "(define (f [x : i64]) : i64 (comptime x))"
      "compile-time evaluation cannot reference runtime variable 'x'")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (comptime (< 1 2)))"
      "typecheck: return type mismatch")
    (compiler-typecheck-stdlib-comptime-surface-tests-ok?)))

;; IO-builtin signature rules (#1042): whole-file helpers and file-handle status
;; primitives accept, plus wrong-argument, wrong-arity, and result-type-mismatch
;; rejections. Migrated from src/typechecker.rs read-file/write-file coverage.
(define (compiler-typecheck-io-builtin-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String]) : String (read-file p))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String]) : String (read-file p))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String] [c : String]) : unit (write-file p c))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String] [c : String]) : i64
  (begin
    (write-file p c)
    (file-open-status p 0)))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String] [c : String]) : i64 (append-file-status p c))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String]) : bool (file-exists? p))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [from : String] [to : String]) : i64
  (fs-rename-status from to))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String]) : i64 (fs-file-size-status p))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String]) : i64 (fs-file-size p))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [from : String] [to : String]) : i64
  (fs-rename-status from to))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f) : i64 (fs-current-dir-status))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f) : String (fs-current-dir))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String]) : i64 (file-open-status p 0))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [h : i64]) : i64 (file-close-status h))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [h : i64] [n : i64]) : i64 (file-read-chunk-status h n))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [h : i64] [c : String]) : i64 (file-write-status h c))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [h : i64]) : i64 (file-flush-status h))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [h : i64]) : String (file-read-chunk-bytes h))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [h : i64]) : bool (file-read-chunk-eof? h))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f) : String (read-stdin-line))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f) : String (read-stdin-bytes 3))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source "(define (f) : bool (stdin-eof?))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (read-file [n : i64]) : i64 (+ n 1))
(define (f) : i64 (read-file 41))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (file-open-status [path : i64] [mode : i64]) : bool true)
(define (f) : bool (file-open-status 1 2))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (read-stdin-line [limit : i64]) : i64 limit)
(define (f) : i64 (read-stdin-line 7))")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [c : String]) : unit (write-file 5 c))")
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String]) : unit (write-file p))")
        "typecheck: call arity mismatch: write-file expected 2 arguments, got 1 argument")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : i64]) : String (read-file p))")
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String]) : i64 (file-open-status p \"r\"))")
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [from : String]) : i64 (fs-rename-status from 5))")
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [from : String]) : i64 (fs-rename-status from))")
        "typecheck: call arity mismatch: fs-rename-status expected 2 arguments, got 1 argument")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [path : String]) : i64 (fs-current-dir-status path))")
        "typecheck: call arity mismatch: fs-current-dir-status expected 0 arguments, got 1 argument")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f) : i64 (file-close-status \"h\"))")
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [h : i64]) : i64 (file-write-status h 5))")
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f) : i64 (file-flush-status))")
        "typecheck: call arity mismatch: file-flush-status expected 1 argument, got 0 arguments")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-fs-source
          "(define (f [p : String] [c : String]) : i64 (write-file p c))")
        "typecheck: return type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : String (fs-current-dir))"
        "typecheck: unbound name fs-current-dir")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : String (read-stdin-line))"
        "typecheck: unbound name read-stdin-line")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [p : String]) : String (read-file p))"
        "typecheck: unbound name read-file")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f [p : String]) : i64 (file-open-status p 0))"
        "typecheck: unbound name file-open-status")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : i64 (fs-process-id))"
        "typecheck: unbound name fs-process-id")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : unit (flush-stdout))"
        "typecheck: unbound name flush-stdout")
        unit
        (set! ok false))
      ok)))

;; Raw-pointer null construction / check (#1054).
(define (compiler-typecheck-ptr-null-ok-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : (Ptr i64))) 1 0))")

(define (compiler-typecheck-ptr-null-mut-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : (MutPtr i64))) 1 0))")

(define (compiler-typecheck-ptr-null-bad-type-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : i64)) 1 0))")

(define (compiler-typecheck-ptr-null-check-bad-source) : String
  "(define (main) : i64 (if (ptr-null? 5) 1 0))")

(define (compiler-typecheck-ptr-null-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-ptr-null-ok-source))
    (compiler-typecheck-ok? (compiler-typecheck-ptr-null-mut-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-ptr-null-bad-type-source)
      "typecheck: ptr-null requires a pointer type, e.g. (ptr-null : (Ptr i64))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-ptr-null-check-bad-source)
      "typecheck: ptr-null? requires a raw pointer operand")))

;; Unsafe blocks (#1053): parse + typecheck like `begin`; empty `(unsafe)`
;; rejects at parse.
(define (compiler-typecheck-unsafe-ok-source) : String
  "(define (main) : i64 (unsafe 1 2 42))")

(define (compiler-typecheck-unsafe-empty-source) : String
  "(define (main) : i64 (unsafe))")

(define (compiler-typecheck-unsafe-define-safe-call-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64 (danger 42))")

(define (compiler-typecheck-unsafe-define-unsafe-call-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64 (unsafe (danger 42)))")

(define (compiler-typecheck-unsafe-define-safe-alias-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64
  (let [f : (-> i64 i64) danger]
    (f 42)))")

(define (compiler-typecheck-unsafe-define-shadow-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64
  (let [danger : (-> i64 i64) (lambda ([x : i64]) : i64 x)]
    (danger 42)))")

(define (compiler-typecheck-unsafe-extern-safe-call-source) : String
  "(unsafe (extern (raw-call [arg0 : i64]) : i64))
(define (main) : i64 (raw-call 42))")

(define (compiler-typecheck-unsafe-extern-unsafe-call-source) : String
  "(unsafe (extern (raw-call [arg0 : i64]) : i64))
(define (main) : i64 (unsafe (raw-call 42)))")

(define (compiler-typecheck-unsafe-import-safe-call-source) : String
  "(module foreign)
(unsafe (define (danger [x : i64]) : i64 x))
(export (value danger))
(module main)
(import \"foreign.tl\" module foreign :as f)
(define (main) : i64 (f.danger 42))")

(define (compiler-typecheck-unsafe-import-unsafe-call-source) : String
  "(module foreign)
(unsafe (define (danger [x : i64]) : i64 x))
(export (value danger))
(module main)
(import \"foreign.tl\" module foreign :as f)
(define (main) : i64 (unsafe (f.danger 42)))")

(define (compiler-typecheck-unsafe-fn-body-still-safe-source) : String
  "(unsafe (define (read-it [p : (Ptr i64)]) : i64 (ptr-read p)))")

(define (compiler-typecheck-unsafe-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-unsafe-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-unsafe-empty-source)
      "parse: unsafe requires a non-empty body")))

(define (compiler-typecheck-unsafe-decl-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-unsafe-define-safe-call-source)
        "typecheck: danger requires unsafe context")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-unsafe-define-unsafe-call-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-unsafe-define-safe-alias-source)
        "typecheck: danger requires unsafe context")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-unsafe-define-shadow-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-unsafe-extern-safe-call-source)
        "typecheck: raw-call requires unsafe context")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-unsafe-extern-unsafe-call-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-unsafe-import-safe-call-source)
        "typecheck: f/danger requires unsafe context")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-unsafe-import-unsafe-call-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-unsafe-fn-body-still-safe-source)
        "typecheck: ptr-read requires unsafe context")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-arena-safe-observe-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : i64
  (let
    [arena : i64 (arena-make)]
    [current : i64 (arena-current)]
    [mark : i64 (arena-mark)]
    (+ arena (+ current mark))))"))

(define (compiler-typecheck-arena-with-arena-safe-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (main) : i64
  (with-arena r
    (let [s : String (int->string 41)]
      (string-length s))))"))

(define (compiler-typecheck-arena-safe-set-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : unit
  (arena-set! (arena-current)))"))

(define (compiler-typecheck-arena-safe-destroy-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : unit
  (arena-destroy (arena-current)))"))

(define (compiler-typecheck-arena-safe-rewind-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : unit
  (arena-rewind (arena-mark)))"))

(define (compiler-typecheck-arena-safe-alias-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : unit
  (let
    [rewind : (-> i64 unit) arena-rewind]
    (rewind (arena-mark))))"))

(define (compiler-typecheck-arena-unimported-source) : String
  "(define (main) : i64 (arena-make))")

(define (compiler-typecheck-arena-top-level-shadow-source) : String
  "(define (arena-rewind [mark : i64]) : unit unit)
(define (arena-set! [arena : i64]) : unit unit)
(define (arena-destroy [arena : i64]) : unit unit)
(define (main) : unit
  (begin
    (arena-rewind 1)
    (arena-set! 2)
    (arena-destroy 3)))")

(define (compiler-typecheck-arena-local-shadow-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : unit
  (let
    [arena-rewind : (-> i64 unit) (lambda ([mark : i64]) : unit unit)]
    (arena-rewind 1)))"))

(define (compiler-typecheck-arena-unsafe-mutate-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : unit
  (let
    [arena : i64 (arena-current)]
    [mark : i64 (arena-mark)]
    (unsafe
      (arena-rewind mark)
      (arena-set! arena)
      (arena-destroy arena))))"))

(define (compiler-typecheck-arena-unsafe-alias-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : unit
  (let
    [mark : i64 (arena-mark)]
    (unsafe
      (let
        [rewind : (-> i64 unit) arena-rewind]
        (rewind mark)))))"))

(define (compiler-typecheck-arena-unsafe-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-arena-safe-observe-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-arena-with-arena-safe-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-arena-safe-set-source)
        "typecheck: arena-set! requires unsafe context")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-arena-safe-destroy-source)
        "typecheck: arena-destroy requires unsafe context")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-arena-safe-rewind-source)
        "typecheck: arena-rewind requires unsafe context")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-arena-safe-alias-source)
        "typecheck: arena-rewind requires unsafe context")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-arena-unimported-source)
        "typecheck: unbound name arena-make")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-arena-top-level-shadow-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-arena-local-shadow-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-arena-unsafe-mutate-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-arena-unsafe-alias-source))
        unit
        (set! ok false))
      ok)))

;; CTFE layout queries (#989): folded calls produce `i64`, runtime calls are
;; rejected, and `offset-of` is restricted to structs with known fields.
(define (compiler-typecheck-layout-query-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        "(define (f) : i64 (comptime (size-of (type i64))))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(define (f) : i64 (comptime (align-of (type bool))))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(defstruct Inner
  (x i32))
(defstruct Outer
  (tag u8)
  (inner Inner)
  (tail i64))
(define (f) : i64
  (comptime (+ (size-of (type Outer)) (offset-of (type Outer) tail))))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(defenum Choice
  (Empty)
  (Wide u8 i64))
(define (f) : i64
  (comptime (+ (size-of (type Choice)) (align-of (type Choice)))))")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        "(defstruct Box (x i64))
(define (f) : i64 (comptime (offset-of (type Box) x)))")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : i64 (comptime (size-of (type i64) (type bool))))"
        "size-of expects exactly one type argument")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (f) : i64 (size-of (type i64)))"
        "typecheck: size-of is compile-time only; wrap it in (comptime ...)")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(defstruct Packet
  (tag u8)
  (count i64))
(define (f) : i64 (comptime (offset-of (type Packet) missing)))"
        "offset-of unknown field missing")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-reflection-source) : String
  "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some String))
(define (field-count-helper [comptime T : type]) : i64
  (comptime (struct-field-count (type T))))
(define (enum-payload-helper [comptime T : type]) : i64
  (comptime (enum-variant-payload-count (type T) 1)))
(define (main) : i64
  (+ (field-count-helper (type Point))
     (+ (enum-payload-helper (type Maybe))
        (+ (comptime (if (string-eq (type-kind (type Point)) \"struct\") 1 0))
           (+ (comptime (if (string-eq (type-nominal-name (type Point)) \"Point\") 1 0))
              (+ (comptime (if (= (struct-field-type (type Point) 0) (type i64)) 1 0))
                 (+ (comptime (if (= (enum-variant-payload-type (type Maybe) 1 0) (type String)) 1 0))
                    (+ (comptime (array-length (type (Array i64 4))))
                       (+ (comptime (if (string-eq (type-key (type (& r str))) \"ref_r_str\") 1 0))
                          (comptime (function-param-count (type (-> i64 bool String)))))))))))))")

(define (compiler-typecheck-reflection-runtime-source) : String
  "(define (main) : String (type-kind (type i64)))")

(define (compiler-typecheck-reflection-string-result-source) : String
  "(define (main) : String (comptime (type-kind (type i64))))")

(define (compiler-typecheck-reflection-kind-mismatch-source) : String
  "(define (main) : i64 (comptime (struct-field-count (type i64))))")

(define (compiler-typecheck-reflection-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-reflection-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reflection-runtime-source)
      "typecheck: type-kind is compile-time only; wrap it in (comptime ...)")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reflection-string-result-source)
      "String value is compile-time only")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reflection-kind-mismatch-source)
      "struct-field-count requires struct type")))

(define (compiler-typecheck-defmacro-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(defmacro (first [x : bool] [rest : bool ...]) : bool x)
(define (main) : i64 0)")

(define (compiler-typecheck-defmacro-produced-mismatch-source) : String
  "(defmacro (bad) : i64 (expr-bool true))
(define (main) : i64 0)")

(define (compiler-typecheck-defmacro-body-type-source) : String
  "(defmacro (bad [x : bool]) : bool (expr-bool? x))
(define (main) : i64 0)")

(define (compiler-typecheck-defmacro-pure-string-source) : String
  "(defmacro (answer-name) : i64 (expr-var (string-concat \"ans\" \"wer\")))
(define answer : i64 42)
(define (main) : i64 (answer-name))")

(define (compiler-typecheck-defmacro-unsafe-source) : String
  "(defmacro (bad) : bool (unsafe (expr-bool true)))
(define (main) : i64 0)")

(define (compiler-typecheck-defmacro-extern-source) : String
  "(extern (read-file [path : String]) : String)
(defmacro (bad) : Expr (read-file \"input.txt\"))
(define (main) : i64 0)")

(define (compiler-typecheck-defmacro-transitive-extern-source) : String
  "(extern (raw-read) : String)
(define (helper) : String (raw-read))
(defmacro (bad) : Expr (helper))
(define (main) : i64 0)")

(define (compiler-typecheck-comptime-decl-unsafe-template-source) : String
  "(comptime-decl (define (bad) : i64 (unsafe 1)))
(define (main) : i64 0)")

(define (compiler-typecheck-quote-source) : String
  "(define (mk [e : Expr]) : Expr `(if ,e true false))
(define (body [xs : ExprList]) : Expr `(begin ,@xs))
(define (main) : i64 0)")

(define (compiler-typecheck-quote-bad-unquote-source) : String
  "(define (bad [x : i64]) : Expr `(if ,x true false))
(define (main) : i64 0)")

(define (compiler-typecheck-quote-bad-splice-source) : String
  "(define (bad [x : i64]) : Expr `(begin ,@x))
(define (main) : i64 0)")

(define (compiler-typecheck-quote-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-quote-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-quote-bad-unquote-source)
      "typecheck: unquote expects Expr")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-quote-bad-splice-source)
      "typecheck: unquote-splicing expects ExprList")))

(define (compiler-typecheck-defmacro-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-defmacro-source))
    (compiler-typecheck-ok? (compiler-typecheck-defmacro-pure-string-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defmacro-produced-mismatch-source)
      "typecheck: macro body produced type does not match declaration")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defmacro-body-type-source)
      "typecheck: macro body must return Expr")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defmacro-unsafe-source)
      "typecheck: comptime purity rejects unsafe block; reference path: bad -> unsafe")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defmacro-extern-source)
      "typecheck: comptime purity rejects extern reference read-file; reference path: bad -> read-file")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defmacro-transitive-extern-source)
      "typecheck: comptime purity rejects extern reference raw-read; reference path: bad -> helper -> raw-read")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-comptime-decl-unsafe-template-source)
      "typecheck: comptime purity rejects unsafe block; reference path: comptime-decl -> unsafe")))

;; --- macro expansion phase (#1139) ------------------------------------------
;; A macro call in an evaluated position is expanded before typechecking; the
;; spliced form must then typecheck. Arity and typed operands are checked at the
;; call site before the transformer runs; Expr operands are syntax captures.
(define (compiler-typecheck-macro-expand-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (main) : i64
  (let ([flag : bool true])
    (if (and2 flag true) 1 0)))")

(define (compiler-typecheck-macro-expand-arity-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (main) : i64 (if (and2 true) 1 0))")

(define (compiler-typecheck-macro-expand-operand-source) : String
  "(defmacro (ignore-bool [value : bool]) : bool
  (expr-bool true))
(define (main) : i64 (if (ignore-bool 1) 1 0))")

(define (compiler-typecheck-macro-expand-variadic-operand-source) : String
  "(defmacro (first [head : bool] [rest : bool ...]) : bool head)
(define (main) : i64 (if (first true 1) 1 0))")

(define (compiler-typecheck-macro-expr-wildcard-operand-source) : String
  "(defmacro (choose [condition : bool] [then-expr : Expr] [else-expr : Expr]) : Expr
  `(if ,condition ,then-expr ,else-expr))
(define (int-value [x : i64]) : i64
  (choose true (+ x 1) 0))
(define (bool-value [x : bool]) : bool
  (choose x true false))
(define (main) : i64 (int-value 10))")

(define (compiler-typecheck-macro-expr-shadow-source) : String
  "(defmacro (choose [condition : bool] [then-expr : Expr] [else-expr : Expr]) : Expr
  `(if ,condition ,then-expr ,else-expr))
(defenum Expr
  (EUserExpr i64))
(define (main) : i64
  (choose true 42 0))")

(define (compiler-typecheck-macro-expr-wildcard-expanded-mismatch-source) : String
  "(defmacro (choose [condition : bool] [then-expr : Expr] [else-expr : Expr]) : Expr
  `(if ,condition ,then-expr ,else-expr))
(define (main) : i64 (choose true 1 false))")

(define (compiler-typecheck-macro-expr-list-nth-source) : String
  "(defmacro (second [args : Expr ...]) : Expr
  (if (< (expr-list-length args) 2)
    (expr-var \"missing\")
    (expr-list-nth args 1)))
(define (main) : bool (second 42 true))")

(define (compiler-typecheck-macro-expand-depth-source) : String
  "(defmacro (again) : Expr `(again))
(define (main) : i64 (again))")

(define (compiler-typecheck-macro-export-source) : String
  "(module bool)
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(export (macro and2))
(module main)
(import \"bool.tl\" module bool :as b)
(define (main) : i64
  (if (b.and2 true true) 42 0))")

(define (compiler-typecheck-macro-forward-qualified-export-source) : String
  "(module main)
(import \"bool.tl\" module bool :as b)
(define (main) : i64
  (if (b.and-later true true) 42 0))
(module bool)
(export (macro and-later))
(defmacro (and-later [lhs : bool] [rhs : bool]) : bool
  `(if ,lhs ,rhs false))")

(define (compiler-typecheck-macro-private-source) : String
  "(module hidden)
(defmacro (private-and [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(module main)
(import \"hidden.tl\" module hidden :as hidden)
(define (main) : i64
  (if (hidden.private-and true true) 0 1))")

(define (compiler-typecheck-macro-missing-export-source) : String
  "(module hidden)
(defmacro (private-and [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(module main)
(import \"hidden.tl\" module hidden :as hidden)
(define (main) : i64
  (if (hidden.missing true true) 0 1))")

(define (compiler-typecheck-macro-forward-local-source) : String
  "(define eager : bool (late true))
(defmacro (late [value : bool]) : bool value)
(define (main) : i64 (if eager 42 0))")

(define (compiler-typecheck-macro-forward-chain-source) : String
  "(define (main) : i64
  (if (outer true) 42 0))
(defmacro (outer [value : bool]) : bool
  `(inner ,value))
(defmacro (inner [value : bool]) : bool value)")

(define (compiler-typecheck-macro-mutual-depth-source) : String
  "(define (main) : i64 (macro-a))
(defmacro (macro-a) : Expr `(macro-b))
(defmacro (macro-b) : Expr `(macro-a))")

(define (compiler-typecheck-module-macro-import-source) : String
  "(defmacro (gen) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)
    (export (value answer))))
(import (gen))
(define (main) : i64 (answer))")

(define (compiler-typecheck-module-macro-import-alias-source) : String
  "(defmacro (gen) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)
    (export (value answer))))
(import (gen) as generated)
(define (main) : i64 (generated.answer))")

(define (compiler-typecheck-module-macro-import-duplicate-source) : String
  "(defmacro (gen) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)
    (export (value answer))))
(import (gen))
(import (gen))
(define (main) : i64 (answer))")

(define (compiler-typecheck-module-macro-import-target-collision-source) : String
  "(defmacro (gen-a) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)
    (export (value answer))))
(defmacro (gen-b) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 99)
    (export (value answer))))
(import (gen-a))
(import (gen-b))
(define (main) : i64 (answer))")

(define (compiler-typecheck-module-macro-import-missing-module-source) : String
  "(defmacro (gen) : Module
  `(define (answer) : i64 42))
(import (gen))
(define (main) : i64 0)")

(define (compiler-typecheck-module-macro-expression-source) : String
  "(defmacro (gen) : Module (expr-var \"unused\"))
(define (main) : i64 (gen))")

(define (compiler-typecheck-decls-macro-import-source) : String
  "(defmacro (gen) : Decls (expr-var \"unused\"))
(import (gen))
(define (main) : i64 0)")

(define (compiler-typecheck-decls-macro-expression-source) : String
  "(defmacro (gen) : Decls (expr-var \"unused\"))
(define (main) : i64 (gen))")

(define (compiler-typecheck-decls-macro-single-source) : String
  "(defmacro (gen) : Decls
  `(define (answer) : i64 42))
(gen)
(define (main) : i64 (answer))")

(define (compiler-typecheck-decls-macro-multiple-source) : String
  "(defmacro (gen) : Decls
  `(begin
    (define (left) : i64 20)
    (define (right) : i64 22)))
(gen)
(define (main) : i64 (+ (left) (right)))")

(define (compiler-typecheck-decls-macro-import-followup-source) : String
  "(module generated)
(define (answer) : i64 42)
(export (value answer))
(module main)
(defmacro (gen) : Decls
  `(import generated))
(gen)
(define (main) : i64 (generated.answer))")

(define (compiler-typecheck-decls-macro-duplicate-source) : String
  "(defmacro (gen) : Decls
  `(define (answer) : i64 42))
(define (answer) : i64 1)
(gen)
(define (main) : i64 (answer))")

(define (compiler-typecheck-expression-macro-module-scope-source) : String
  "(defmacro (gen) : Expr (expr-var \"unused\"))
(gen)
(define (main) : i64 0)")

(define (compiler-typecheck-macro-runtime-import-order-source) : String
  "(define (runtime-touch [text : String]) : unit
  (if true
    (unsafe
      (let [ptr : (Ptr u8) (string-data text)] unit))
    unit))
(module stdlib.core_macros)
(defmacro (and [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool true)
    `(if ,(expr-list-head args)
       (and ,@(expr-list-tail args))
       false)))
(defmacro (or [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool false)
    `(if ,(expr-list-head args)
       true
       (or ,@(expr-list-tail args)))))
(defmacro (when [condition : bool] [body : unit]) : unit
  `(if ,condition ,body unit))
(defmacro (unless [condition : bool] [body : unit]) : unit
  `(if ,condition unit ,body))
(export (macro and))
(export (macro or))
(export (macro when))
(export (macro unless))
(module main)
(define (main) : i64
      (let [value : i64 0]
    (begin
      (when true (set! value 21))
      (unless false (set! value (+ value 21)))
      (if (and (= value 42) (or false true)) value 0))))")

(define (compiler-typecheck-macro-prelude-module-source) : String
  "(module stdlib.core_macros)
(defmacro (and [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool true)
    `(if ,(expr-list-head args)
       (and ,@(expr-list-tail args))
       false)))
(defmacro (or [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool false)
    `(if ,(expr-list-head args)
       true
       (or ,@(expr-list-tail args)))))
(export (macro and))
(export (macro or))
(module main)
")

(define (compiler-typecheck-macro-prelude-and-or-source) : String
  (string-append
    (compiler-typecheck-macro-prelude-module-source)
    "(define (main [x : bool] [y : bool]) : i64
  (if (and x y)
    42
    (if (or x y) 7 0)))"))

(define (compiler-typecheck-macro-prelude-and-bad-source) : String
  (string-append
    (compiler-typecheck-macro-prelude-module-source)
    "(define (main [a : bool]) : bool (and a 1))"))

(define (compiler-typecheck-macro-prelude-or-bad-source) : String
  (string-append
    (compiler-typecheck-macro-prelude-module-source)
    "(define (main [a : bool]) : bool (or 1 a))"))

(define (compiler-typecheck-macro-forward-prelude-shadow-source) : String
  (string-append
    (compiler-typecheck-macro-prelude-module-source)
    "(define (main) : i64 (and 1 41))
(defmacro (and [lhs : i64] [rhs : i64]) : i64
  `(+ ,lhs ,rhs))"))

(define (compiler-typecheck-macro-hygiene-capture-source) : String
  "(defmacro (with-temp-bool [body : bool]) : bool
  `(let ([tmp : i64 1])
     ,body))
(define (main) : bool
  (let ([tmp : bool true])
    (with-temp-bool tmp)))")

(define (compiler-typecheck-macro-forward-hygiene-source) : String
  "(define (main) : bool
  (let ([tmp : bool true])
    (with-late-temp tmp)))
(defmacro (with-late-temp [body : bool]) : bool
  `(let ([tmp : i64 1])
     ,body))")

(define (compiler-typecheck-macro-hygiene-definition-source) : String
  "(define (macro-helper [x : bool]) : bool (not x))
(defmacro (unless2 [condition : bool] [body : unit]) : unit
  `(if (macro-helper ,condition)
     ,body
     unit))
(define (main) : unit
  (let ([macro-helper : bool true])
    (unless2 false unit)))")

(define (compiler-typecheck-macro-hygiene-imported-definition-source) : String
  "(module macros)
(define (macro-helper [x : bool]) : bool (not x))
(defmacro (choose-helper [condition : bool] [body : Expr]) : Expr
  `(if (macro-helper ,condition)
     ,body
     0))
(export (macro choose-helper))
(module main)
(import \"macros.tl\" module macros as m)
(define (macro-helper [x : bool]) : i64 7)
(define (main) : i64
  (m.choose-helper false (macro-helper true)))")

(define (compiler-typecheck-macro-dotted-import-default-alias-source) : String
  "(module pkg.macros)
(define (macro-helper [x : bool]) : bool (not x))
(defmacro (choose-helper [condition : bool] [body : Expr]) : Expr
  `(if (macro-helper ,condition)
     ,body
     0))
(export (macro choose-helper))
(module main)
(import pkg.macros)
(define (macro-helper [x : bool]) : i64 7)
(define (main) : i64
  (macros.choose-helper false (macro-helper true)))")

(define (compiler-typecheck-macro-hygiene-imported-builtin-source) : String
  "(module macros)
(defmacro (dyn-len [items : Expr]) : i64
  `(array-length ,items))
(export (macro dyn-len))
(module main)
(import \"macros.tl\" module macros as m)
(define (main [items : (Array i64)]) : i64
  (m.dyn-len items))")

(define (compiler-typecheck-macro-hygiene-nested-source) : String
  "(defmacro (with-temp-bool [body : bool]) : bool
  `(let ([tmp : i64 1])
     ,body))
(defmacro (wrap-temp [body : bool]) : bool
  `(with-temp-bool ,body))
(define (main) : bool
  (let ([tmp : bool true])
    (wrap-temp tmp)))")

(define (compiler-typecheck-macro-hygiene-exported-helper-local-source) : String
  "(module m)
(defmacro (id-expr [body : Expr]) : i64 body)
(defmacro (with-temp [value : i64]) : i64
  `(let ([tmp : i64 ,value])
     (id-expr tmp)))
(export (macro id-expr))
(export (macro with-temp))
(module main)
(import m)
(define (main) : i64 (m.with-temp 42))")

(define (compiler-typecheck-macro-hygiene-splice-source) : String
  "(defmacro (with-temp-do [steps : unit ...]) : unit
  `(let ([tmp : i64 1])
     (begin ,@steps)))
(define (main) : unit
  (let ([tmp : unit unit])
    (with-temp-do tmp)))")

(define (compiler-typecheck-macro-hygiene-unsafe-global-source) : String
  "(unsafe (define (danger [x : i64]) : i64 x))
(defmacro (call-danger [x : i64]) : i64
  `(danger ,x))
(define (main) : i64 (call-danger 1))")

(define (compiler-typecheck-macro-own-when-source) : String
  "(defmacro (when [condition : i64] [body : unit]) : unit body)
(define (main) : unit (when 1 unit))")

(define (compiler-typecheck-macro-own-unless-source) : String
  "(defmacro (unless [condition : i64] [body : unit]) : unit body)
(define (main) : unit (unless 1 unit))")

(define (compiler-typecheck-macro-own-cond-source) : String
  "(defmacro (cond [arm : ExprClause]) : i64
  (expr-clause-second arm))
(define (main) : i64 (cond [true 42]))")

(define (compiler-typecheck-macro-own-and-source) : String
  "(defmacro (and [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool true)
    `(if ,(expr-list-head args)
       (and ,@(expr-list-tail args))
       false)))
(define (main [x : bool] [y : bool] [z : bool]) : i64
  (if (and)
    (if (and x)
      (if (and x y z) 42 0)
      0)
    0))")

(define (compiler-typecheck-macro-own-or-source) : String
  "(defmacro (or [args : bool ...]) : bool
  (if (expr-list-empty? args)
    (expr-bool false)
    `(if ,(expr-list-head args)
       true
       (or ,@(expr-list-tail args)))))
(define (main [x : bool] [y : bool] [z : bool]) : i64
  (if (or)
    0
    (if (or x)
      42
      (if (or x y z) 42 0))))")

(define (compiler-typecheck-compat-guards-source) : String
  "(define (main) : unit
  (begin
    (when true unit)
    (unless false unit)))")

(define (compiler-typecheck-macro-ownership-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-macro-own-when-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-own-unless-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-own-cond-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-own-and-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-own-or-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-forward-prelude-shadow-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-prelude-and-or-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-prelude-and-bad-source)
      "typecheck: macro operand type mismatch: expected bool, got i32")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-prelude-or-bad-source)
      "typecheck: macro operand type mismatch: expected bool, got i32")
    (compiler-typecheck-ok? (compiler-typecheck-compat-guards-source))))

(define (compiler-typecheck-macro-export-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-macro-export-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-forward-qualified-export-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-private-source)
      "typecheck: private macro hidden/private-and")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-missing-export-source)
      "typecheck: missing macro export hidden/missing")
    (compiler-typecheck-ok? (compiler-typecheck-macro-forward-local-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-forward-chain-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-mutual-depth-source)
      "macro expansion exceeded depth limit")
    (compiler-typecheck-ok? (compiler-typecheck-module-macro-import-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-module-macro-import-alias-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-module-macro-import-duplicate-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-module-macro-import-target-collision-source)
      "typecheck: Module macro output collides with existing module generated.module for generated identity :gen-b()")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-module-macro-import-missing-module-source)
      "typecheck: Module macro output must include a module declaration")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-module-macro-expression-source)
      "typecheck: Module macro can only be used in import position")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-decls-macro-import-source)
      "typecheck: Decls macro cannot be used in import position")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-decls-macro-expression-source)
      "typecheck: Decls macro can only be used at module scope")
    (compiler-typecheck-ok? (compiler-typecheck-decls-macro-single-source))
    (compiler-typecheck-ok? (compiler-typecheck-decls-macro-multiple-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-decls-macro-import-followup-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-decls-macro-duplicate-source)
      "symbols: duplicate value declaration answer")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-expression-macro-module-scope-source)
      "typecheck: expression macro cannot be used at module scope")
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-runtime-import-order-source))))

;; Returns true when a macro call expands and the result typechecks, and when
;; arity plus operand-type errors are rejected during expansion at the call site.
(define (compiler-typecheck-macro-expand-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-macro-expand-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-expand-arity-source)
      "macro call has too few arguments")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-expand-operand-source)
      "typecheck: macro operand type mismatch: expected bool, got i32")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-expand-variadic-operand-source)
      "typecheck: macro operand type mismatch: expected bool, got i32")
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-expr-wildcard-operand-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-expr-shadow-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-expr-wildcard-expanded-mismatch-source)
      "typecheck: if branches must match")
    (compiler-typecheck-ok? (compiler-typecheck-macro-expr-list-nth-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-expand-depth-source)
      "macro expansion exceeded depth limit")
    (compiler-typecheck-macro-export-tests-ok?)
    (compiler-typecheck-ok? (compiler-typecheck-macro-hygiene-capture-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-forward-hygiene-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-hygiene-definition-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-hygiene-imported-definition-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-dotted-import-default-alias-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-hygiene-imported-builtin-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-hygiene-nested-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-hygiene-exported-helper-local-source))
    (compiler-typecheck-ok? (compiler-typecheck-macro-hygiene-splice-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-macro-hygiene-unsafe-global-source)
      "typecheck: danger requires unsafe context")
    (compiler-typecheck-macro-ownership-tests-ok?)))

(define (compiler-typecheck-self-test-basics) : unit
  (begin
    (if (intern-qualified-metadata-tests-ok?)
      unit
      (panic "typecheck: intern qualified metadata tests failed"))
    (if (tc-type-env-box-smoke?)
      unit
      (panic "typecheck: boxed type env smoke mismatch"))
    (if (tc-type-env-local-cache-smoke?)
      unit
      (panic "typecheck: local type env cache smoke mismatch"))
    (if (tc-spmd-env-box-smoke?)
      unit
      (panic "typecheck: boxed spmd env smoke mismatch"))
    (if (compiler-typecheck-ptr-null-tests-ok?)
      unit
      (panic "typecheck: ptr-null construction/check tests failed"))
    (if (compiler-typecheck-unsafe-tests-ok?)
      unit
      (panic "typecheck: unsafe block tests failed"))
    (if (compiler-typecheck-unsafe-decl-tests-ok?)
      unit
      (panic "typecheck: unsafe declaration tests failed"))
    (if (compiler-typecheck-arena-unsafe-tests-ok?)
      unit
      (panic "typecheck: arena unsafe primitive tests failed"))
    (if (compiler-typecheck-raw-pointer-op-tests-ok?)
      unit
      (panic "typecheck: raw pointer unsafe operation tests failed"))
    (if (compiler-typecheck-statement-tests-ok?)
      unit
      (panic "typecheck: statement/control-flow tests failed"))
    (if (compiler-typecheck-operator-tests-ok?)
      unit
      (panic "typecheck: operator/arity tests failed"))
    (if (compiler-typecheck-scalar-parity-tests-ok?)
      unit
      (panic "typecheck: scalar bool/float/cast parity tests failed"))
    (if (compiler-typecheck-match-tests-ok?)
      unit
      (panic "typecheck: match/pattern tests failed"))
    (if (compiler-typecheck-spmd-reduce-op-tests-ok?)
      unit
      (panic "typecheck: spmd-reduce operator/type tests failed"))
    (if (compiler-typecheck-spmd-reduce-purity-tests-ok?)
      unit
      (panic "typecheck: spmd-reduce purity tests failed"))
    (if (compiler-typecheck-spmd-broadcast-tests-ok?)
      unit
      (panic "typecheck: spmd-broadcast tests failed"))
    (if (compiler-typecheck-array-builtin-tests-ok?)
      unit
      (panic "typecheck: array-builtin signature tests failed"))
    (match (typecheck-compiler-source (compiler-typecheck-smoke-source))
      [(OkCompilerTypecheck summary)
        (if (= (compiler-typecheck-summary-score summary) 121)
          unit
          (panic "typecheck: smoke score mismatch"))]
      [(ErrCompilerTypecheck diag)
        (begin
          (panic (compiler-diagnostic-message diag))
          ;; lint-allow: unreachable-code
          unit)])
    unit))

;; --- move checker fixtures (#1048) ------------------------------------------
;; `String` is move-only; binding it into a fresh local with `let` moves it, so a
;; later read of the source is a use-after-move. Copyable scalars are never moved.
(define (compiler-typecheck-move-use-after-move-source) : String
  "(define (use-after-move [s : String]) : String
  (let [t : String s] s))")

(define (compiler-typecheck-move-single-move-source) : String
  "(define (single-move [s : String]) : String
  (let [t : String s] t))")

(define (compiler-typecheck-move-copyable-source) : String
  "(define (copy-reuse [n : i64]) : i64
  (let [t : i64 n] (+ n t)))")

(define (compiler-typecheck-move-branch-source) : String
  "(define (branch-move [flag : bool] [s : String]) : String
  (begin (if flag (let [t : String s] t) (let [u : String s] u)) s))")

(define (compiler-typecheck-move-ordinary-sharing-source) : String
  "(defstruct OrdinaryPacket
  (name String)
  (count i64))
(defstruct OrdinaryWrapper
  (packet OrdinaryPacket))
(defenum MaybeCount (SomeCount i64) (NoCount))
(define (inspect-packet [p : OrdinaryPacket]) : i64 (struct-get p count))
(define (ordinary-sharing [p : OrdinaryPacket] [m : MaybeCount]) : i64
  (begin
    (inspect-packet p)
    (let [w : OrdinaryWrapper (OrdinaryWrapper p)]
      (begin
        (match m [(SomeCount v) v] [NoCount 0])
        (+ (struct-get p count) (struct-get (struct-get w packet) count))))))")

(define (compiler-typecheck-move-ordinary-enum-match-reuse-source) : String
  "(defenum Flag (On) (Off))
(define (ordinary-enum-match-reuse [flag : Flag]) : i64
  (begin
    (match flag [(On) 1] [(Off) 0])
    (match flag [(On) 2] [(Off) 3])))")

(define (compiler-typecheck-move-cleanup-enum-match-source) : String
  "(defenum Ticket
  (:cleanup cleanup-ticket)
  (Open i64)
  (Closed))
(define (cleanup-enum-match [ticket : Ticket]) : i64
  (match ticket [(Open code) code] [(Closed) 0]))")

(define (compiler-typecheck-move-cleanup-enum-match-param-reuse-source) : String
  "(defenum Ticket
  (:cleanup cleanup-ticket)
  (Open i64)
  (Closed))
(define (take-ticket [ticket : Ticket]) : unit unit)
(define (bad-cleanup-enum-match-param-reuse [ticket : Ticket]) : unit
  (begin
    (match ticket [(Open code) unit] [(Closed) unit])
    (take-ticket ticket)))")

(define (compiler-typecheck-move-cleanup-enum-match-local-reuse-source) : String
  "(defenum Ticket
  (:cleanup cleanup-ticket)
  (Open i64)
  (Closed))
(define (take-ticket [ticket : Ticket]) : unit unit)
(define (bad-cleanup-enum-match-local-reuse [n : i64]) : unit
  (with ([ticket (Open n) cleanup-ticket])
    (begin
      (match ticket [(Open code) unit] [(Closed) unit])
      (take-ticket ticket))))")

(define (compiler-typecheck-move-cleanup-enum-payload-prefix) : String
  "(define (close-fd [fd : i64]) : unit unit)
(define (close-code [code : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defenum MaybeHandle
  (:cleanup cleanup-maybe-handle)
  (Some FileHandle (:owned))
  (Code i64 (:cleanup close-code))
  (None))
(define (take-handle [h : FileHandle]) : unit unit)
")

(define (compiler-typecheck-move-cleanup-enum-owner-payload-one-shot-source) : String
  (string-append
    (compiler-typecheck-move-cleanup-enum-payload-prefix)
    "(define (cleanup-enum-owner-payload-one-shot [m : MaybeHandle]) : unit
  (match m
    [(Some h) (take-handle h)]
    [(Code code) unit]
    [(None) unit]))"))

(define (compiler-typecheck-move-cleanup-enum-owner-payload-repeat-source) : String
  (string-append
    (compiler-typecheck-move-cleanup-enum-payload-prefix)
    "(define (bad-cleanup-enum-owner-payload-repeat [m : MaybeHandle]) : unit
  (match m
    [(Some h) (begin (take-handle h) (take-handle h))]
    [(Code code) unit]
    [(None) unit]))"))

(define (compiler-typecheck-move-cleanup-enum-payload-copyable-source) : String
  (string-append
    (compiler-typecheck-move-cleanup-enum-payload-prefix)
    "(define (cleanup-enum-payload-copyable [m : MaybeHandle]) : i64
  (match m
    [(Some h) 0]
    [(Code code) (+ code code)]
    [(None) 0]))"))

(define (compiler-typecheck-move-cleanup-enum-payload-shadow-source) : String
  (string-append
    (compiler-typecheck-move-cleanup-enum-payload-prefix)
    "(define (cleanup-enum-payload-shadow
  [h : FileHandle]
  [m : MaybeHandle]) : unit
  (begin
    (match m
      [(Some h) (take-handle h)]
      [(Code code) unit]
      [(None) unit])
    (take-handle h)))"))

(define (compiler-typecheck-move-owner-call-ok-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (valid-owner-call [h : FileHandle]) : unit (take-handle h))")

(define (compiler-typecheck-move-owner-call-reuse-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-call [h : FileHandle]) : i64
  (begin (take-handle h) (struct-get h fd)))")

(define (compiler-typecheck-move-owner-constructor-reuse-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-holder [holder : Holder]) : unit unit)
(define (bad-owner-constructor [h : FileHandle]) : i64
  (begin
    (take-holder (Holder h 1))
    (struct-get h fd)))")

(define (compiler-typecheck-move-owner-return-reuse-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-return [h : FileHandle]) : FileHandle
  (begin (return h) h))")

(define (compiler-typecheck-move-ordinary-projection-source) : String
  "(defstruct Counter
  (value i64))
(defstruct CounterHolder
  (counter Counter)
  (tag i64))
(define (inspect-counter [c : Counter]) : i64 (struct-get c value))
(define (ordinary-projection [p : CounterHolder]) : i64
  (begin
    (inspect-counter (struct-get p counter))
    (struct-get p tag)))")

(define (compiler-typecheck-move-owner-projection-other-field-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-projection-other-field [p : Holder]) : i64
  (begin
    (take-handle (struct-get p handle))
    (struct-get p size)))")

(define (compiler-typecheck-move-owner-projection-one-shot-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-projection-one-shot [p : Holder]) : unit
  (take-handle (struct-get p handle)))")

(define (compiler-typecheck-move-owner-projection-bind-other-field-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (owner-projection-bind-other-field [p : Holder]) : i64
  (with ([h (struct-get p handle) cleanup-file-handle])
    (struct-get p size)))")

(define (compiler-typecheck-move-owner-projection-nested-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Inner
  (:cleanup cleanup-inner)
  (handle FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (inner Inner (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-projection-nested [p : Holder]) : unit
  (take-handle (struct-get (struct-get p inner) handle)))")

(define (compiler-typecheck-move-owner-projection-nested-siblings-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Inner
  (:cleanup cleanup-inner)
  (handle FileHandle (:owned))
  (backup FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (inner Inner (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-projection-nested-siblings [p : Holder]) : unit
  (begin
    (take-handle (struct-get (struct-get p inner) handle))
    (take-handle (struct-get (struct-get p inner) backup))))")

(define (compiler-typecheck-move-owner-projection-nested-repeat-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Inner
  (:cleanup cleanup-inner)
  (handle FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (inner Inner (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-projection-nested-repeat [p : Holder]) : unit
  (begin
    (take-handle (struct-get (struct-get p inner) handle))
    (take-handle (struct-get (struct-get p inner) handle))))")

(define (compiler-typecheck-move-owner-projection-nested-root-reuse-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Inner
  (:cleanup cleanup-inner)
  (handle FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (inner Inner (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (take-holder [h : Holder]) : unit unit)
(define (bad-owner-projection-nested-root-reuse [p : Holder]) : unit
  (begin
    (take-handle (struct-get (struct-get p inner) handle))
    (take-holder p)))")

(define (compiler-typecheck-move-owner-projection-nested-parent-after-child-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Inner
  (:cleanup cleanup-inner)
  (handle FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (inner Inner (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (take-inner [h : Inner]) : unit unit)
(define (bad-owner-projection-nested-parent-after-child [p : Holder]) : unit
  (begin
    (take-handle (struct-get (struct-get p inner) handle))
    (take-inner (struct-get p inner))))")

(define (compiler-typecheck-move-owner-projection-nested-child-after-parent-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Inner
  (:cleanup cleanup-inner)
  (handle FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (inner Inner (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (take-inner [h : Inner]) : unit unit)
(define (bad-owner-projection-nested-child-after-parent [p : Holder]) : unit
  (begin
    (take-inner (struct-get p inner))
    (take-handle (struct-get (struct-get p inner) handle))))")

(define (compiler-typecheck-move-owner-projection-nested-set-reset-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Inner
  (:cleanup cleanup-inner)
  (handle FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (inner Inner (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-projection-nested-set-reset [p : Holder]) : unit
  (begin
    (take-handle (struct-get (struct-get p inner) handle))
    (set! p (Holder (Inner (FileHandle 10) 11) 12))
    (take-handle (struct-get (struct-get p inner) handle))))")

(define (compiler-typecheck-move-owner-projection-nested-shadow-reset-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Inner
  (:cleanup cleanup-inner)
  (handle FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (inner Inner (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-projection-nested-shadow-reset [p : Holder]) : unit
  (with ([q p cleanup-holder])
    (begin
      (struct-get (struct-get (struct-get q inner) handle) fd)
      (with ([q (Holder (Inner (FileHandle 20) 21) 22) cleanup-holder])
        (begin
          (struct-get (struct-get (struct-get q inner) handle) fd)
          unit)))))")

(define (compiler-typecheck-move-owner-projection-repeat-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-projection-repeat [p : Holder]) : unit
  (begin
    (take-handle (struct-get p handle))
    (take-handle (struct-get p handle))))")

(define (compiler-typecheck-move-owner-projection-root-reuse-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (take-holder [h : Holder]) : unit unit)
(define (bad-owner-projection-root-reuse [p : Holder]) : unit
  (begin
    (take-handle (struct-get p handle))
    (take-holder p)))")

(define (compiler-typecheck-move-owner-projection-key-collision-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-projection-key-collision
  [p : Holder]
  [p.handle : Holder]
  [p.__tl_partial : Holder]) : i64
  (begin
    (take-handle (struct-get p handle))
    (+ (struct-get p.handle size) (struct-get p.__tl_partial size))))")

(define (compiler-typecheck-move-owner-tuple-ref-reuse-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-tuple-ref-other-element [p : (Tuple FileHandle i64)]) : i64
  (begin
    (take-handle (tuple-ref p 0))
    (tuple-ref p 1)))")

(define (compiler-typecheck-move-owner-tuple-ref-repeat-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-tuple-ref-repeat [p : (Tuple FileHandle i64)]) : unit
  (begin
    (take-handle (tuple-ref p 0))
    (take-handle (tuple-ref p 0))))")

(define (compiler-typecheck-move-owner-tuple-ref-nested-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-tuple-ref-nested [p : (Tuple (Tuple FileHandle i64) i64)]) : unit
  (take-handle (tuple-ref (tuple-ref p 0) 0)))")

(define (compiler-typecheck-move-owner-tuple-ref-nested-repeat-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-tuple-ref-nested-repeat [p : (Tuple (Tuple FileHandle i64) i64)]) : unit
  (begin
    (take-handle (tuple-ref (tuple-ref p 0) 0))
    (take-handle (tuple-ref (tuple-ref p 0) 0))))")

(define (compiler-typecheck-move-owner-tuple-ref-nested-sibling-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-tuple-ref-nested-sibling [p : (Tuple (Tuple FileHandle FileHandle) i64)]) : unit
  (begin
    (take-handle (tuple-ref (tuple-ref p 0) 0))
    (take-handle (tuple-ref (tuple-ref p 0) 1))))")

(define (compiler-typecheck-move-owner-array-ref-other-element-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-other-element [items : (Array FileHandle 2)]) : i64
  (begin
    (take-handle (array-ref items 0))
    (struct-get (array-ref items 1) fd)))")

(define (compiler-typecheck-move-owner-array-ref-repeat-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-repeat [items : (Array FileHandle 1)]) : unit
  (begin
    (take-handle (array-ref items 0))
    (take-handle (array-ref items 0))))")

(define (compiler-typecheck-move-owner-array-ref-reinit-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-reinit [items : (Array FileHandle 1)]) : unit
  (begin
    (take-handle (array-ref items 0))
    (array-set! items 0 (FileHandle 7))
    (take-handle (array-ref items 0))))")

(define (compiler-typecheck-move-owner-array-ref-reinit-root-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-reinit-root [items : (Array FileHandle 1)]) : unit
  (begin
    (take-handle (array-ref items 0))
    (array-set! items 0 (FileHandle 7))
    (let [next : (Array FileHandle 1) items] unit)))")

(define (compiler-typecheck-move-owner-array-ref-reinit-sibling-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-reinit-sibling [items : (Array FileHandle 2)]) : unit
  (begin
    (take-handle (array-ref items 0))
    (array-set! items 1 (FileHandle 7))
    (take-handle (array-ref items 0))))")

(define (compiler-typecheck-move-owner-array-ref-reinit-nonliteral-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-reinit-nonliteral
  [items : (Array FileHandle 2)]
  [index : i64]) : unit
  (begin
    (take-handle (array-ref items 0))
    (array-set! items index (FileHandle 7))
    (take-handle (array-ref items 0))))")

(define (compiler-typecheck-move-owner-array-ref-nested-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-nested [items : (Array (Array FileHandle 2) 2)]) : unit
  (take-handle (array-ref (array-ref items 0) 1)))")

(define (compiler-typecheck-move-owner-array-ref-nested-repeat-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-nested-repeat [items : (Array (Array FileHandle 2) 2)]) : unit
  (begin
    (take-handle (array-ref (array-ref items 0) 1))
    (take-handle (array-ref (array-ref items 0) 1))))")

(define (compiler-typecheck-move-owner-array-ref-nested-sibling-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-nested-sibling [items : (Array (Array FileHandle 2) 2)]) : unit
  (begin
    (take-handle (array-ref (array-ref items 0) 1))
    (take-handle (array-ref (array-ref items 0) 0))))")

(define (compiler-typecheck-move-owner-array-ref-nonliteral-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-nonliteral
  [items : (Array FileHandle 2)]
  [index : i64]) : unit
  (take-handle (array-ref items index)))")

(define (compiler-typecheck-move-owner-dyn-array-ref-call-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-dyn-array-ref-call [items : (Array FileHandle)] [i : i64]) : unit
  (take-handle (array-ref items i)))")

(define (compiler-typecheck-move-owner-dyn-array-ref-bind-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-dyn-array-ref-bind [items : (Array FileHandle)] [i : i64]) : i64
  (let [h : FileHandle (array-ref items i)]
    (struct-get h fd)))")

(define (compiler-typecheck-move-box-get-copyable-source) : String
  "(define (main) : i64
  (let
    [cell : (Box i64) (box 7)]
    (box-get cell)))")

(define (compiler-typecheck-move-owner-box-get-call-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-box-get-call [cell : (Box FileHandle)]) : unit
  (take-handle (box-get cell)))")

(define (compiler-typecheck-move-owner-box-get-bind-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-box-get-bind [cell : (Box FileHandle)]) : i64
  (let [h : FileHandle (box-get cell)]
    (struct-get h fd)))")

(define (compiler-typecheck-move-owner-box-get-return-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-box-get-return [cell : (Box FileHandle)]) : FileHandle
  (return (box-get cell)))")

(define (compiler-typecheck-move-box-take-reuse-source) : String
  "(define (bad-box-take-reuse [cell : (Box String)]) : i64
  (let
    [value : String (box-take cell)]
    (+ (string-length value) (string-length (box-get cell)))))")

(define (compiler-typecheck-move-branch-arm-isolated-source) : String
  "(define (branch-arm-isolated [flag : bool] [s : String]) : String
  (if flag (let [t : String s] t) s))")

(define (compiler-typecheck-move-lambda-body-discard-source) : String
  "(define (lambda-body-discard [s : String]) : String
  (begin (lambda () : unit (let [t : String s] unit)) s))")

(define (compiler-typecheck-move-owner-lambda-capture-box-ok-source) : String
  "(define (owner-lambda-capture-box-ok [cell : (Box i64)]) : (-> i64)
  (lambda () : i64 (box-get cell)))")

(define (compiler-typecheck-move-owner-lambda-capture-box-reuse-source) : String
  "(define (bad-owner-lambda-capture-box-reuse [cell : (Box i64)]) : i64
  (begin (lambda () : i64 (box-get cell)) (box-get cell)))")

(define (compiler-typecheck-move-owner-lambda-capture-cleanup-reuse-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-lambda-capture-cleanup-reuse [h : FileHandle]) : i64
  (begin (lambda () : i64 (struct-get h fd)) (struct-get h fd)))")

(define (compiler-typecheck-move-owner-lambda-body-reuse-source) : String
  "(define (take-cell [cell : (Box i64)]) : unit unit)
(define (bad-owner-lambda-body-reuse [cell : (Box i64)]) : (-> i64)
  (lambda () : i64 (begin (take-cell cell) (box-get cell))))")

(define (compiler-typecheck-move-while-loop-carried-param-source) : String
  "(define (bad-while-loop-carried-param [flag : bool] [s : String]) : String
  (begin (while flag (let [t : String s] unit)) s))")

(define (compiler-typecheck-move-while-loop-carried-local-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (bad-while-loop-carried-local [flag : bool]) : unit
  (let
    [s : String (int->string 1)]
    (while flag (let [t : String s] unit))))"))

(define (compiler-typecheck-move-while-body-local-owner-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (while-body-local-owner [flag : bool]) : unit
  (while flag
    (let
      [s : String (int->string 1)]
      (let [t : String s] unit))))"))

(define (compiler-typecheck-move-while-copyable-source) : String
  "(define (while-copyable [flag : bool] [n : i64]) : i64
  (begin (while flag (let [m : i64 n] unit)) n))")

(define (compiler-typecheck-move-foreach-loop-carried-param-source) : String
  "(define (bad-foreach-loop-carried-param [n : i64] [s : String]) : unit
  (foreach ([i : i64 0 n]) (let [t : String s] unit)))")

(define (compiler-typecheck-move-foreach-loop-carried-local-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (bad-foreach-loop-carried-local [n : i64]) : unit
  (let
    [s : String (int->string 1)]
    (foreach ([i : i64 0 n]) (let [t : String s] unit))))"))

(define (compiler-typecheck-move-foreach-body-local-owner-source) : String
  (compiler-typecheck-with-alloc-string-helper-source
    "(define (foreach-body-local-owner [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [s : String (int->string 1)]
      (let [t : String s] unit))))"))

(define (compiler-typecheck-move-foreach-copyable-source) : String
  "(define (foreach-copyable [n : i64] [x : i64]) : i64
  (begin (foreach ([i : i64 0 n]) (let [y : i64 x] unit)) x))")

(define (compiler-typecheck-move-with-cleanup-owner-read-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (with-cleanup-owner-read [fd : i64]) : i64
  (with ([h (FileHandle fd) cleanup-file-handle])
    (struct-get h fd)))")

(define (compiler-typecheck-move-with-cleanup-owner-whole-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-with-cleanup-owner-whole [fd : i64]) : i64
  (with ([h (FileHandle fd) cleanup-file-handle])
    (begin
      (take-handle h)
      0)))")

(define (compiler-typecheck-move-with-cleanup-owner-field-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-with-cleanup-owner-field [fd : i64]) : i64
  (with ([h (Holder (FileHandle fd) 7) cleanup-holder])
    (begin
      (take-handle (struct-get h handle))
      0)))")

(define (compiler-typecheck-live-borrow-owner-prefix) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
")

(define (compiler-typecheck-live-borrow-holder-prefix) : String
  (string-append
    (compiler-typecheck-live-borrow-owner-prefix)
    "(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-holder [h : Holder]) : unit unit)
"))

(define (compiler-typecheck-live-borrow-many-post-scope-source) : String
  "(define (main [n : i64]) : i64
  (begin
    (let [r1 : (& n i64) (& n)]
      (let [r2 : (& n i64) (& n)] n))
    (set! n 7)
    n))")

(define (compiler-typecheck-live-borrow-owner-post-scope-source) : String
  (string-append
    (compiler-typecheck-live-borrow-owner-prefix)
    "(define (main [h : FileHandle]) : unit
  (begin
    (let [r : (& h FileHandle) (& h)] unit)
    (take-handle h)))"))

(define (compiler-typecheck-live-borrow-shadowed-local-source) : String
  "(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [n : i64 1]
      (begin
        (set! n 2)
        n))))")

(define (compiler-typecheck-live-borrow-whole-move-source) : String
  (string-append
    (compiler-typecheck-live-borrow-owner-prefix)
    "(define (bad [h : FileHandle]) : unit
  (let [r : (& h FileHandle) (& h)]
    (take-handle h)))"))

(define (compiler-typecheck-live-borrow-whole-assign-source) : String
  "(define (bad [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (begin
      (set! n 2)
      n)))")

(define (compiler-typecheck-live-borrow-aggregate-root-move-source) : String
  (string-append
    (compiler-typecheck-live-borrow-holder-prefix)
    "(define (bad [p : Holder]) : unit
  (let [r : (& p FileHandle) (& (struct-get p handle))]
    (take-holder p)))"))

(define (compiler-typecheck-live-borrow-aggregate-child-move-source) : String
  (string-append
    (compiler-typecheck-live-borrow-holder-prefix)
    "(define (bad [p : Holder]) : unit
  (let [r : (& p Holder) (& p)]
    (take-handle (struct-get p handle))))"))

(define (compiler-typecheck-live-borrow-nested-scope-source) : String
  "(define (bad [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [m : i64 1]
      (begin
        (set! n m)
        n))))")

(define (compiler-typecheck-live-borrow-begin-source) : String
  "(define (bad [n : i64]) : i64
  (begin
    (& n)
    (set! n 2)
    n))")

(define (compiler-typecheck-live-borrow-match-arm-source) : String
  "(defenum Flag (On) (Off))
(define (bad [flag : Flag] [n : i64]) : i64
  (match flag
    [On (let [r : (& n i64) (& n)] (begin (set! n 2) n))]
    [Off n]))")

(define (compiler-typecheck-live-borrow-with-arena-ok-source) : String
  "(define (main [n : i64]) : i64
  (begin
    (with-arena r
      (let [borrowed : (& n i64) (& n)] unit))
    (set! n 3)
    n))")

(define (compiler-typecheck-live-borrow-with-arena-conflict-source) : String
  "(define (bad [n : i64]) : i64
  (with-arena r
    (let [borrowed : (& n i64) (& n)]
      (begin
        (set! n 3)
        n))))")

(define (compiler-typecheck-live-borrow-resource-conflict-source) : String
  (string-append
    (compiler-typecheck-live-borrow-owner-prefix)
    "(define (bad [fd : i64]) : i64
  (with ([h (FileHandle fd) cleanup-file-handle])
    (let [borrowed : (& h FileHandle) (& h)]
      (begin
        (set! h (FileHandle 2))
        0))))"))

(define (compiler-typecheck-live-borrow-array-set-source) : String
  "(define (bad [items : (Array i64)]) : unit
  (let [borrowed : (& items i64) (& (array-ref items 0))]
    (array-set! items 0 7)))")

(define (compiler-typecheck-live-mut-borrow-post-scope-source) : String
  "(define (main [n : i64]) : i64
  (begin
    (let [r : (&mut n i64) (&mut n)] unit)
    (let [s : (&mut n i64) (&mut n)] unit)
    n))")

(define (compiler-typecheck-live-mut-borrow-array-post-scope-source) : String
  "(define (main [items : (Array i64)]) : unit
  (begin
    (let [r : (&mut items i64) (&mut (array-ref items 0))] unit)
    (let [s : (&mut items i64) (&mut (array-ref items 0))] unit)))")

(define (compiler-typecheck-live-mut-borrow-register-resident-binding-source) : String
  "(defstruct Pair (x i64) (y i64))
(define (bad) : unit
  (let
    [p : Pair (Pair 1 2)]
    (let [r : (&mut p Pair) (&mut p)] unit)))")

(define (compiler-typecheck-live-mut-borrow-function-call-source) : String
  "(define (take [r : (&mut n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (begin
    (take (&mut n))
    (set! n 3)))")

(define (compiler-typecheck-live-mut-borrow-duplicate-source) : String
  "(define (bad [items : (Array i64)]) : unit
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    (let [s : (&mut items i64) (&mut (array-ref items 0))] unit)))")

(define (compiler-typecheck-live-mut-borrow-after-immut-source) : String
  "(define (bad [items : (Array i64)]) : unit
  (let [r : (& items i64) (& (array-ref items 0))]
    (let [s : (&mut items i64) (&mut (array-ref items 0))] unit)))")

(define (compiler-typecheck-live-immut-borrow-after-mut-source) : String
  "(define (bad [items : (Array i64)]) : unit
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    (let [s : (& items i64) (& (array-ref items 0))] unit)))")

(define (compiler-typecheck-live-mut-borrow-call-duplicate-source) : String
  "(define (take2 [a : (&mut n i64)] [b : (&mut n i64)]) : unit unit)
(define (bad [n : i64]) : unit
  (take2 (&mut n) (&mut n)))")

(define (compiler-typecheck-live-mut-borrow-assign-source) : String
  "(define (bad [items : (Array i64)]) : unit
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    (array-set! items 0 2)))")

(define (compiler-typecheck-live-mut-borrow-array-set-source) : String
  "(define (bad [items : (Array i64)]) : unit
  (let [borrowed : (&mut items i64) (&mut (array-ref items 0))]
    (array-set! items 0 7)))")

(define (compiler-typecheck-live-borrow-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-live-borrow-many-post-scope-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-live-borrow-owner-post-scope-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-live-borrow-shadowed-local-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-whole-move-source)
        "typecheck: cannot move borrowed place `h`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-whole-assign-source)
        "typecheck: cannot assign to borrowed place `n`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-aggregate-root-move-source)
        "typecheck: cannot move borrowed place `p`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-aggregate-child-move-source)
        "typecheck: cannot move borrowed place `p.handle`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-nested-scope-source)
        "typecheck: cannot assign to borrowed place `n`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-begin-source)
        "typecheck: cannot assign to borrowed place `n`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-match-arm-source)
        "typecheck: cannot assign to borrowed place `n`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-live-borrow-with-arena-ok-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-with-arena-conflict-source)
        "typecheck: cannot assign to borrowed place `n`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-resource-conflict-source)
        "typecheck: cannot assign to borrowed place `h`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-borrow-array-set-source)
        "typecheck: cannot assign to borrowed place `items.#array.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-mut-borrow-post-scope-source)
        "typecheck: mutable borrow of by-value place is only supported as an immediate call argument")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-live-mut-borrow-array-post-scope-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-mut-borrow-register-resident-binding-source)
        "typecheck: mutable borrow of by-value place is only supported as an immediate call argument")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-live-mut-borrow-function-call-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-mut-borrow-duplicate-source)
        "typecheck: cannot read mutably borrowed place `items.#array.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-mut-borrow-after-immut-source)
        "typecheck: cannot mutably borrow borrowed place `items.#array.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-immut-borrow-after-mut-source)
        "typecheck: cannot read mutably borrowed place `items.#array.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-mut-borrow-call-duplicate-source)
        "typecheck: cannot read mutably borrowed place `n`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-mut-borrow-assign-source)
        "typecheck: cannot assign to borrowed place `items.#array.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-live-mut-borrow-array-set-source)
        "typecheck: cannot assign to borrowed place `items.#array.0`")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-moved-set-metrics-ok?) : bool
  (let
    [origin-a : AstExpr (AstExprVar (intern "origin-a"))]
    [origin-b : AstExpr (AstExprVar (intern "origin-b"))]
    [empty : TcMovedSet (tc-moved-empty)]
    [one : TcMovedSet (tc-moved-add empty "alpha")]
    [dupe : TcMovedSet (tc-moved-add (tc-moved-clone one) "alpha")]
    [two : TcMovedSet (tc-moved-add (tc-moved-clone dupe) "beta")]
    [removed : TcMovedSet (tc-moved-remove (tc-moved-clone two) "alpha")]
    [origin-whole : TcMovedSet
      (tc-moved-add-origin (tc-moved-empty) "origin-root" origin-a)]
    [origin-whole-id : i64
      (match (tc-moved-conflict origin-whole "origin-root")
        [(TcSomeMoveConflict key origin-id)
          (if (string-eq key "origin-root")
            origin-id
            (tc-moved-no-origin-id))]
        [TcNoMoveConflict (tc-moved-no-origin-id)])]
    [origin-whole-ok : bool (not (= origin-whole-id (tc-moved-no-origin-id)))]
    [origin-clone-ok : bool
      (match (tc-moved-conflict (tc-moved-clone origin-whole) "origin-root")
        [(TcSomeMoveConflict _ origin-id) (= origin-id origin-whole-id)]
        [TcNoMoveConflict false])]
    [partial : TcMovedSet
      (tc-moved-add-projection-path
        (tc-moved-add-projection-path
          (tc-moved-empty)
          "items"
          "items.#array.0"
          origin-a)
        "items"
        "items.#array.1"
        origin-b)]
    [partial-exact-conflict : bool
      (match (tc-moved-path-conflict partial "items.#array.0")
        [(TcSomeMoveConflict key origin-id)
          (and
            (string-eq key (tc-moved-path-key "items.#array.0"))
            (not (= origin-id (tc-moved-no-origin-id))))]
        [TcNoMoveConflict false])]
    [partial-parent-conflict : bool
      (match (tc-moved-path-conflict partial "items")
        [(TcSomeMoveConflict _ origin-id)
          (not (= origin-id (tc-moved-no-origin-id)))]
        [TcNoMoveConflict false])]
    [partial-root-conflict : bool
      (match (tc-moved-root-conflict partial "items")
        [(TcSomeMoveConflict _ origin-id)
          (not (= origin-id (tc-moved-no-origin-id)))]
        [TcNoMoveConflict false])]
    [partial-one : TcMovedSet
      (tc-moved-remove-exact-path
        (tc-moved-clone partial)
        "items"
        "items.#array.0")]
    [partial-clear : TcMovedSet
      (tc-moved-remove-exact-path
        (tc-moved-clone partial-one)
        "items"
        "items.#array.1")]
    [partial-keeps-sibling : bool
      (tc-moved-contains? partial-one (tc-moved-path-key "items.#array.1"))]
    [partial-keeps-marker : bool (tc-moved-partial? partial-one "items")]
    [partial-clears-sibling : bool
      (not
        (tc-moved-contains? partial-clear (tc-moved-path-key "items.#array.1")))]
    [partial-clears-marker : bool
      (not (tc-moved-partial? partial-clear "items"))]
    [root-path : TcMovedSet
      (tc-moved-add (tc-moved-empty) (tc-moved-path-key "shadowed"))]
    [root-path-clear : TcMovedSet
      (tc-moved-remove-root-state root-path "shadowed")]
    [root-path-clears : bool
      (not (tc-moved-contains? root-path-clear (tc-moved-path-key "shadowed")))]
    [union-left : TcMovedSet (tc-moved-add-value (tc-moved-empty) "shared" 101)]
    [union-right : TcMovedSet
      (tc-moved-add-value (tc-moved-empty) "shared" 202)]
    [union-origin-left : bool
      (match (tc-moved-conflict
        (tc-moved-union union-left union-right)
        "shared")
        [(TcSomeMoveConflict _ origin-id) (= origin-id 101)]
        [TcNoMoveConflict false])]
    (and
      (= (tc-moved-len (tc-moved-empty)) 0)
      (= (tc-moved-len dupe) 1)
      (= (tc-moved-len two) 2)
      (>= (tc-moved-capacity two) 8)
      (not (tc-moved-contains? removed "alpha"))
      origin-whole-ok
      origin-clone-ok
      partial-exact-conflict
      partial-parent-conflict
      partial-root-conflict
      partial-keeps-sibling
      partial-keeps-marker
      partial-clears-sibling
      partial-clears-marker
      root-path-clears
      union-origin-left)))

;; Returns true when use-after-move is rejected (straight-line and after a
;; branch that moves on every arm), while a single move, copyable reuse, ordinary
;; aggregate/projection sharing, one-shot owner transfers, branch/deferred body
;; isolation, and conservative repeated-loop owner moves pass.
(define (compiler-typecheck-move-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-moved-set-metrics-ok?)
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-use-after-move-source)
        "typecheck: use of moved value `s`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-move-single-move-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok? (compiler-typecheck-move-copyable-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-branch-source)
        "typecheck: use of moved value `s`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-ordinary-sharing-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-ordinary-enum-match-reuse-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-cleanup-enum-match-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-cleanup-enum-match-param-reuse-source)
        "typecheck: use of moved value `ticket`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-cleanup-enum-match-local-reuse-source)
        "typecheck: use of moved value `ticket`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-cleanup-enum-owner-payload-one-shot-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-cleanup-enum-owner-payload-repeat-source)
        "typecheck: use of moved value `h`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-cleanup-enum-payload-copyable-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-cleanup-enum-payload-shadow-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-call-ok-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-call-reuse-source)
        "typecheck: use of moved value `h`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-constructor-reuse-source)
        "typecheck: use of moved value `h`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-return-reuse-source)
        "typecheck: use of moved value `h`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-ordinary-projection-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-projection-other-field-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-projection-one-shot-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-projection-bind-other-field-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-projection-nested-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-projection-nested-siblings-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-projection-nested-repeat-source)
        "typecheck: use of moved value `p.inner.handle`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-projection-nested-root-reuse-source)
        "typecheck: use of moved value `p`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-projection-nested-parent-after-child-source)
        "typecheck: use of moved value `p.inner`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-projection-nested-child-after-parent-source)
        "typecheck: use of moved value `p.inner`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-projection-nested-set-reset-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-projection-nested-shadow-reset-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-projection-repeat-source)
        "typecheck: use of moved value `p.handle`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-projection-root-reuse-source)
        "typecheck: use of moved value `p`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-projection-key-collision-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-tuple-ref-reuse-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-tuple-ref-repeat-source)
        "typecheck: use of moved value `p.#tuple.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-tuple-ref-nested-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-tuple-ref-nested-repeat-source)
        "typecheck: use of moved value `p.#tuple.0.#tuple.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-tuple-ref-nested-sibling-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-array-ref-other-element-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-array-ref-repeat-source)
        "typecheck: use of moved value `items.#array.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-array-ref-reinit-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-array-ref-reinit-root-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-array-ref-reinit-sibling-source)
        "typecheck: use of moved value `items.#array.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-array-ref-reinit-nonliteral-source)
        "typecheck: use of moved value `items.#array.0`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-array-ref-nested-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-array-ref-nested-repeat-source)
        "typecheck: use of moved value `items.#array.0.#array.1`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-array-ref-nested-sibling-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-array-ref-nonliteral-source)
        "typecheck: cannot move owner-consuming value out of aggregate path")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-dyn-array-ref-call-source)
        "typecheck: cannot move owner-consuming value out of dynamic array element")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-dyn-array-ref-bind-source)
        "typecheck: ordinary let cannot own cleanup-required resource; use with")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-box-get-copyable-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-box-get-call-source)
        "typecheck: cannot move owner-consuming value out of box")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-box-get-bind-source)
        "typecheck: ordinary let cannot own cleanup-required resource; use with")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-box-get-return-source)
        "typecheck: cannot move owner-consuming value out of box")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-box-take-reuse-source)
        "typecheck: use of moved value `cell`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-branch-arm-isolated-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-lambda-body-discard-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-owner-lambda-capture-box-ok-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-lambda-capture-box-reuse-source)
        "typecheck: use of moved value `cell`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-lambda-capture-cleanup-reuse-source)
        "typecheck: use of moved value `h`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-owner-lambda-body-reuse-source)
        "typecheck: use of moved value `cell`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-while-loop-carried-param-source)
        "typecheck: cannot move loop-carried owner value `s`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-while-loop-carried-local-source)
        "typecheck: cannot move loop-carried owner value `s`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-while-body-local-owner-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-while-copyable-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-foreach-loop-carried-param-source)
        "typecheck: cannot move loop-carried owner value `s`")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-foreach-loop-carried-local-source)
        "typecheck: cannot move loop-carried owner value `s`")
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-foreach-body-local-owner-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-foreach-copyable-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-move-with-cleanup-owner-read-source))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-with-cleanup-owner-whole-source)
        "typecheck: cleanup owner `h` moved before with scope exit")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-move-with-cleanup-owner-field-source)
        "typecheck: cleanup owner `h` moved before with scope exit")
        unit
        (set! ok false))
      ok)))

;; --- defdispatch frontend model (#1908) ------------------------------------
(define (compiler-typecheck-defdispatch-full-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : i64]) : i64 (+ x 1))
(define (dot-avx512 [x : i64]) : i64 (+ x 2))
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-typecheck-defdispatch-scalar-only-source) : String
  "(define (id-scalar [x : i64]) : i64 x)
(defdispatch id (scalar id-scalar))
(define (main [x : i64]) : i64 (id x))")

(define (compiler-typecheck-defdispatch-no-scalar-source) : String
  "(define (dot-avx2 [x : i64]) : i64 x)
(defdispatch dot (avx2 dot-avx2))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-typecheck-defdispatch-duplicate-isa-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : i64]) : i64 x)
(define (dot-avx2b [x : i64]) : i64 x)
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx2 dot-avx2b))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-typecheck-defdispatch-unknown-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-typecheck-defdispatch-non-function-source) : String
  "(define value : i64 1)
(defdispatch dot (scalar value))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-typecheck-defdispatch-mismatch-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : bool]) : i64 0)
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-typecheck-defdispatch-self-source) : String
  "(defdispatch dot (scalar dot))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-typecheck-defdispatch-dispatch-variant-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(defdispatch dot (scalar dot-scalar))
(defdispatch other (scalar dot))
(define (main [x : i64]) : i64 (other x))")

(define (compiler-typecheck-defdispatch-export-alias-source) : String
  "(module kernels)
(define (dot-scalar [x : i64]) : i64 x)
(defdispatch dot (scalar dot-scalar))
(export (value dot))
(module app)
(import \"kernels.tl\" module kernels :as k)
(define (main [x : i64]) : i64 (k.dot x))")

(define (compiler-typecheck-defdispatch-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-defdispatch-full-source))
    (compiler-typecheck-ok? (compiler-typecheck-defdispatch-scalar-only-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-defdispatch-export-alias-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defdispatch-no-scalar-source)
      "typecheck: defdispatch requires exactly one scalar variant")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defdispatch-duplicate-isa-source)
      "typecheck: duplicate defdispatch ISA variant")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defdispatch-unknown-source)
      "typecheck: unknown defdispatch variant dot-avx2")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defdispatch-non-function-source)
      "typecheck: defdispatch variant is not a function value")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defdispatch-mismatch-source)
      "typecheck: defdispatch variant signatures must match")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defdispatch-self-source)
      "typecheck: defdispatch cannot use itself as a variant")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defdispatch-dispatch-variant-source)
      "typecheck: defdispatch variant cannot be another dispatch")))

;; --- declaration namespace / duplicate diagnostics (#1537) ------------------
;; Migrated from src/typechecker.rs namespace coverage. These flow through
;; build-compiler-symbols / build-compiler-registries during typechecking, so the
;; CI typecheck smoke exercises them. Builtin shadowing remains accepted to
;; match the Rust reference behavior from #677.
(define (compiler-typecheck-dup-function-source) : String
  "(define (foo [x : i64]) : i64 x)
(define (foo [y : i64]) : i64 y)
(define (main) : i64 0)")

(define (compiler-typecheck-define-function-collision-source) : String
  "(define foo : i64 1)
(define (foo [x : i64]) : i64 x)
(define (main) : i64 0)")

(define (compiler-typecheck-dup-struct-type-source) : String
  "(defstruct Point (x i64))
(defstruct Point (y i64))
(define (main) : i64 0)")

(define (compiler-typecheck-dup-enum-type-source) : String
  "(defenum E (A))
(defenum E (B))
(define (main) : i64 0)")

(define (compiler-typecheck-dup-extern-source) : String
  "(extern (f [arg0 : i64]) : i64)
(extern (f [arg0 : i64]) : i64)
(define (main) : i64 0)")

(define (compiler-typecheck-dup-extern-paths) : AstDeclPathList
  (ast-decl-path-cons
    "src/main.tl"
    (ast-decl-path-cons
      "src/assets.tl"
      (ast-decl-path-cons "src/main.tl" AstDeclPathNil))))

(define (compiler-typecheck-dup-extern-paths-ok?) : bool
  (match (parse-ast-source (compiler-typecheck-dup-extern-source))
    [(OkAstProgram program)
      (match (typecheck-compiler-program-with-paths
        program
        (compiler-typecheck-dup-extern-paths))
        [(ErrCompilerTypecheck diag)
          (let
            [message : String (compiler-diagnostic-message diag)]
            [duplicate-needle : String "symbols: duplicate value declaration f"]
            [main-path : String "src/main.tl"]
            [assets-path : String "src/assets.tl"]
            (and
              (string-contains (& message) (& duplicate-needle))
              (string-contains (& message) (& main-path))
              (string-contains (& message) (& assets-path))))]
        [(OkCompilerTypecheck _) false])]
    [(ErrAstProgram _) false]))

(define (compiler-typecheck-cross-module-mismatch-source) : String
  "(module left)
(define (helper [x : i64]) : i64 x)
(export (value helper))
(module main)
(import left)
(define (main) : i64 (left.helper true))")

;; Returns true when duplicate function/value, define/function collision,
;; duplicate struct and enum type names, duplicate externs, enum variants and
;; struct constructors colliding with value declarations, and a cross-module
;; wrong-argument-type call are all rejected with the expected diagnostics.
;; Builtin shadowing is asserted as accepted.
(define (compiler-typecheck-namespace-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-dup-function-source)
      "symbols: duplicate value declaration foo")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-define-function-collision-source)
      "symbols: duplicate value declaration foo")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-dup-struct-type-source)
      "symbols: duplicate type declaration Point")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-dup-enum-type-source)
      "symbols: duplicate type declaration E")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-dup-extern-source)
      "symbols: duplicate value declaration f")
    (compiler-typecheck-dup-extern-paths-ok?)
    (compiler-typecheck-error-ok?
      (compiler-typecheck-variant-function-collision-source)
      "symbols: duplicate value declaration Foo")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-variant-define-collision-source)
      "symbols: duplicate value declaration Foo")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-variant-extern-collision-source)
      "symbols: duplicate value declaration Foo")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-variant-struct-collision-source)
      "symbols: duplicate value declaration Foo")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-struct-function-collision-source)
      "symbols: duplicate value declaration Point")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-struct-define-collision-source)
      "symbols: duplicate value declaration Point")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-struct-extern-collision-source)
      "symbols: duplicate value declaration Point")
    (compiler-typecheck-ok? (compiler-typecheck-builtin-shadow-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-cross-module-mismatch-source)
      "typecheck: argument type mismatch")))

(define (compiler-typecheck-self-test-diagnostics) : unit
  (begin
    (if (compiler-typecheck-namespace-tests-ok?)
      unit
      (panic "typecheck: declaration namespace tests failed"))
    (if (compiler-typecheck-defdispatch-tests-ok?)
      unit
      (panic "typecheck: defdispatch tests failed"))
    (if (compiler-typecheck-move-tests-ok?)
      unit
      (panic "typecheck: move checker tests failed"))
    (if (compiler-typecheck-live-borrow-tests-ok?)
      unit
      (panic "typecheck: live borrow checker tests failed"))
    (if (compiler-typecheck-diagnostic-code-tests-ok?)
      unit
      (panic "typecheck: diagnostic code tests failed"))
    (if (compiler-typecheck-escape-diagnostic-tests-ok?)
      unit
      (panic "typecheck: escape diagnostic tests failed"))
    (if (compiler-typecheck-pool-exhaustion-diagnostic-ok?)
      unit
      (panic "typecheck: pool exhaustion diagnostic test failed"))
    (if (compiler-typecheck-prefix-cache-smoke-ok?)
      unit
      (panic "typecheck: prefix snapshot cache smoke test failed"))
    (if (compiler-typecheck-prefix-cache-stats-smoke-ok?)
      unit
      (panic "typecheck: prefix snapshot cache stats smoke test failed"))
    (if (compiler-typecheck-error-ok?
      (compiler-typecheck-unbound-source)
      "typecheck: unbound name missing")
      unit
      (panic "typecheck: unbound-name diagnostic test failed"))
    (if (compiler-typecheck-error-ok?
      (compiler-typecheck-bad-call-source)
      "typecheck: argument type mismatch")
      unit
      (panic "typecheck: bad-call diagnostic test failed"))
    (if (compiler-typecheck-error-ok?
      (compiler-typecheck-branch-mismatch-source)
      "typecheck: if branches must match")
      unit
      (panic "typecheck: branch mismatch diagnostic test failed"))
    unit))

(define (compiler-typecheck-self-test-models) : unit
  (begin
    (if (compiler-typecheck-aggregate-tests-ok?)
      unit
      (panic "typecheck: aggregate tests failed"))
    (if (compiler-typecheck-clone-tests-ok?)
      unit
      (panic "typecheck: clone tests failed"))
    (if (compiler-typecheck-foreach-spmd-tests-ok?)
      unit
      (panic "typecheck: foreach/spmd tests failed"))
    (if (compiler-typecheck-nominal-tests-ok?)
      unit
      (panic "typecheck: nominal tests failed"))
    (if (compiler-typecheck-abstraction-policy-tests-ok?)
      unit
      (panic "typecheck: abstraction policy tests failed"))
    (if (compiler-typecheck-region-tests-ok?)
      unit
      (panic "typecheck: region tests failed"))
    (if (compiler-typecheck-with-escape-tests-ok?)
      unit
      (panic "typecheck: with-escape tests failed"))
    (if (compiler-typecheck-in-arena-tests-ok?)
      unit
      (panic "typecheck: in-arena tests failed"))
    (if (compiler-typecheck-owner-model-tests-ok?)
      unit
      (panic "typecheck: lifetime owner model tests failed"))
    (if (compiler-typecheck-box-tests-ok?)
      unit
      (panic "typecheck: box tests failed"))
    (if (compiler-typecheck-init-tests-ok?)
      unit
      (panic "typecheck: init tests failed"))
    (if (compiler-typecheck-result-try-tests-ok?)
      unit
      (panic "typecheck: result try tests failed"))
    (if (compiler-typecheck-move-kind-tests-ok?)
      unit
      (panic "typecheck: move-kind classifier tests failed"))
    (if (compiler-typecheck-resource-with-tests-ok?)
      unit
      (panic "typecheck: resource with tests failed"))
    (if (compiler-typecheck-cleanup-struct-tests-ok?)
      unit
      (panic "typecheck: cleanup struct metadata tests failed"))
    (if (compiler-typecheck-cleanup-enum-tests-ok?)
      unit
      (panic "typecheck: cleanup enum metadata tests failed"))
    (if (compiler-typecheck-raw-pointer-tests-ok?)
      unit
      (panic "typecheck: raw pointer type tests failed"))
    (if (compiler-typecheck-extern-abi-tests-ok?)
      unit
      (panic "typecheck: extern ABI signature tests failed"))
    (if (compiler-typecheck-reference-tests-ok?)
      unit
      (panic "typecheck: reference tests failed"))
    (if (compiler-typecheck-located-ok?)
      unit
      (panic "typecheck: located diagnostic test failed"))
    (if (compiler-typecheck-quote-tests-ok?)
      unit
      (panic "typecheck: quote tests failed"))
    unit))

;; Runtime stdlib signature + shadowing coverage (#1539, migrated from
;; src/typechecker.rs). `print-string`/`print-str`/`print-error` are stdlib
;; functions that take a `String`; `xgetbv` takes an integer; `cpuid` takes
;; integers; `string-ref`/`char-at` require an integer index. A user declaration
;; may still define the same source-level name when no stdlib import brings it
;; into scope.
(define (compiler-typecheck-runtime-builtin-print-string-ok-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64 (begin (print-string \"hi\") 0))"))

(define (compiler-typecheck-runtime-builtin-print-str-ok-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64 (begin (print-str \"hi\") 0))"))

(define (compiler-typecheck-runtime-builtin-print-error-ok-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64 (begin (print-error \"hi\") 0))"))

(define (compiler-typecheck-runtime-builtin-print-region-ok-source) : String
  (compiler-typecheck-with-io-source
    (compiler-typecheck-with-alloc-string-helper-source
      "(define (main) : i64
  (let
    [s : String (int->string 42)]
    (begin
      (print-string s)
      (print-str s)
      (print-error s)
      0)))")))

(define (compiler-typecheck-runtime-builtin-xgetbv-ok-source) : String
  (compiler-typecheck-with-cpu-source
    "(define (main) : i64 (begin (xgetbv 0) 0))"))

(define (compiler-typecheck-runtime-builtin-shadow-source) : String
  "(define (print-string [x : i64]) : i64 x)
(define (main) : i64 (print-string 5))")

(define (compiler-typecheck-runtime-builtin-print-string-bad-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64 (begin (print-string 42) 0))"))

(define (compiler-typecheck-runtime-builtin-print-str-bad-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64 (begin (print-str 42) 0))"))

(define (compiler-typecheck-runtime-builtin-print-error-bad-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64 (begin (print-error 42) 0))"))

(define (compiler-typecheck-runtime-builtin-xgetbv-bad-source) : String
  (compiler-typecheck-with-cpu-source
    "(define (main) : i64 (begin (xgetbv \"x\") 0))"))

(define (compiler-typecheck-runtime-builtin-cpuid-bad-source) : String
  (compiler-typecheck-with-cpu-source
    "(define (main) : i64 (begin (cpuid \"x\" 0) 0))"))

(define (compiler-typecheck-runtime-builtin-no-import-source) : String
  "(define (main) : i64 (begin (print-string \"hi\") 0))")

(define (compiler-typecheck-runtime-stdlib-no-import-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (begin (print 1) 0))"
        "typecheck: unbound name print")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-runtime-builtin-no-import-source)
        "typecheck: unbound name print-string")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (begin (print-str \"hi\") 0))"
        "typecheck: unbound name print-str")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (begin (print-newline) 0))"
        "typecheck: unbound name print-newline")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (begin (print-bool true) 0))"
        "typecheck: unbound name print-bool")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (begin (print-char 'A') 0))"
        "typecheck: unbound name print-char")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (begin (print-float 1.5) 0))"
        "typecheck: unbound name print-float")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (begin (print-error \"hi\") 0))"
        "typecheck: unbound name print-error")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (panic \"stop\"))"
        "typecheck: unbound name panic")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        "(define (main) : i64 (error \"stop\"))"
        "typecheck: unbound name error")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-runtime-builtin-string-ref-bad-index-source) : String
  "(define (main) : i64 (string-ref \"abc\" \"x\"))")

(define (compiler-typecheck-runtime-builtin-char-at-bad-index-source) : String
  "(define (main) : i64 (char-at \"abc\" \"x\"))")

(define (compiler-typecheck-runtime-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-runtime-builtin-print-string-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-runtime-builtin-print-str-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-runtime-builtin-print-error-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-runtime-builtin-print-region-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-runtime-builtin-xgetbv-ok-source))
    (compiler-typecheck-ok? (compiler-typecheck-runtime-builtin-shadow-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-runtime-builtin-print-string-bad-source)
      "typecheck: argument type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-runtime-builtin-print-str-bad-source)
      "typecheck: argument type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-runtime-builtin-print-error-bad-source)
      "typecheck: argument type mismatch")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-runtime-builtin-xgetbv-bad-source)
      "typecheck: xgetbv index must be integer")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-runtime-builtin-cpuid-bad-source)
      "typecheck: argument type mismatch")
    (compiler-typecheck-runtime-stdlib-no-import-tests-ok?)
    (compiler-typecheck-error-ok?
      (compiler-typecheck-runtime-builtin-string-ref-bad-index-source)
      "typecheck: string index must be integer")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-runtime-builtin-char-at-bad-index-source)
      "typecheck: string index must be integer")))

(define (compiler-typecheck-panic-error-never-tests-ok?) : bool
  (let
    [ok : bool true]
    (begin
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f [s : String]) : i64 (panic s))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f [s : String]) : i64 (panic s))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f [s : String]) : i64 (error s))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f [s : String]) : i64 (error s))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f [flag : bool]) : i64 (if flag 42 (panic \"stop\")))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f [flag : bool]) : String (if flag \"ok\" (error \"stop\")))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(defenum Choice (Left) (Right))
(define (f [c : Choice]) : i64 (match c [(Left) (panic \"left\")] [(Right) 7]))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(defenum Choice (Left) (Right))
(define (f [c : Choice]) : String (match c [(Left) \"ok\"] [(Right) (error \"right\")]))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f) : unit (begin (panic \"stop\") unit))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-ok?
        (compiler-typecheck-with-io-source
          "(define (f) : unit (begin (error \"stop\")))"))
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-io-source "(define (f) : i64 (panic))")
        "typecheck: call arity mismatch: panic expected 1 argument, got 0 arguments")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-io-source
          "(define (f) : i64 (error \"a\" \"b\"))")
        "typecheck: call arity mismatch: error expected 1 argument, got 2 arguments")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-io-source "(define (f) : i64 (panic 5))")
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      (if (compiler-typecheck-error-ok?
        (compiler-typecheck-with-io-source "(define (f) : i64 (error true))")
        "typecheck: argument type mismatch")
        unit
        (set! ok false))
      ok)))

(define (compiler-typecheck-profile-no-default-tests-ok?) : bool
  (compiler-typecheck-error-ok?
    "(define (main) : i64 (profile-now-ms))"
    "typecheck: unbound name profile-now-ms"))

(define (compiler-typecheck-self-test-builtins) : unit
  (begin
    (if (compiler-typecheck-runtime-builtin-tests-ok?)
      unit
      (panic "typecheck: runtime builtin tests failed"))
    (if (compiler-typecheck-profile-no-default-tests-ok?)
      unit
      (panic "typecheck: profile helpers should require stdlib import"))
    (if (compiler-typecheck-panic-error-never-tests-ok?)
      unit
      (panic "typecheck: panic/error never-context tests failed"))
    (if (compiler-typecheck-string-builtin-tests-ok?)
      unit
      (panic "typecheck: string builtin tests failed"))
    (if (compiler-typecheck-argv-builtin-tests-ok?)
      unit
      (panic "typecheck: argv builtin tests failed"))
    (if (compiler-typecheck-lambda-tests-ok?)
      unit
      (panic "typecheck: lambda tests failed"))
    (if (compiler-typecheck-cast-tests-ok?)
      unit
      (panic "typecheck: cast tests failed"))
    (if (compiler-typecheck-comptime-tests-ok?)
      unit
      (panic "typecheck: comptime tests failed"))
    (if (compiler-typecheck-type-literal-tests-ok?)
      unit
      (panic "typecheck: type-literal tests failed"))
    (if (compiler-typecheck-io-builtin-tests-ok?)
      unit
      (panic "typecheck: io builtin tests failed"))
    (if (compiler-typecheck-reflection-tests-ok?)
      unit
      (panic "typecheck: comptime reflection tests failed"))
    (if (compiler-typecheck-layout-query-tests-ok?)
      unit
      (begin
        (panic "typecheck: layout query tests failed")
        ;; lint-allow: unreachable-code
        unit))
    (if (compiler-typecheck-defmacro-tests-ok?)
      unit
      (begin
        (panic "typecheck: defmacro tests failed")
        ;; lint-allow: unreachable-code
        unit))
    (if (compiler-typecheck-macro-expand-tests-ok?)
      unit
      (begin
        (panic "typecheck: macro expansion tests failed")
        ;; lint-allow: unreachable-code
        unit))))

(define (compiler-typecheck-self-test) : i64
  (begin
    (compiler-typecheck-self-test-basics)
    (compiler-typecheck-self-test-diagnostics)
    (compiler-typecheck-self-test-models)
    (compiler-typecheck-self-test-builtins)
    42))