;; compiler_typecheck_tests.tl - Self-tests for the compiler typechecker API.
(import stdlib.iterator)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf)
(import stdlib.io)
(import compiler_typecheck_api as tc_api)
(import compiler_typecheck_core as tc_core)
(import compiler_typecheck_core_tests as core_tests)
(import compiler_load as load)
(import compiler_load_tests as load_tests)
(import compiler_ast_types as ast)
(import compiler_ast_types_tests as ast_tests)
(import compiler_diagnostic as cdiag)
(import compiler_clone_tests as clone_tests)
(import compiler_parse_core as parser)
(import compiler_symbols as csym)
(import stdlib.arena)
(import stdlib.string)
(import sym_i64_env)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import compiler_intern_tests as intern_tests)
(import compiler_intern_state as cis)
(import compiler_owned_view as owned_view)

(define (compiler-typecheck-write-text [path : String] [contents : String]) : unit
  (io.write-file path (byte_buf.str-as-bytes (& contents))))

;; Importing the typechecker should leave large optional/cache tables empty.
;; Remaining global tables use their dedicated persistent arena; job-owned
;; tables use their compiler job's lifetime arena. Neither may retain the
;; transient arena active at the lookup that happened to initialize it. The
;; inlay collector is job-owned and is covered by its explicit isolation test.
(define (compiler-typecheck-lazy-table-storage-ok?) : bool
  (core_tests.tc-lazy-table-storage-ok?))

(define (compiler-typecheck-inlay-hint-state-isolation-ok?) : bool
  (core_tests.tc-inlay-hint-state-isolation-ok?))

(define (compiler-typecheck-inlay-hint-serial-adapters-ok?) : bool
  (core_tests.tc-inlay-hint-serial-adapters-ok?))

(define (compiler-typecheck-with-io-source [src : String]) : String
  (str_cat.str-cat
    "(extern (io.emit-int [arg0 : i64]) : unit)
(extern (io.emit-bool [arg0 : bool]) : unit)
(extern (io.emit-float [arg0 : f64]) : unit)
(extern (io.emit-char [arg0 : char]) : unit)
(extern (emit-newline) : unit)
(extern (io.emit-string [arg0 : (& arg0 str)]) : unit)
(extern (io.emit-str [arg0 : (& arg0 str)]) : unit)
(extern (io.print-error [arg0 : (& arg0 str)]) : unit)
(extern (io.panic [arg0 : (& arg0 str)]) : never)
(extern (io.error [arg0 : (& arg0 str)]) : never)
(extern (arg-count) : i64)
(extern (io.arg [arg0 : i64]) : String)
(defstruct ByteBuf
  (slots (__tl_dyn-array u8))
  (len i64))
(extern (io.read-file [arg0 : String]) : ByteBuf)
(extern (io.read-file-status [arg0 : String]) : i64)
(extern (io.write-file [arg0 : String] [arg1 : (& arg1 bytes)]) : unit)
(extern (io.write-file-status [arg0 : String] [arg1 : (& arg1 bytes)]) : i64)
(extern (io.append-file-status [arg0 : String] [arg1 : (& arg1 bytes)]) : i64)
(extern (io.file-exists? [arg0 : String]) : bool)
(extern (io.file-exists-status [arg0 : String]) : i64)
(unsafe (extern (io.file-open-status [arg0 : String] [arg1 : i64]) : i64))
(unsafe (extern (io.file-close-status [arg0 : i64]) : i64))
(unsafe (extern (io.file-read-chunk-status [arg0 : i64] [arg1 : i64]) : i64))
(unsafe (extern (io.file-write-status [arg0 : i64] [arg1 : (& arg1 bytes)]) : i64))
(unsafe (extern (io.file-flush-status [arg0 : i64]) : i64))
(unsafe (extern (io.file-read-chunk-bytes [arg0 : i64]) : ByteBuf))
(unsafe (extern (io.file-read-chunk-eof? [arg0 : i64]) : bool))
(extern (read-stdin-line) : ByteBuf)
(extern (io.read-stdin-bytes [arg0 : i64]) : ByteBuf)
(extern (stdin-eof?) : bool)
(extern (flush-stdout) : unit)
"
    src))

(define (compiler-typecheck-with-alloc-string-helper-source [src : String]) : String
  (str_cat.str-cat
    "(define (string.int->string [value : i64]) : String
  (if (= value 0) \"0\" \"1\"))
(define (string.substring [text : (& text str)] [start : i64] [len : i64]) : String
  \"slice\")
(define (string.slice [text : (& text str)] [start : i64] [len : i64]) : String
  (string.substring text start len))
(define (string.append [left : (& left str)] [right : (& right str)]) : String
  \"append\")
(define (string.concat [left : (& left str)] [right : (& right str)]) : String
  (string.append left right))
"
    src))

(define (compiler-typecheck-with-fs-source [src : String]) : String
  (compiler-typecheck-with-io-source
    (compiler-typecheck-with-alloc-string-helper-source
      (str_cat.str-cat
        "(extern (mkdir-status [arg0 : String]) : i64)
(extern (remove-file-status [arg0 : String]) : i64)
(extern (remove-dir-status [arg0 : String]) : i64)
(extern (rename-status [arg0 : String] [arg1 : String]) : i64)
(extern (read-dir-status [arg0 : String]) : i64)
(extern (read-dir [arg0 : String]) : String)
(extern (file-kind-status [arg0 : String]) : i64)
(extern (file-size-status [arg0 : String]) : i64)
(extern (file-size [arg0 : String]) : i64)
(extern (process-id) : i64)
(extern (current-dir-status) : i64)
(extern (current-dir) : String)
"
        src))))

(define (compiler-typecheck-with-cpu-source [src : String]) : String
  (str_cat.str-cat "(import stdlib.cpu)\n" src))

(define (compiler-typecheck-with-env-source [src : String]) : String
  (str_cat.str-cat
    "(define (var-exists? [name : (& name str)]) : bool true)
(define (var-value [name : (& name str)]) : String \"value\")
(define (path-separator) : String \":\")
"
    src))

(define (compiler-typecheck-with-arena-source [src : String]) : String
  (str_cat.str-cat
    "(module stdlib.arena)
(extern (tl_arena_make) : i64)
(extern (tl_arena_make_atomic) : i64)
(extern (tl_arena_current) : i64)
(extern (tl_region_mark) : i64)
(unsafe (extern (tl_arena_set [arg0 : i64]) : unit))
(unsafe (extern (tl_arena_destroy [arg0 : i64]) : unit))
(unsafe (extern (tl_region_reset [arg0 : i64]) : unit))
(defstruct Arena (handle i64))
(defstruct ArenaMark (handle i64))
(define (arena-make) : Arena (Arena (tl_arena_make)))
(define (arena-make-atomic) : Arena (Arena (tl_arena_make_atomic)))
(define (arena-current) : Arena (Arena (tl_arena_current)))
(define (arena-mark) : ArenaMark (ArenaMark (tl_region_mark)))
(define (arena-raw-handle [arena : Arena]) : i64 arena.handle)
(define (arena-mark-raw-handle [mark : ArenaMark]) : i64 mark.handle)
(unsafe (define (arena-set! [arena : Arena]) : unit (unsafe (tl_arena_set (arena-raw-handle arena)))))
(unsafe (define (arena-destroy [arena : Arena]) : unit (unsafe (tl_arena_destroy (arena-raw-handle arena)))))
(unsafe (define (arena-rewind [mark : ArenaMark]) : unit (unsafe (tl_region_reset (arena-mark-raw-handle mark)))))
"
    (compiler-typecheck-with-alloc-string-helper-source src)))

;; `want` is plain message text, or a message a typecheck builder tagged with
;; its kind; a tagged one must also match the diagnostic's code.
(define (compiler-typecheck-diagnostic-matches?
  [diag : (& diag cdiag.CompilerDiagnostic)]
  [want : String]) : bool
  (if (cdiag.compiler-diagnostic-typecheck-tagged? (& want))
    (and
      (string.eq
        (cdiag.compiler-diagnostic-code-or-empty diag)
        (cdiag.compiler-diagnostic-typecheck-tag-code (& want)))
      (string.eq
        (cdiag.compiler-diagnostic-message diag)
        (cdiag.compiler-diagnostic-untagged-message want)))
    (string.eq (cdiag.compiler-diagnostic-message diag) want)))

(define (compiler-typecheck-error-ok? [src : String] [want : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (compiler-typecheck-diagnostic-matches? (& first) want))]
    [(Ok _) false]))

(define (compiler-typecheck-error-count-ok?
  [src : String]
  [want : String]
  [want-count : i64]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Err diag)
      (let
        [diagnostics : cdiag.CompilerDiagnosticList
          (cdiag.compiler-diagnostic-list-box-shared-view diag)]
        [count : i64 diagnostics.len]
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first diagnostics)]
        (and
          (= count want-count)
          (compiler-typecheck-diagnostic-matches? (& first) want)))]
    [(Ok _) false]))

(define (compiler-typecheck-error-location-ok?
  [src : String]
  [want : String]
  [want-line : i64]
  [want-col : i64]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Err diag)
      (let
        [value : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (and
          (string.eq (cdiag.compiler-diagnostic-message value) want)
          (= (cdiag.compiler-diagnostic-line value) want-line)
          (= (cdiag.compiler-diagnostic-col value) want-col)))]
    [(Ok _) false]))

(define (compiler-typecheck-error-code-ok?
  [src : String]
  [want-code : String]
  [want-category : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (match (cdiag.compiler-diagnostic-code first)
          [(CompilerDiagnosticSomeString code)
            (if (string.eq code want-code)
              (match (cdiag.compiler-diagnostic-category first)
                [(CompilerDiagnosticSomeString category)
                  (string.eq category want-category)]
                [CompilerDiagnosticNoString false])
              false)]
          [CompilerDiagnosticNoString false]))]
    [(Ok _) false]))

(define (compiler-typecheck-secondary-count
  [labels : cdiag.CompilerDiagnosticLabelList]) : i64
  (cdiag.compiler-diagnostic-label-list-count labels))

(define (compiler-typecheck-help-present? [diag : cdiag.CompilerDiagnostic]) : bool
  (match (cdiag.compiler-diagnostic-help diag)
    [(CompilerDiagnosticSomeString _) true]
    [CompilerDiagnosticNoString false]))

(define (compiler-typecheck-error-shape-ok?
  [src : String]
  [want : String]
  [want-line : i64]
  [want-col : i64]
  [want-secondary-count : i64]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (and
          (string.eq (cdiag.compiler-diagnostic-message first) want)
          (= (cdiag.compiler-diagnostic-line first) want-line)
          (= (cdiag.compiler-diagnostic-col first) want-col)
          (=
            (compiler-typecheck-secondary-count
              (cdiag.compiler-diagnostic-secondary-spans first))
            want-secondary-count)
          (compiler-typecheck-help-present? first)))]
    [(Ok _) false]))

(define (compiler-typecheck-program-error-ok?
  [program : ast.AstProgram]
  [want : String]) : bool
  (match (tc_api.typecheck-compiler-program program)
    [(Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (string.eq (cdiag.compiler-diagnostic-message first) want))]
    [(Ok _) false]))

;; With the growing ty-node pool a compile that starts with the pool at
;; capacity grows the backing array and succeeds rather than failing closed with
;; an exhaustion diagnostic. Verify the typecheck still succeeds under that
;; pressure (and that the pool grew).
(define (compiler-typecheck-pool-exhaustion-diagnostic-ok?) : bool
  (let
    [capacity : i64 (ast_tests.ty-node-pool-capacity)]
    (ast.ty-node-pool-reset!)
    (ast.ty-node-pool-truncate! capacity)
    (let
      [result : tc_core.ResultCompilerTypecheck
        (tc_api.typecheck-compiler-source "(define (main) : i64 0)")]
      [grew : bool (> (ast_tests.ty-node-pool-capacity) capacity)]
      [ok : bool
        (match result
          [(Ok _) grew]
          [(Err _) false])]
      (ast.ty-node-pool-reset!)
      ok)))

(define (compiler-typecheck-prefix-cache-paths [entry-path : String]) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "stdlib/tc_prefix_shared.tl"
    (ast.ast-decl-root-path-cons entry-path (ast.ast-decl-path-list-new))))

(define (compiler-typecheck-prefix-cache-source-a) : String
  "(define (shared-helper [x : i64]) : i64 (+ x 1))
(define (main) : i64 (shared-helper 1))")

(define (compiler-typecheck-prefix-cache-source-b) : String
  "(define (shared-helper [x : i64]) : i64 (+ x 1))
(define (main) : i64 (shared-helper 2))")

(define (compiler-typecheck-prefix-cache-check
  [src : String]
  [entry-path : String]) : bool
  (match (parser.parse-ast-source-diagnostic
    (tc_core.tc-global-shared-view entry-path)
    src)
    [(Ok program)
      (match (tc_api.typecheck-compiler-program-with-paths
        program
        (compiler-typecheck-prefix-cache-paths entry-path))
        [(Ok _) true]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-typecheck-prefix-cache-smoke-ok?) : bool
  (let
    [ok : bool true]
    (load.compiler-load-session-cache-enable!)
    (tc_core.tc-prefix-snapshot-cache-clear!)
    (if (compiler-typecheck-prefix-cache-check
      (compiler-typecheck-prefix-cache-source-a)
      "target/tc_prefix_entry_a.tl")
      unit
      (set! ok false))
    ;; Preserve the owner generation while resetting transient file state so
    ;; this smoke exercises a real same-session prefix hit. Pool/intern reset
    ;; invalidation is covered by the explicit provenance rollover smoke.
    (tc_core.compiler-typecheck-reset-file-state!)
    (if (compiler-typecheck-prefix-cache-check
      (compiler-typecheck-prefix-cache-source-b)
      "target/tc_prefix_entry_b.tl")
      unit
      (set! ok false))
    (if (> (tc_core.tc-prefix-snapshot-cache-hit-count-value) 0)
      unit
      (set! ok false))
    (if (> (tc_core.tc-prefix-snapshot-cache-store-count-value) 0)
      unit
      (set! ok false))
    (load.compiler-load-session-cache-disable-for-test!)
    (tc_core.tc-prefix-snapshot-cache-clear!)
    (tc_api.compiler-typecheck-reset-load-session!)
    ok))

(define (compiler-typecheck-prefix-cache-stats-smoke-ok?) : bool
  (tc_core.tc-prefix-snapshot-cache-clear!)
  (tc_core.tc-prefix-snapshot-cache-note-hit!)
  (tc_core.tc-prefix-snapshot-cache-note-miss!)
  (tc_core.tc-prefix-snapshot-cache-note-store!)
  (let
    [line : String (tc_core.tc-prefix-snapshot-cache-stats-line "smoke")]
    (tc_core.tc-prefix-snapshot-cache-stats-reset!)
    (and
      (string.eq
        line
        "typecheck-prefix-cache|smoke|hits=1|misses=1|stores=1|lookups=2|hit-rate-per-mille=500")
      (string.eq
        (tc_core.tc-prefix-snapshot-cache-stats-line "reset")
        "typecheck-prefix-cache|reset|hits=0|misses=0|stores=0|lookups=0|hit-rate-per-mille=0"))))

(define (compiler-typecheck-ok-score? [src : String] [want : i64]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Ok summary) (= (tc_api.compiler-typecheck-summary-score summary) want)]
    [(Err _) false]))

(define (compiler-typecheck-ok? [src : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Ok _) true]
    [(Err _) false]))

(define (compiler-typecheck-bad-call-source) : String
  "(define (id [x : i64]) : i64 x)
(define (main) : i64 (id true))")

(define (compiler-typecheck-mismatch-detail-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-bad-call-source)
      "typecheck: call `id` argument 1 (parameter `x`) type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (let [x : i64 \"hello\"] x))"
      "typecheck: let binding `x` type mismatch: expected i64, found String")
    (compiler-typecheck-error-ok?
      "(define (main) : i64
  (let [x : i64 0] (begin (set! x true) x)))"
      "typecheck: assignment type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (ann true : i64))"
      "typecheck: annotation type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 true)"
      "typecheck: return type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (lambda () : i64 true) 0))"
      "typecheck: lambda return type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64
  (let [pair : (Tuple i64 bool) (tuple true false)] 0))"
      "typecheck: tuple element type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(defstruct Left (value i64))
(defstruct Right (value i64))
(define (take [value : Left]) : i64 value.value)
(define (main) : i64 (take (Right 1)))"
      "typecheck: call `take` argument 1 (parameter `value`) type mismatch: expected Left, found Right")))

(define (compiler-typecheck-branch-mismatch-source) : String
  "(define (main [flag : bool]) : i64
  (if flag 1 false))")

(define (compiler-typecheck-unop-diagnostic-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (neg true))"
      "typecheck: neg expects integer or float")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (neg (tuple 1 2)))"
      "typecheck: neg expects integer or float")
    (compiler-typecheck-ok? "(define (main) : i64 (neg 3))")
    (compiler-typecheck-ok? "(define (main) : f32 (neg 1.0))")
    (compiler-typecheck-ok? "(define (main) : f64 (neg 2.0))")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (not 3))"
      "typecheck: not expects bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (bit-not true))"
      "typecheck: bit-not expects integer")))

(define (compiler-typecheck-escape-with-arena-diagnostic-source) : String
  "(define (string.int->string [value : i64]) : String
  (if (= value 0) \"0\" \"1\"))
(define (main) : String
  (with-arena phase (string.int->string 42)))")

(define (compiler-typecheck-rendered-error-ok? [src : String] [want : String]) : bool
  (match (tc_api.typecheck-compiler-source (tc_core.tc-global-shared-view src))
    [(Err diag)
      (string.eq
        (cdiag.compiler-diagnostic-render-source
          (cdiag.compiler-diagnostic-list-first (deref diag))
          src)
        want)]
    [(Ok _) false]))

(define (compiler-typecheck-escape-diagnostic-tests-ok?) : bool
  (and
    (compiler-typecheck-error-shape-ok?
      "(define (main [n : i64]) : (& n i64)
  (let [x : i64 1] (& x)))"
      "typecheck: reference value would escape lexical scope"
      2
      3
      1)
    (compiler-typecheck-error-shape-ok?
      "(define (main [n : i64]) : i64
  (let
    [slot : (& n i64) (& n)]
    (let [n : i64 1] (set! slot (& n)))))"
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
      "(define (take [r : (& n i64)]) : i64 1)
(define (main [n : i64]) : (-> i64)
  (let [r : (& n i64) (& n)]
    (lambda () : i64 (take r))))"
      "typecheck: lambda cannot capture immutable reference; reference value would escape lexical scope"
      4
      5
      1)
    (compiler-typecheck-error-shape-ok?
      "(import stdlib.comptime)
(defmacro (for-each [vec : Expr] [body : Expr]) : unit
  `(let
    [idx : i64 0]
    (while (< idx (__tl-project-field-name ,vec \"len\"))
      (,body (array-ref (__tl-project-field-name ,vec \"slots\") idx))
      (set! idx (+ idx 1)))))

(defstruct Ball
  (x i64)
  (y i64))

(defstruct Vec
  (slots (__tl_dyn-array Ball))
  (len i64))

(defstruct World
  (balls Vec))

(define (draw-ball [ball : Ball]) : unit
  unit)

(define (draw-balls [world : (& a World)]) : unit
  (for-each (& world.balls) draw-ball))"
      "typecheck: cannot pass region-tagged value to function parameter; region value would escape; direct aggregate reads through a shared vector borrow are not owned values; borrow slots from a vector place or use the generated vector get helper"
      24
      13
      2)
    (compiler-typecheck-rendered-error-ok?
      "(define (take [value : (& n i64)]) : i64 0)
(define (main [n : i64]) : i64
  (let [r (& (+ n 1))] (take r)))"
      "error[E0207]: typecheck: a borrowed temporary must be a direct function-call argument
  --> :3:11
   |
 3 |   (let [r (& (+ n 1))] (take r)))
   |           ^^^^^^^^^^
  --> :3:11
   |
 3 |   (let [r (& (+ n 1))] (take r)))
   |           ^^^^^^^^^^ this borrow of a temporary is not a call argument
   = help: pass the borrow directly as a function-call argument, or bind the value to a local before borrowing it
")
    (compiler-typecheck-rendered-error-ok?
      "(define (take [value : (& n i64)]) : i64 0)
(define (main [n : i64]) : i64
  (take (+ n 1)))"
      "error[E0207]: typecheck: borrow requires a local, parameter, or aggregate place
  --> :3:9
   |
 3 |   (take (+ n 1)))
   |         ^^^^^^
  --> :3:9
   |
 3 |   (take (+ n 1)))
   |         ^^^^^^ this expression produces a temporary value, not a borrowable place
   = help: bind the value to a local before borrowing it, borrow a field or array element from a local aggregate, or pass a borrowed temporary `(& value)` directly as a call argument
")
    (compiler-typecheck-rendered-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (use [text : String]) : i64 (__tl_string_length text))
(define (main) : i64
  (with-arena phase (use (string.int->string 42))))")
      "error[E0205]: typecheck: cannot pass region-tagged value to function parameter; region value would escape
  --> :13:26
   |
13 |   (with-arena phase (use (string.int->string 42))))
   |                          ^^^^^^^^^^^^^^^^^^^^^^
  --> :13:26
   |
13 |   (with-arena phase (use (string.int->string 42))))
   |                          ^^^^^^^^^^^^^^^^^^^^^^ this argument carries an arena region that the parameter does not accept
   = help: pass an owned clone, keep the call inside the value's arena/scope, or use with-escape to clone out a supported arena result before passing it
")
    (compiler-typecheck-rendered-error-ok?
      (compiler-typecheck-escape-with-arena-diagnostic-source)
      "error[E0205]: typecheck: region-tagged value cannot escape with-arena 'phase'
  --> :4:21
   |
 4 |   (with-arena phase (string.int->string 42)))
   |                     ^^^^^^^^^^^^^^^^^^^^^^
  --> :4:3
   |
 4 |   (with-arena phase (string.int->string 42)))
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ with-arena `phase` scope resets before this value can escape
   = help: use with-escape to clone one supported result out of `phase`, or keep the value inside the with-arena scope
")))

(define (compiler-typecheck-diagnostic-code-tests-ok?) : bool
  (and
    (compiler-typecheck-error-code-ok?
      "(define (main) : i64 (+ 1))"
      (cdiag.compiler-diagnostic-code-parse)
      "parse")
    (compiler-typecheck-error-code-ok?
      (compiler-typecheck-branch-mismatch-source)
      (cdiag.compiler-diagnostic-code-typecheck-type-mismatch)
      "typecheck")))

(define (compiler-typecheck-clone-tests-ok?) : bool
  (and
    (clone_tests.clone-name-set-smoke-ok?)
    (clone_tests.clone-root-entries-smoke-ok?)
    (compiler-typecheck-ok?
      "(defstruct Holder
  (name String)
  (fixed (Array String 2))
  (items (__tl_dyn-array String))
  (pair (Tuple String String)))
(defenum StringTree
  (SLeaf String)
  (SBranch (Box StringTree) (Box StringTree)))
(define (clone-tuple [items : (__tl_dyn-array String)]) : (Tuple String (__tl_dyn-array String))
  (clone (tuple \"tuple\" items)))
(define (clone-fixed) : (Array String 2)
  (clone (array \"left\" \"right\")))
(define (clone-dyn [items : (__tl_dyn-array String)]) : (__tl_dyn-array String)
  (clone items))
(define (clone-holder [items : (__tl_dyn-array String)]) : Holder
  (clone (Holder \"holder\" (array \"x\" \"y\") items (tuple \"p\" \"q\"))))
(define (clone-tree [tree : StringTree]) : StringTree
  (clone tree))
(define (main [items : (__tl_dyn-array String)] [tree : StringTree]) : i64 0)")
    (compiler-typecheck-error-ok?
      "(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : (-> i64 i64)
  (clone inc))"
      "typecheck: clone unsupported type (-> i64 i64)")
    (compiler-typecheck-error-ok?
      "(extern (raw-make) : (MutPtr i64))
(define (main) : (MutPtr i64)
  (unsafe (clone (raw-make))))"
      "typecheck: clone unsupported type (MutPtr i64)")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : (& n i64)
  (clone (& n)))"
      "typecheck: clone unsupported type (& n i64)")
    (compiler-typecheck-error-count-ok?
      "(module hashmap.clone.values)
(defstruct RawValue (raw (Ptr i64)))
(module stdlib.hashmap.generated.first)
(import hashmap.clone.values as values)
(define (copy-first [value : values.RawValue]) : values.RawValue (clone value))
(define (copy-second [value : values.RawValue]) : values.RawValue (clone value))
(module stdlib.hashmap.generated.second)
(import hashmap.clone.values as values)
(define (copy-first [value : values.RawValue]) : values.RawValue (clone value))
(define (copy-second [value : values.RawValue]) : values.RawValue (clone value))"
      "typecheck: clone unsupported type hashmap.clone.values/RawValue at hashmap.clone.values/RawValue.raw: (Ptr i64) has no clone capability"
      2)))

(define (compiler-typecheck-foreach-control-flow-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (sink [x : i64]) : unit unit)
(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [x : i64 0]
      (begin
        (set! x 1)
        (sink x)))))")
    (compiler-typecheck-error-ok?
      "(define (sink [x : i64]) : unit unit)
(define (main [xs : (__tl_dyn-array i64)] [flag : bool] [n : i64]) : unit
  (let
    [f : (-> i64 unit) sink]
    (foreach ([i : i64 0 n])
      (let
        [x : i64 0]
        (begin
          (if flag (set! x (array-ref xs i)) unit)
          (f x))))))"
      "typecheck: foreach calls with varying arguments are not supported")
    (compiler-typecheck-error-ok?
      "(define (sink [x : i64]) : unit unit)
(define (main [xs : (__tl_dyn-array i64)] [flag : bool] [n : i64]) : unit
  (let
    [f : (-> i64 unit) sink]
    (foreach ([i : i64 0 n])
      (let
        [x : i64 0]
        (begin
          (while flag (set! x (array-ref xs i)))
          (f x))))))"
      "typecheck: foreach calls with varying arguments are not supported")
    (compiler-typecheck-error-ok?
      "(defenum Maybe (None) (Some i64))
(define (sink [x : i64]) : unit unit)
(define (main [m : Maybe] [xs : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 unit) sink]
    (foreach ([i : i64 0 n])
      (let
        [x : i64 0]
        (begin
          (match m [(Some v) (set! x (array-ref xs i))] [None unit])
          (f x))))))"
      "typecheck: foreach calls with varying arguments are not supported")))

(define (compiler-typecheck-foreach-spmd-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : unit
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [b : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (foreach ([i : i64 0 n])
      (let
        [sum : i64 (+ (array-ref a i) (array-ref b i))]
        (set! (array-ref out i) sum)))))")
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : unit
  (let
    [a : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [b : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [out : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    (foreach ([i : i64 0 n])
      (let
        [sum : f32 (+ (array-ref a i) (array-ref b i))]
        (set! (array-ref out i) sum)))))")
    (compiler-typecheck-ok?
      "(define (fill-i16 [a : (__tl_dyn-array i16)] [b : (__tl_dyn-array i16)] [out : (__tl_dyn-array i16)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))
(define (fill-u16 [a : (__tl_dyn-array u16)] [b : (__tl_dyn-array u16)] [out : (__tl_dyn-array u16)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (set! (array-ref out i) (+ (array-ref a i) (array-ref b i)))))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (if (= (array-ref xs i) 0) unit unit)))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (while (< (array-ref xs i) 0) unit)))")
    (compiler-typecheck-ok?
      "(define (sink [x : i64]) : unit unit)
(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (sink (array-ref xs i))))")
    (compiler-typecheck-error-ok?
      "(define (sink [x : i64]) : unit unit)
(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : unit
  (let
    [f : (-> i64 unit) sink]
    (foreach ([i : i64 0 n])
      (f (array-ref xs i)))))"
      "typecheck: foreach calls with varying arguments are not supported")
    (compiler-typecheck-error-ok?
      "(define (main [ss : (__tl_dyn-array String)] [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [s : String (array-ref ss i)]
      unit)))"
      "typecheck: foreach varying array lane type is not supported: String")
    (compiler-typecheck-foreach-control-flow-tests-ok?)))

(define (compiler-typecheck-return-tests-ok?) : bool
  (and
    (compiler-typecheck-ok-score?
      "(define (main [flag : bool]) : i64
  (begin
    (if flag (return 7) unit)
    42))"
      10)
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (return true))"
      "typecheck: return type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define answer : i64 (return 1))"
      "typecheck: return requires enclosing function")))

(define (compiler-typecheck-abstraction-policy-tests-ok?) : bool
  (compiler-typecheck-error-ok?
    "(define (id [x : T]) : T x)"
    (tc_core.tc-source-type-policy-message "T")))

(define (compiler-typecheck-aggregate-tests-ok?) : bool
  (and
    (compiler-typecheck-ok-score?
      "(define (id-lambda [n : i64]) : i64
  (let
    [f : (-> i64 i64) (lambda ([x : i64]) : i64 (+ x 1))]
    (f n)))
(define (main [n : i64] [s : String]) : i64
  (let
    [fixed : (Array i64 3) (array 1 2 3)]
    [t : (Tuple i64 bool) (tuple 7 true)]
    [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (set! (array-ref a 0) (cast (__tl_string_ref s 0) : i64))
      (foreach ([i : i64 0 n])
        (set! (array-ref a i) (+ (array-ref a i) 1)))
      (+ (array-length a)
         (+ (tuple-ref t 0) (+ (array-ref fixed 1) (id-lambda 3)))))))"
      20)
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (main [s : String]) : String
  (begin
    (mkdir-status s)
    (remove-file-status s)
    (remove-dir-status s)
    (rename-status s s)
    (read-dir-status s)
    (file-kind-status s)
    (file-size-status s)
    (file-size s)
    (process-id)
    (current-dir-status)
    (__tl_string_length (current-dir))
    (string.append (read-dir s)
      (string.append (string.substring s 0 (__tl_string_length s))
                    (string.int->string (__tl_string_to_int \"7\"))))))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (main) : i64
  (begin
    (flush-stdout)
    (if (stdin-eof?)
        (let [buffer : ByteBuf (read-stdin-line)] buffer.len)
        (let [buffer : ByteBuf (io.read-stdin-bytes 3)] buffer.len))))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-env-source
        "(define (main [name : String]) : String
  (if (var-exists? name)
    (var-value name)
    (path-separator)))"))
    (compiler-typecheck-error-ok?
      "(define (main [name : String]) : String
  (var-value name))"
      "typecheck: unbound name var-value")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (tuple-ref (tuple 1 true) 2))"
      "typecheck: tuple index out of bounds")
    (compiler-typecheck-error-ok?
      "(define bad : (Array i64 2) (array 1 true))"
      "typecheck: array elements must have same type: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : char (__tl_string_ref \"hi\" true))"
      "typecheck: call `__tl_string_ref` argument 2 type mismatch: expected integer, found bool")
    (compiler-typecheck-ok-score?
      "(define (string.string-ref [a : i64] [b : i64]) : i64 (+ a b))
(define (string.char-at [a : i64] [b : i64]) : i64 (* a b))
(define (main) : i64 (+ (string.string-ref 10 7) (string.char-at 3 4)))"
      30)
    (compiler-typecheck-ok-score?
      "(define (is-digit [c : char]) : bool
  (if (>= c '0') (<= c '9') false))
(define (main [c : char]) : bool (is-digit c))"
      20)
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (main [flag : bool]) : i64
  (if flag 42 (io.panic \"stop\")))"))
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : unit
  (foreach ([i : i64 0 n]) i))"
      "typecheck: foreach body must be unit: expected unit, found i64")
    (compiler-typecheck-error-ok?
      "(define (main) : (-> i64 i64)
  (lambda ([x : i64]) : i64 true))"
      "typecheck: lambda return type mismatch: expected i64, found bool")
    (compiler-typecheck-return-tests-ok?)))

(define (compiler-typecheck-generated-notes-ok?
  [notes : cdiag.CompilerDiagnosticNoteList]
  [want-key : String]
  [want-context : String]) : bool
  (and
    (= (cdiag.compiler-diagnostic-note-list-count notes) 2)
    (string.eq
      (cdiag.compiler-diagnostic-note-list-get notes 0)
      (str_cat.str-cat "generated identity: " want-key))
    (string.eq (cdiag.compiler-diagnostic-note-list-get notes 1) want-context)))

(define (compiler-typecheck-generated-fallback-diagnostic-ok?) : bool
  (let
    [generated-name-id : i64 (tc_core.tc-generated-name-id "GeneratedStruct")]
    [meta : ast.AstGeneratedDeclMeta
      (Some
        "policy-family"
        "GeneratedStruct"
        (ast.ast-expr-list-new)
        "policy-key")]
    [decl : ast.AstDecl
      (ast.ast-decl-comptime-decl-with-meta
        meta
        (ast.ast-decl-def-struct-id
          generated-name-id
          (Default)
          (No)
          (ast.ast-field-def-list-new)))]
    [diag : cdiag.CompilerDiagnostic
      (tc_core.tc-decl-diag
        (ast.ast-node-pool-active-expr-segment-bases)
        decl
        "typecheck: policy fallback")]
    [message-ok : bool
      (string.eq
        (cdiag.compiler-diagnostic-message diag)
        "typecheck: policy fallback")]
    [path-ok : bool (string.eq (cdiag.compiler-diagnostic-path diag) "")]
    [line-ok : bool (= (cdiag.compiler-diagnostic-line diag) 1)]
    [col-ok : bool (= (cdiag.compiler-diagnostic-col diag) 1)]
    [notes-ok : bool
      (compiler-typecheck-generated-notes-ok?
        (cdiag.compiler-diagnostic-notes diag)
        "policy-key"
        "generated declaration: GeneratedStruct from policy-family")]
    (and message-ok path-ok line-ok col-ok notes-ok)))

(define (compiler-typecheck-unknown-variant-source) : String
  "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (match m [(Other) 1] [_ 0]))")

(define (compiler-typecheck-unknown-field-source) : String
  "(defstruct Point (x i64) (y i64))
(define (main [p : Point]) : i64
  p.z)")

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
  (tail u16))
(defstruct WideC
  (:repr c)
  (f0 u8)
  (f1 u16)
  (f2 u32)
  (f3 i64)
  (f4 bool)
  (f5 u8)
  (f6 u16)
  (f7 u32)
  (f8 Inner)
  (f9 i64)
  (f10 u8)
  (f11 u16))")

(define (compiler-typecheck-repr-c-f32-source) : String
  "(defstruct Vec2
  (:repr c)
  (x f32)
  (y f32)
  (tag i64))
(define (main) : f32
  (let
    [v : Vec2 (Vec2 1.5 2.5 7)]
    v.x))")

(define (compiler-typecheck-fixture-nominal-id
  [program : (& program ast.AstProgram)]
  [name : String]) : i64
  (let
    [program : ast.AstProgram
      (owned_view.compiler-owned-reference-shared-view program)]
    (match program
      [(Program decls-box)
        (let
          [decls : ast.AstDeclList
            (ast.ast-decl-list-box-shared-view decls-box)]
          [index : i64 0]
          [name-id : i64 -1]
          (while (and (< name-id 0) (< index decls.len))
            (let
              [decl : ast.AstDecl
                (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback))]
              (match decl
                [(DefStruct decl-meta candidate _ _ _)
                  (if (string.eq (tc_core.tc-env-key-name-text candidate) name)
                    (set! name-id candidate)
                    unit)]
                [(DefStructLifetimes decl-meta candidate _ _ _ _)
                  (if (string.eq (tc_core.tc-env-key-name-text candidate) name)
                    (set! name-id candidate)
                    unit)]
                [(DefEnum decl-meta candidate _ _)
                  (if (string.eq (tc_core.tc-env-key-name-text candidate) name)
                    (set! name-id candidate)
                    unit)]
                [(DefEnumLifetimes decl-meta candidate _ _ _)
                  (if (string.eq (tc_core.tc-env-key-name-text candidate) name)
                    (set! name-id candidate)
                    unit)]
                [_ unit])
              (+= index 1)))
          name-id)])))

(define (compiler-typecheck-repr-c-layout-ok?) : bool
  (tc_core.tc-agg-caches-reset!)
  (match (parser.parse-ast-source (compiler-typecheck-repr-c-layout-source))
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    (ast.ast-global-shared-view program)
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program "Packet"))
                  [(Ok packet)
                    (match (tc_core.tc-inline-aggregate-layout-for-id
                      ctx
                      (compiler-typecheck-fixture-nominal-id program "Outer"))
                      [(Ok outer)
                        (match (tc_core.tc-inline-aggregate-layout-for-id
                          ctx
                          (compiler-typecheck-fixture-nominal-id
                            program
                            "WideC"))
                          [(Ok wide)
                            (let
                              [wide-fields : tc_core.TcInlineFieldLayoutList
                                (core_tests.tc-inline-layout-fields
                                  (tc_core.tc-global-shared-view wide))]
                              (and
                                (=
                                  (tc_core.tc-inline-aggregate-layout-size
                                    (tc_core.tc-global-shared-view packet))
                                  24)
                                (=
                                  (tc_core.tc-inline-aggregate-layout-align
                                    (tc_core.tc-global-shared-view packet))
                                  8)
                                (=
                                  (core_tests.tc-inline-layout-field-offset
                                    (tc_core.tc-global-shared-view packet)
                                    "tag")
                                  0)
                                (=
                                  (core_tests.tc-inline-layout-field-offset
                                    (tc_core.tc-global-shared-view packet)
                                    "count")
                                  8)
                                (=
                                  (core_tests.tc-inline-layout-field-offset
                                    packet
                                    "flag")
                                  16)
                                (=
                                  (tc_core.tc-inline-aggregate-layout-size
                                    (tc_core.tc-global-shared-view outer))
                                  16)
                                (=
                                  (tc_core.tc-inline-aggregate-layout-align
                                    (tc_core.tc-global-shared-view outer))
                                  4)
                                (=
                                  (core_tests.tc-inline-layout-field-offset
                                    (tc_core.tc-global-shared-view outer)
                                    "inner")
                                  4)
                                (=
                                  (core_tests.tc-inline-layout-field-offset
                                    outer
                                    "tail")
                                  12)
                                (=
                                  (tc_core.tc-inline-aggregate-layout-size
                                    (tc_core.tc-global-shared-view wide))
                                  48)
                                (=
                                  (tc_core.tc-inline-aggregate-layout-align
                                    wide)
                                  8)
                                (=
                                  (tc_core.tc-inline-field-layout-list-count
                                    (& wide-fields))
                                  12)
                                (=
                                  (array-length
                                    (__tl-project-field wide-fields slots))
                                  12)
                                (=
                                  (core_tests.tc-inline-field-list-offset
                                    (tc_core.tc-global-shared-view wide-fields)
                                    "f0")
                                  0)
                                (=
                                  (core_tests.tc-inline-field-list-offset
                                    (tc_core.tc-global-shared-view wide-fields)
                                    "f8")
                                  24)
                                (=
                                  (core_tests.tc-inline-field-list-offset
                                    wide-fields
                                    "f11")
                                  42)))]
                          [(Err _) false])]
                      [(Err _) false])]
                  [(Err _) false]))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-typecheck-repr-c-f32-layout-ok?) : bool
  (tc_core.tc-agg-caches-reset!)
  (match (parser.parse-ast-source (compiler-typecheck-repr-c-f32-source))
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    (ast.ast-global-shared-view program)
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program "Vec2"))
                  [(Ok layout)
                    (and
                      (=
                        (tc_core.tc-inline-aggregate-layout-size
                          (tc_core.tc-global-shared-view layout))
                        16)
                      (=
                        (tc_core.tc-inline-aggregate-layout-align
                          (tc_core.tc-global-shared-view layout))
                        8)
                      (=
                        (core_tests.tc-inline-layout-field-offset
                          (tc_core.tc-global-shared-view layout)
                          "x")
                        0)
                      (=
                        (core_tests.tc-inline-layout-field-offset
                          (tc_core.tc-global-shared-view layout)
                          "y")
                        4)
                      (=
                        (core_tests.tc-inline-layout-field-offset layout "tag")
                        8))]
                  [(Err _) false]))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-typecheck-repr-c-layout-error-ok?
  [src : String]
  [name : String]
  [want : String]) : bool
  (tc_core.tc-agg-caches-reset!)
  (match (parser.parse-ast-source src)
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    (ast.ast-global-shared-view program)
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program name))
                  [(Ok _) false]
                  [(Err message) (string.eq message want)]))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-typecheck-repr-c-mixed-layout-ok?) : bool
  (tc_core.tc-agg-caches-reset!)
  (match (parser.parse-ast-source
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
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    (ast.ast-global-shared-view program)
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program "Mixed"))
                  [(Ok layout)
                    (and
                      (=
                        (tc_core.tc-inline-aggregate-layout-size
                          (tc_core.tc-global-shared-view layout))
                        48)
                      (=
                        (tc_core.tc-inline-aggregate-layout-align
                          (tc_core.tc-global-shared-view layout))
                        8)
                      (=
                        (core_tests.tc-inline-layout-field-offset
                          (tc_core.tc-global-shared-view layout)
                          "lead")
                        0)
                      (=
                        (core_tests.tc-inline-layout-field-offset
                          (tc_core.tc-global-shared-view layout)
                          "point")
                        8)
                      (=
                        (core_tests.tc-inline-layout-field-offset
                          (tc_core.tc-global-shared-view layout)
                          "tag")
                        24)
                      (=
                        (core_tests.tc-inline-layout-field-offset layout "tail")
                        40))]
                  [(Err _) false]))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

;; Explicit `(:align N)` layout: the one inline aggregate layout behind
;; `size-of`/`align-of`/`offset-of` and field addresses gives the C11
;; `_Alignas` result (struct size 16, alignment 8, `data` at 8).
(define (compiler-typecheck-repr-c-aligned-layout-source) : String
  "(defstruct Frame
  (:repr c)
  (id u32)
  (len u8)
  (data (Array u8 8) (:align 8)))
(defstruct Prefix
  (:align 8)
  (:repr c)
  (kind u8)
  (schedule u8 (:align 8)))
(defstruct Holder
  (:repr c)
  (tag u8)
  (inner Prefix)
  (items (Array Prefix 2))
  (tail u16))")

(define (compiler-typecheck-aligned-pair-ok?
  [ctx : tc_core.TcContext]
  [program : ast.AstProgram]
  [name : String]
  [want-size : i64]
  [want-align : i64]
  [field : String]
  [want-offset : i64]) : bool
  (let
    [name-id : i64
      (compiler-typecheck-fixture-nominal-id
        program
        (tc_core.tc-global-shared-view name))]
    (compiler-typecheck-aligned-pair-id-ok?
      ctx
      name-id
      want-size
      want-align
      field
      want-offset)))

(define (compiler-typecheck-aligned-pair-id-ok?
  [ctx : tc_core.TcContext]
  [name-id : i64]
  [want-size : i64]
  [want-align : i64]
  [field : String]
  [want-offset : i64]) : bool
  (match (tc_core.tc-inline-aggregate-layout-for-id ctx name-id)
    [(Ok layout)
      (and
        (=
          (tc_core.tc-inline-aggregate-layout-size
            (tc_core.tc-global-shared-view layout))
          want-size)
        (=
          (tc_core.tc-inline-aggregate-layout-align
            (tc_core.tc-global-shared-view layout))
          want-align)
        (= (core_tests.tc-inline-layout-field-offset layout field) want-offset))]
    [(Err _) false]))

(define (compiler-typecheck-repr-c-aligned-layout-ok?) : bool
  (tc_core.tc-agg-caches-reset!)
  (match (parser.parse-ast-source
    (compiler-typecheck-repr-c-aligned-layout-source))
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    (ast.ast-global-shared-view program)
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (and
                  (compiler-typecheck-aligned-pair-ok?
                    ctx
                    (ast.ast-global-shared-view program)
                    "Frame"
                    16
                    8
                    "data"
                    8)
                  (compiler-typecheck-aligned-pair-ok?
                    ctx
                    (ast.ast-global-shared-view program)
                    "Prefix"
                    16
                    8
                    "schedule"
                    8)
                  ;; Nested and arrayed aligned structs propagate 8: the
                  ;; array starts at 24 with a 16-byte stride.
                  (compiler-typecheck-aligned-pair-ok?
                    ctx
                    (ast.ast-global-shared-view program)
                    "Holder"
                    64
                    8
                    "tail"
                    56)
                  (compiler-typecheck-aligned-pair-ok?
                    ctx
                    (ast.ast-global-shared-view program)
                    "Holder"
                    64
                    8
                    "items"
                    24)))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-typecheck-repr-c-align-errors-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-aligned-layout-source))
    (compiler-typecheck-ok?
      "(defstruct Same
  (:repr c)
  (:align 8)
  (x i64 (:align 8)))")
    (compiler-typecheck-error-ok?
      "(defstruct Weak
  (:repr c)
  (x i64 (:align 4)))"
      "typecheck: repr c struct Weak field x declares (:align 4) below its type's natural alignment 8")
    (compiler-typecheck-error-ok?
      "(defstruct Weak
  (:repr c)
  (:align 4)
  (x i64))"
      "typecheck: repr c struct Weak declares (:align 4) below the alignment its fields require, 8")
    ;; A raised field alignment counts toward the struct's requirement.
    (compiler-typecheck-error-ok?
      "(defstruct Weak
  (:repr c)
  (:align 4)
  (x u8 (:align 8)))"
      "typecheck: repr c struct Weak declares (:align 4) below the alignment its fields require, 8")
    (compiler-typecheck-error-ok?
      "(defstruct Inner
  (:repr c)
  (:align 8)
  (x u8))
(defstruct Weak
  (:repr c)
  (inner Inner (:align 4)))"
      "typecheck: repr c struct Weak field inner declares (:align 4) below its type's natural alignment 8")
    (compiler-typecheck-error-ok?
      "(defstruct Empty
  (:repr c)
  (:align 8)
  (x unit))"
      "typecheck: repr c struct Empty declares (:align 8) but its fields occupy 0 bytes")
    (compiler-typecheck-error-ok?
      "(defstruct Wide
  (:repr c)
  (:align 16)
  (x i64))"
      "typecheck: repr c struct Wide declares (:align 16); storage cannot yet place values aligned above 8")
    (compiler-typecheck-error-ok?
      "(defstruct Wide
  (:repr c)
  (x u8 (:align 32)))"
      "typecheck: repr c struct Wide field x declares (:align 32); storage cannot yet place values aligned above 8")
    (compiler-typecheck-error-location-ok?
      "(define (f) : i64 1)
(defstruct Weak
  (:repr c)
  (x i64 (:align 4)))"
      "typecheck: repr c struct Weak field x declares (:align 4) below its type's natural alignment 8"
      2
      1)))

(define (compiler-typecheck-repr-c-tests-ok?) : bool
  (and
    (compiler-typecheck-repr-c-aligned-layout-ok?)
    (compiler-typecheck-repr-c-align-errors-ok?)
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-layout-source))
    (compiler-typecheck-repr-c-layout-ok?)
    (compiler-typecheck-ok? (compiler-typecheck-repr-c-f32-source))
    (compiler-typecheck-repr-c-f32-layout-ok?)
    (compiler-typecheck-ok? "(defstruct Bad
  (:repr c)
  (s String))")
    (compiler-typecheck-ok?
      "(defstruct Inner (x i64))
(defstruct Bad
  (:repr c)
  (inner Inner))")
    ;; A repr-c struct gets the same finite-layout check as any struct.
    (compiler-typecheck-error-ok?
      "(defstruct Node
  (:repr c)
  (next Node))"
      "typecheck: inline aggregate layout cycle Node -> Node; insert (Box Node) at the recursive edge")
    (compiler-typecheck-repr-c-layout-error-ok?
      "(defstruct A
  (:repr c)
  (b B))
(defstruct B
  (:repr c)
  (a A))"
      "A"
      "typecheck: inline aggregate layout cycle A -> B -> A; insert (Box A) at the recursive edge")
    (compiler-typecheck-repr-c-layout-error-ok?
      "(defstruct Middle
  (back CRoot))
(defstruct CRoot
  (:repr c)
  (tag u8)
  (middle Middle))"
      "CRoot"
      "typecheck: inline aggregate layout cycle CRoot -> Middle -> CRoot; insert (Box CRoot) at the recursive edge")
    (compiler-typecheck-repr-c-mixed-layout-ok?)))

(define (compiler-typecheck-inline-layout-result [src : String] [name : String]) : tc_core.ResultTcUnit
  (let
    [program (try (parser.parse-ast-source src))]
    [symbols (try (csym.build-compiler-symbols program))]
    [registries (try (csym.build-compiler-registries program))]
    [ctx : tc_core.TcContext
      (tc_core.tc-context-new
        (ast.ast-global-shared-view program)
        symbols
        registries
        ""
        cbi.compiler-builtin-id-fix-empty
        (ast.ast-node-pool-context-capture-active))]
    (tc_core.tc-inline-aggregate-layout-finite-ok
      ctx
      (tc_core.tc-global-shared-view name)
      (compiler-typecheck-fixture-nominal-id program name))))

(define (compiler-typecheck-inline-layout-ok? [src : String] [name : String]) : bool
  (match (compiler-typecheck-inline-layout-result src name)
    [(Ok) true]
    [(Err _) false]))

(define (compiler-typecheck-inline-layout-size-ok?
  [src : String]
  [name : String]
  [want : i64]) : bool
  (match (parser.parse-ast-source src)
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    (ast.ast-global-shared-view program)
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program name))
                  [(Ok layout)
                    (= (tc_core.tc-inline-aggregate-layout-size layout) want)]
                  [(Err _) false]))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-typecheck-inline-layout-error-ok?
  [src : String]
  [name : String]
  [want : String]) : bool
  (match (compiler-typecheck-inline-layout-result src name)
    [(Err message) (string.eq message want)]
    [(Ok) false]))

(define (compiler-typecheck-inline-field-id-at
  [fields : (& fields tc_core.TcInlineFieldLayoutList)]
  [index : i64]) : i64
  (if (or
    (< index 0)
    (>= index (tc_core.tc-inline-field-layout-list-count fields)))
    -1
    (match (tc_core.tc-inline-field-layout-list-ref fields index)
      [(Field name-id _ _) name-id])))

(define (compiler-typecheck-inline-variant-id-at
  [variants : (& variants tc_core.TcInlineVariantLayoutList)]
  [index : i64]) : i64
  (if (or
    (< index 0)
    (>= index (tc_core.tc-inline-variant-layout-list-count variants)))
    -1
    (match (tc_core.tc-inline-variant-layout-list-ref variants index)
      [(Variant name-id _ _ _) name-id])))

;; The retained layout builders allocate in their cache-owned arena but must
;; restore the caller's active arena after each allocation. Exercise all three
;; builder families directly, including cache-owner reuse and reset.
(define (compiler-typecheck-inline-layout-storage-arena-ok?) : bool
  (let
    [job-state : tc_core.TcJobState (tc_core.tc-serial-job-state)]
    [state : tc_core.TcAggLayoutCacheState
      (tc_core.tc-job-state-agg-layout-cache job-state)]
    (tc_core.tc-agg-caches-reset-for-job! job-state)
    (tc_core.tc-agg-layout-cache-table-storage-ensure-for-state! state)
    (tc_core.tc-agg-layout-cache-storage-reset-for-state! state)
    (let
      [home : i64 (arena.raw-handle (arena.current))]
      [fields : tc_core.TcInlineFieldLayoutList
        (tc_core.tc-inline-field-layout-list-with-count-for-state state 4)]
      [storage : i64
        (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state state)]
      [state-storage : i64
        (arena.raw-handle
          (__tl-project-field
            (tc_core.tc-agg-layout-cache-state-data state)
            agg-layout-storage-owner))]
      [after-fields : i64 (arena.raw-handle (arena.current))]
      [payloads : tc_core.TcInlinePayloadLayoutList
        (tc_core.tc-inline-payload-layout-list-with-count-for-state state 3)]
      [after-payloads : i64 (arena.raw-handle (arena.current))]
      [variants : tc_core.TcInlineVariantLayoutList
        (tc_core.tc-inline-variant-layout-list-with-count-for-state state 2)]
      [after-variants : i64 (arena.raw-handle (arena.current))]
      [_publish : unit
        (tc_core.tc-agg-layout-cache-store-for-state!
          state
          0
          4242
          (Struct 8 8 (tc_core.tc-global-shared-view fields)))]
      [ok : bool
        (and
          (> storage 0)
          (= storage state-storage)
          (=
            storage
            (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state
              state))
          (=
            (array-length
              (__tl-project-field
                (tc_core.tc-agg-layout-cache-state-data state)
                agg-layout-cache))
            tc_core.tc-agg-layout-cache-capacity)
          (not (core_tests.tc-agg-layout-cache-slot-empty-for-state? state 0))
          (= home after-fields)
          (= home after-payloads)
          (= home after-variants)
          (= (tc_core.tc-inline-field-layout-list-count fields) 4)
          (= (tc_core.tc-inline-payload-layout-list-count payloads) 3)
          (= (tc_core.tc-inline-variant-layout-list-count variants) 2))]
      (tc_core.tc-agg-layout-cache-storage-reset-for-state! state)
      (tc_core.tc-agg-caches-reset-for-job! job-state)
      (and
        ok
        (= (arena.raw-handle (arena.current)) home)
        (=
          (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state
            state)
          0)
        (=
          (array-length
            (__tl-project-field
              (tc_core.tc-agg-layout-cache-state-data state)
              agg-layout-cache))
          tc_core.tc-agg-layout-cache-capacity)
        (core_tests.tc-agg-layout-cache-slot-empty-for-state? state 0)
        (=
          (arena.raw-handle
            (__tl-project-field
              (tc_core.tc-agg-layout-cache-state-data state)
              agg-layout-storage-owner))
          0)))))

;; Complete aggregate layouts and their retained payload arrays belong to the
;; explicit compiler job. Reset and destroy each payload owner while the other
;; job remains populated, then reuse the first job to prove the swap is local.
(define (compiler-typecheck-inline-layout-state-isolation-ok?) : bool
  (let
    [job-a : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [job-b : tc_core.TcJobState (tc_core.tc-job-state-new)]
    [state-a : tc_core.TcAggLayoutCacheState
      (tc_core.tc-job-state-agg-layout-cache job-a)]
    [state-b : tc_core.TcAggLayoutCacheState
      (tc_core.tc-job-state-agg-layout-cache job-b)]
    [_table-a : unit
      (tc_core.tc-agg-layout-cache-table-storage-ensure-for-state! state-a)]
    [_table-b : unit
      (tc_core.tc-agg-layout-cache-table-storage-ensure-for-state! state-b)]
    [_clear-a : unit
      (tc_core.tc-agg-layout-cache-storage-reset-for-state! state-a)]
    [_clear-b : unit
      (tc_core.tc-agg-layout-cache-storage-reset-for-state! state-b)]
    [_bind-a : unit
      (tc_core.tc-agg-layout-cache-ensure-for-state! state-a 101 3)]
    [_bind-b : unit
      (tc_core.tc-agg-layout-cache-ensure-for-state! state-b 202 7)]
    [fields-a : tc_core.TcInlineFieldLayoutList
      (tc_core.tc-inline-field-layout-list-with-count-for-state state-a 2)]
    [fields-b : tc_core.TcInlineFieldLayoutList
      (tc_core.tc-inline-field-layout-list-with-count-for-state state-b 3)]
    [_field-a : unit
      (tc_core.tc-inline-field-layout-list-set!
        (tc_core.tc-global-shared-view fields-a)
        0
        (Field 1101 (I64) 0))]
    [_field-b : unit
      (tc_core.tc-inline-field-layout-list-set!
        (tc_core.tc-global-shared-view fields-b)
        0
        (Field 2202 (U32) 0))]
    [_publish-a : unit
      (tc_core.tc-agg-layout-cache-store-for-state!
        state-a
        0
        101
        (Struct 16 8 (tc_core.tc-global-shared-view fields-a)))]
    [_publish-b : unit
      (tc_core.tc-agg-layout-cache-store-for-state!
        state-b
        0
        202
        (Struct 12 4 (tc_core.tc-global-shared-view fields-b)))]
    [storage-a : i64
      (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state state-a)]
    [storage-b : i64
      (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state state-b)]
    [initially-isolated? : bool
      (and
        (> storage-a 0)
        (> storage-b 0)
        (not (= storage-a storage-b))
        (not (core_tests.tc-agg-layout-cache-slot-empty-for-state? state-a 0))
        (not (core_tests.tc-agg-layout-cache-slot-empty-for-state? state-b 0))
        (= (compiler-typecheck-inline-field-id-at fields-a 0) 1101)
        (= (compiler-typecheck-inline-field-id-at fields-b 0) 2202)
        (=
          (__tl-project-field
            (tc_core.tc-agg-layout-cache-state-data state-a)
            intern-table-id)
          101)
        (=
          (__tl-project-field
            (tc_core.tc-agg-layout-cache-state-data state-b)
            intern-generation)
          7))]
    (tc_core.tc-agg-layout-cache-storage-reset-for-state! state-a)
    (let
      [b-after-a-destroy? : bool
        (and
          (core_tests.tc-agg-layout-cache-slot-empty-for-state? state-a 0)
          (not (core_tests.tc-agg-layout-cache-slot-empty-for-state? state-b 0))
          (=
            (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state
              state-b)
            storage-b)
          (= (compiler-typecheck-inline-field-id-at fields-b 0) 2202))]
      [reused-a : tc_core.TcInlineFieldLayoutList
        (tc_core.tc-inline-field-layout-list-with-count-for-state state-a 1)]
      [reused-storage-a : i64
        (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state
          state-a)]
      [_reuse-field : unit
        (tc_core.tc-inline-field-layout-list-set!
          (tc_core.tc-global-shared-view reused-a)
          0
          (Field 3303 (U64) 0))]
      [_reuse-publish : unit
        (tc_core.tc-agg-layout-cache-store-for-state!
          state-a
          0
          303
          (Struct 8 8 (tc_core.tc-global-shared-view reused-a)))]
      (tc_core.tc-agg-layout-cache-storage-reset-for-state! state-b)
      (let
        [a-after-b-destroy? : bool
          (and
            (> reused-storage-a 0)
            (not
              (core_tests.tc-agg-layout-cache-slot-empty-for-state? state-a 0))
            (core_tests.tc-agg-layout-cache-slot-empty-for-state? state-b 0)
            (= (compiler-typecheck-inline-field-id-at reused-a 0) 3303))]
        (tc_core.tc-agg-layout-cache-storage-reset-for-state! state-a)
        (and
          initially-isolated?
          b-after-a-destroy?
          a-after-b-destroy?
          (core_tests.tc-agg-layout-cache-slot-empty-for-state? state-a 0)
          (=
            (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state
              state-a)
            0)
          (=
            (tc_core.tc-agg-layout-cache-storage-arena-handle-value-for-state
              state-b)
            0))))))

(define (compiler-typecheck-inline-layout-query-ok?) : bool
  (match (parser.parse-ast-source
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
(defstruct InlineInner
  (a u8)
  (b i64))
(defstruct WidePacket
  (f0 u8)
  (f1 u16)
  (f2 u32)
  (f3 i64)
  (f4 bool)
  (f5 u8)
  (f6 u16)
  (f7 u32)
  (f8 InlineInner)
  (f9 i64)
  (f10 u8)
  (f11 u16))
(defenum WideChoice
  (V0)
  (V1)
  (V2)
  (V3)
  (V4)
  (V5)
  (V6)
  (V7)
  (V8)
  (V9)
  (V10)
  (V11 u8 i64 u16))
(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    (ast.ast-global-shared-view program)
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                [ok : bool true]
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program "InlinePacket"))
                  [(Ok layout)
                    (let
                      [small-id : i64
                        (match (tc_core.tc-global-shared-view layout)
                          [(Struct _ _ fields)
                            (compiler-typecheck-inline-field-id-at fields 3)]
                          [_ -1])]
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-size
                          (tc_core.tc-global-shared-view layout))
                        24)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-align
                          (tc_core.tc-global-shared-view layout))
                        8)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-field-offset-id
                          (tc_core.tc-global-shared-view layout)
                          cbi.compiler-builtin-id-fix-tag)
                        0)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-field-offset-id
                          (tc_core.tc-global-shared-view layout)
                          cbi.compiler-builtin-id-fix-count)
                        8)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-field-offset-id
                          (tc_core.tc-global-shared-view layout)
                          cbi.compiler-builtin-id-fix-flag)
                        16)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-field-offset-id
                          layout
                          small-id)
                        18)
                        unit
                        (set! ok false)))]
                  [(Err _) (set! ok false)])
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program "InlineChoice"))
                  [(Ok layout)
                    (let
                      [empty-id : i64
                        (match (tc_core.tc-global-shared-view layout)
                          [(Enum _ _ variants)
                            (compiler-typecheck-inline-variant-id-at variants 0)]
                          [_ -1])]
                      [byte-id : i64
                        (match (tc_core.tc-global-shared-view layout)
                          [(Enum _ _ variants)
                            (compiler-typecheck-inline-variant-id-at variants 1)]
                          [_ -1])]
                      [wide-id : i64
                        (match (tc_core.tc-global-shared-view layout)
                          [(Enum _ _ variants)
                            (compiler-typecheck-inline-variant-id-at variants 2)]
                          [_ -1])]
                      [pair-id : i64
                        (match (tc_core.tc-global-shared-view layout)
                          [(Enum _ _ variants)
                            (compiler-typecheck-inline-variant-id-at variants 3)]
                          [_ -1])]
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-size
                          (tc_core.tc-global-shared-view layout))
                        24)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-align
                          (tc_core.tc-global-shared-view layout))
                        8)
                        unit
                        (set! ok false))
                      (if (=
                        (core_tests.tc-inline-aggregate-layout-variant-size-id
                          layout
                          empty-id)
                        8)
                        unit
                        (set! ok false))
                      (if (=
                        (core_tests.tc-inline-aggregate-layout-variant-size-id
                          layout
                          byte-id)
                        16)
                        unit
                        (set! ok false))
                      (if (=
                        (core_tests.tc-inline-aggregate-layout-variant-size-id
                          layout
                          wide-id)
                        24)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-variant-payload-offset-id
                          (tc_core.tc-global-shared-view layout)
                          wide-id
                          0)
                        8)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-variant-payload-offset-id
                          (tc_core.tc-global-shared-view layout)
                          wide-id
                          1)
                        16)
                        unit
                        (set! ok false))
                      (if (=
                        (tc_core.tc-inline-aggregate-layout-variant-payload-offset-id
                          layout
                          pair-id
                          0)
                        8)
                        unit
                        (set! ok false)))]
                  [(Err _) (set! ok false)])
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program "WidePacket"))
                  [(Ok layout)
                    (match (tc_core.tc-global-shared-view layout)
                      [(Struct size align fields)
                        (let
                          [first-id : i64
                            (compiler-typecheck-inline-field-id-at fields 0)]
                          [last-id : i64
                            (compiler-typecheck-inline-field-id-at fields 11)]
                          (if (and
                            (= size 56)
                            (= align 8)
                            (=
                              (tc_core.tc-inline-field-layout-list-count fields)
                              12)
                            (= (array-length fields.slots) 12)
                            (string.eq
                              (tc_core.tc-env-key-name-text first-id)
                              "f0")
                            (string.eq
                              (tc_core.tc-env-key-name-text last-id)
                              "f11")
                            (=
                              (tc_core.tc-inline-aggregate-layout-field-offset-id
                                (tc_core.tc-global-shared-view layout)
                                first-id)
                              0)
                            (=
                              (tc_core.tc-inline-aggregate-layout-field-offset-id
                                (tc_core.tc-global-shared-view layout)
                                (compiler-typecheck-inline-field-id-at fields 8))
                              24)
                            (=
                              (tc_core.tc-inline-aggregate-layout-field-offset-id
                                layout
                                last-id)
                              50))
                            unit
                            (set! ok false)))]
                      [_ (set! ok false)])]
                  [(Err _) (set! ok false)])
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program "WideChoice"))
                  [(Ok layout)
                    (match layout
                      [(Enum size align variants)
                        (let
                          [first-id : i64
                            (compiler-typecheck-inline-variant-id-at variants 0)]
                          [last-id : i64
                            (compiler-typecheck-inline-variant-id-at
                              variants
                              11)]
                          [payloads : tc_core.TcInlinePayloadLayoutList
                            (match (tc_core.tc-inline-variant-layout-list-ref
                              variants
                              11)
                              [(Variant _ _ _ items) items])]
                          (if (and
                            (= size 32)
                            (= align 8)
                            (=
                              (tc_core.tc-inline-variant-layout-list-count
                                variants)
                              12)
                            (= (array-length variants.slots) 12)
                            (string.eq
                              (tc_core.tc-env-key-name-text first-id)
                              "V0")
                            (string.eq
                              (tc_core.tc-env-key-name-text last-id)
                              "V11")
                            (=
                              (tc_core.tc-inline-payload-layout-list-count
                                payloads)
                              3)
                            (= (array-length payloads.slots) 3)
                            (=
                              (tc_core.tc-inline-payload-layout-list-offset
                                (tc_core.tc-global-shared-view payloads)
                                0)
                              8)
                            (=
                              (tc_core.tc-inline-payload-layout-list-offset
                                (tc_core.tc-global-shared-view payloads)
                                1)
                              16)
                            (=
                              (tc_core.tc-inline-payload-layout-list-offset
                                payloads
                                2)
                              24))
                            unit
                            (set! ok false)))]
                      [_ (set! ok false)])]
                  [(Err _) (set! ok false)])
                (match (tc_core.tc-inline-aggregate-layout-for-id
                  ctx
                  (compiler-typecheck-fixture-nominal-id program "Tree"))
                  [(Ok layout)
                    (if (= (tc_core.tc-inline-aggregate-layout-size layout) 24)
                      unit
                      (set! ok false))]
                  [(Err _) (set! ok false)])
                (match (tc_core.tc-inline-aggregate-type-layout
                  ctx
                  (ast.ast-ty-tuple (tc_core.tc-type-list2 (U8) (I32))))
                  [(Ok info)
                    (if (and
                      (= (tc_core.tc-layout-info-size info) 8)
                      (= (tc_core.tc-layout-info-align info) 4))
                      unit
                      (set! ok false))]
                  [(Err _) (set! ok false)])
                (match (tc_core.tc-inline-aggregate-type-layout
                  ctx
                  (ast.ast-ty-array
                    (ast.ast-ty-tuple (tc_core.tc-type-list2 (U8) (I32)))
                    2))
                  [(Ok info)
                    (if (and
                      (= (tc_core.tc-layout-info-size info) 16)
                      (= (tc_core.tc-layout-info-align info) 4))
                      unit
                      (set! ok false))]
                  [(Err _) (set! ok false)])
                (match (tc_core.tc-inline-aggregate-type-layout
                  ctx
                  (ast.ast-ty-box (Struct (ci.intern "InlinePacket"))))
                  [(Ok info)
                    (if (and
                      (= (tc_core.tc-layout-info-size info) 8)
                      (= (tc_core.tc-layout-info-align info) 8))
                      unit
                      (set! ok false))]
                  [(Err _) (set! ok false)])
                (match (tc_core.tc-inline-aggregate-type-layout
                  ctx
                  (ast.ast-ty-dyn-array (Struct (ci.intern "InlinePacket"))))
                  [(Ok info)
                    (if (and
                      (= (tc_core.tc-layout-info-size info) 8)
                      (= (tc_core.tc-layout-info-align info) 8))
                      unit
                      (set! ok false))]
                  [(Err _) (set! ok false)])
                ok)]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-typecheck-inline-dense-sequence-source) : String
  "(defstruct I64Sequence
  (items (__tl_dyn-array i64)))")

(define (compiler-typecheck-inline-boxed-tree-source) : String
  "(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))")

(define (compiler-typecheck-inline-loader-helper-layout-ok?) : bool
  (let
    [src : String
      "(defstruct InlineHelperRoots
  (slots (__tl_dyn-array String))
  (len i64))
(defstruct CompilerPkgDep
  (alias String)
  (path String))
(defstruct CompilerPkgDeps
  (slots (__tl_dyn-array CompilerPkgDep))
  (len i64))"]
    (and
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "InlineHelperRoots")
      (compiler-typecheck-inline-layout-ok? src "CompilerPkgDeps"))))

(define (compiler-typecheck-inline-ctfe-metadata-layout-ok?) : bool
  (let
    [src : String
      "(defenum CompilerCtfeValue
  (Unit))
(defstruct CtfeLayoutField
  (name String)
  (offset i64))
(defstruct CtfeLayoutFieldList
  (slots (__tl_dyn-array CtfeLayoutField))
  (len i64))
(defstruct CtfeLayoutInfo
  (name String)
  (is-struct bool)
  (size i64)
  (align i64)
  (fields CtfeLayoutFieldList))
(defstruct CtfeLayoutInfoList
  (slots (__tl_dyn-array CtfeLayoutInfo))
  (len i64))
(defenum AstType
  (AstType.I64))
(defstruct AstTypeList
  (slots (__tl_dyn-array AstType))
  (len i64))
(defstruct CtfeReflectField
  (name String)
  (ty AstType))
(defstruct CtfeReflectFieldList
  (slots (__tl_dyn-array CtfeReflectField))
  (len i64))
(defstruct CtfeReflectVariant
  (name String)
  (payloads AstTypeList))
(defstruct CtfeReflectVariantList
  (slots (__tl_dyn-array CtfeReflectVariant))
  (len i64))
(defenum CtfeReflectInfo
  (Struct String String String CtfeReflectFieldList)
  (Enum String String String CtfeReflectVariantList))
(defstruct CtfeReflectInfoList
  (slots (__tl_dyn-array CtfeReflectInfo))
  (len i64))
(defstruct CtfeEnvBinding
  (key i64)
  (value CompilerCtfeValue)
  (ty AstType)
  (parent i64)
  (mutable-local bool))
(defstruct CtfeEnvArena
  (segments (__tl_dyn-array (__tl_dyn-array CtfeEnvBinding)))
  (segment-count i64)
  (len i64)
  (owner-arena i64))
(defstruct CtfeEnvMetadata
  (layouts CtfeLayoutInfoList)
  (reflections CtfeReflectInfoList))
(defstruct CtfeEnv
  (arena-store (Box CtfeEnvArena))
  (head i64)
  (metadata (Box CtfeEnvMetadata)))"]
    (and
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "CtfeEnv")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "CtfeEnvBinding")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "CtfeEnvArena")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "CtfeEnvMetadata")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "CtfeLayoutInfoList")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "CtfeLayoutFieldList")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "CtfeReflectInfoList")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "CtfeReflectFieldList")
      (compiler-typecheck-inline-layout-ok? src "CtfeReflectVariantList"))))

(define (compiler-typecheck-inline-ast-list-layout-ok?) : bool
  (let
    [src : String
      "(defenum AstType
  (AstType.I64)
  (AstType.Func (Box AstTypeList) i64)
  (AstType.Tuple (Box AstTypeList))
  (AstType.Box (Box AstType)))
(defstruct AstTypeList
  (slots (__tl_dyn-array AstType))
  (len i64))
(defenum AstPattern
  (AstPattern.Wildcard)
  (AstPattern.Tuple (Box AstPatternList)))
(defstruct AstPatternList
  (slots (__tl_dyn-array AstPattern))
  (len i64))
(defenum AstExpr
  (AstExpr.Literal i64)
  (AstExpr.Call (Box AstExpr) FixtureExprList)
  (AstExpr.Tuple FixtureExprList)
  (AstExpr.Match (Box AstExpr) AstPatternList))
(defstruct FixtureExprList
  (slots (__tl_dyn-array AstExpr))
  (len i64))"]
    (and
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "AstType")
      (compiler-typecheck-inline-layout-size-ok?
        (tc_core.tc-global-shared-view src)
        "AstType"
        24)
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "AstTypeList")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "AstPattern")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "AstPatternList")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "AstExpr")
      (compiler-typecheck-inline-layout-ok? src "FixtureExprList"))))

(define (compiler-typecheck-inline-formatter-layout-ok?) : bool
  (let
    [src : String
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
(defstruct FormatCstList
  (slots (__tl_dyn-array FormatCst))
  (start i64)
  (len i64))
(defenum Doc
  (DEmpty)
  (DText String)
  (DSoftLine)
  (DHardLine)
  (DConcat (Box Doc) (Box Doc))
  (DNest i64 (Box Doc))
  (DGroup (Box Doc)))"]
    (and
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "FormatCst")
      (compiler-typecheck-inline-layout-ok?
        (tc_core.tc-global-shared-view src)
        "FormatCstList")
      (compiler-typecheck-inline-layout-ok? src "Doc"))))

(define (compiler-typecheck-inline-unboxed-tree-source) : String
  "(defenum BadTree
  (Leaf i64)
  (Branch BadTree BadTree))")

(define (compiler-typecheck-inline-mutual-struct-source) : String
  "(defstruct A (b B))
(defstruct B (a A))")

(define (compiler-typecheck-inline-layout-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-inline-unboxed-tree-source)
        "\n"
        "(define (main [x : BadTree]) : i64 0)")
      "typecheck: inline aggregate layout cycle BadTree -> BadTree; insert (Box BadTree) at the recursive edge")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-inline-mutual-struct-source)
      "typecheck: inline aggregate layout cycle A -> B -> A; insert (Box A) at the recursive edge")
    (compiler-typecheck-ok? (compiler-typecheck-inline-dense-sequence-source))
    (compiler-typecheck-ok? (compiler-typecheck-inline-boxed-tree-source))
    (compiler-typecheck-inline-layout-ok?
      (compiler-typecheck-inline-dense-sequence-source)
      "I64Sequence")
    (compiler-typecheck-inline-layout-ok?
      (compiler-typecheck-inline-boxed-tree-source)
      "Tree")
    (compiler-typecheck-inline-layout-ok?
      "(defstruct SymI64Binding
  (key i64)
  (value i64))
(defstruct SymI64Env
  (bindings (__tl_dyn-array SymI64Binding)))"
      "SymI64Env")
    (compiler-typecheck-inline-loader-helper-layout-ok?)
    (compiler-typecheck-inline-ctfe-metadata-layout-ok?)
    (compiler-typecheck-inline-ast-list-layout-ok?)
    (compiler-typecheck-inline-formatter-layout-ok?)
    (compiler-typecheck-inline-layout-ok?
      "(defstruct Node
  (name String)
  (children (__tl_dyn-array Node))
  (next (Box Node))
  (raw (Ptr Node))
  (raw-mut (MutPtr Node))
  (ref (& phase Node))
  (ref-mut (&mut phase Node))
  (visit (-> Node Node)))"
      "Node")
    (compiler-typecheck-inline-layout-query-ok?)
    (compiler-typecheck-inline-layout-storage-arena-ok?)
    (compiler-typecheck-inline-layout-state-isolation-ok?)
    (compiler-typecheck-inline-layout-error-ok?
      (compiler-typecheck-inline-unboxed-tree-source)
      "BadTree"
      "typecheck: inline aggregate layout cycle BadTree -> BadTree; insert (Box BadTree) at the recursive edge")
    (compiler-typecheck-inline-layout-error-ok?
      (compiler-typecheck-inline-mutual-struct-source)
      "A"
      "typecheck: inline aggregate layout cycle A -> B -> A; insert (Box A) at the recursive edge")
    (compiler-typecheck-inline-layout-error-ok?
      "(defstruct BadFixed
  (items (Array BadFixed 2)))"
      "BadFixed"
      "typecheck: inline aggregate layout cycle BadFixed -> BadFixed; insert (Box BadFixed) at the recursive edge")
    (compiler-typecheck-inline-layout-error-ok?
      "(defstruct BadTuple
  (item (Tuple i64 BadTuple)))"
      "BadTuple"
      "typecheck: inline aggregate layout cycle BadTuple -> BadTuple; insert (Box BadTuple) at the recursive edge")
    (compiler-typecheck-inline-layout-error-ok?
      "(defstruct BadRegion
  (next (in phase BadRegion)))"
      "BadRegion"
      "typecheck: inline aggregate layout cycle BadRegion -> BadRegion; insert (Box BadRegion) at the recursive edge")))

(define (compiler-typecheck-nominal-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defenum Maybe (None) (Some i64))
(defstruct Point (x i64) (y i64))
(define (from-maybe [m : Maybe]) : i64
  (match m [(Some v) v] [None 0]))
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (+ p.x (from-maybe (Some p.y)))))")
    (compiler-typecheck-ok?
      "(defmacro (generate-nominals) : Decls
  `(begin
    (defstruct Point (x i64) (y i64))
    (defenum Maybe (None) (Some i64))))
(generate-nominals)
(define (main) : i64
  (let
    [p : Point (Point 40 2)]
    (match (Some p.y)
      [(Some n) (+ p.x n)]
      [None 0])))")
    (compiler-typecheck-ok?
      "(defmacro (generate-point-api) : Decls
  `(begin
    (defstruct Point (x i64))
    (define (make-point [x : i64]) : Point (Point x))))
(generate-point-api)
(define (main) : i64
  (let [point : Point (make-point 7)] point.x))")
    (compiler-typecheck-generated-fallback-diagnostic-ok?)
    (compiler-typecheck-error-ok?
      "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (match m [(Some v) v] [None false]))"
      "typecheck: match arm result type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-unknown-variant-source)
      "typecheck: unknown variant Other")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-unknown-field-source)
      "typecheck: unknown struct field Point.z; available fields: x, y")
    (compiler-typecheck-ok?
      "(defstruct Point (x i64) (y i64))
(defenum Maybe (None) (Some i64))
(define point : Point (Point 20 2))
(define pair : (Tuple i64 bool) (tuple 7 true))
(define fixed : (Array i64 2) (array 5 6))
(define maybe : Maybe (Some 8))
(define (main) : i64
  (+ point.x
     (+ (tuple-ref pair 0)
        (+ (array-ref fixed 1)
           (match maybe [(Some n) n] [None 0])))))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define bad : String (with-arena r (string.int->string 1)))")
      "typecheck: region-tagged value cannot escape with-arena 'r'")
    (compiler-typecheck-error-ok?
      "(define bad : (Tuple (& n i64) i64) (tuple (& n) 1))"
      "typecheck: storing references in top-level values requires lifetime support")
    (compiler-typecheck-error-ok?
      "(defstruct Point (x i64) (flag bool))
(define bad : Point (Point true false))"
      "typecheck: call `Point` argument 1 (parameter `x`) type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(defstruct Point (x i64) (flag bool))
(define bad : Point (Point 1))"
      "typecheck: call arity mismatch: Point expected 2 arguments, got 1 argument")
    (compiler-typecheck-error-ok?
      "(define (main) : i64
  (let [value : i64 1] value.x))"
      "typecheck: field projection .x requires struct, got i64")
    (compiler-typecheck-ok?
      "(defenum Tree
  (Leaf i64)
  (Branch (Box Tree) (Box Tree)))
(define (left-value [tree : Tree]) : i64
  (match tree
    [(Leaf value) value]
    [(Branch left _) (left-value (deref left))]))
(define (main) : i64
  (left-value (Branch (box (Leaf 1)) (box (Leaf 2)))))")
    (compiler-typecheck-error-ok?
      "(defenum Left (Same) (Same))
(define (main) : i64 0)"
      "symbols: duplicate enum variant Left.Same")
    (compiler-typecheck-ok?
      "(defenum Left (Same) (Other))
(defenum Right (Same))
(define left : Left Left.Same)
(define right : Right Right.Same)
(define (main) : i64
  (+ (match left [Left.Same 1] [_ 0])
     (match right [Right.Same 2] [_ 0])))")
    (compiler-typecheck-ok?
      "(defenum Left (Ok i64) (Err i64))
(defenum Right (Ok i64) (Err i64))
(define (left-score [item : Left]) : i64
  (match item
    [(Left.Ok value) value]
    [(Left.Err error) error]))
(define (right-score [item : Right]) : i64
  (match item
    [(Right.Ok value) value]
    [(Right.Err error) error]))
(define (main) : i64
  (+ (left-score (Left.Ok 1)) (right-score (Right.Err 2))))")
    (compiler-typecheck-ok?
      "(module prior)
(defenum List (Nil))
(module current)
(defenum List (Nil))
(define (make) : List (Nil))
(define (main) : i64 (match (make) [Nil 1]))")
    (compiler-typecheck-ok?
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
    (compiler-typecheck-ok?
      "(module left)
(define same : i64 20)
(define (get) : i64 same)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module right)
(define same : i64 22)
(define (get) : i64 same)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import left)
(import right)
(define (main) : i64
  (let
    [left-point : left.Point (left.Point 5)]
    [right-point : right.Point (right.Point 7)]
    (+
      (left.get)
      (+
        (right.get)
        (+
          left-point.x
          (+
            right-point.x
            (match (right.Maybe.Some 1)
              [(right.Maybe.Some v) v]
              [right.Maybe.None 0])))))))")
    (compiler-typecheck-error-ok?
      "(module left)
(define (get) : i64 20)
(module main)
(define (main) : i64 (get))"
      "typecheck: unbound name get")
    (compiler-typecheck-ok?
      "(module data)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import data as d)
(define (main) : i64
  (+
    (d.get)
    (+
      (let [p : d.Point (d.Point 7)]
        p.x)
      (match (d.Maybe.Some 3)
        [(d.Maybe.Some v) v]
        [d.Maybe.None 0]))))")
    (compiler-typecheck-ok?
      "(module pkg.data)
(define (get) : i64 20)
(defenum Maybe (None) (Some i64))
(defstruct Point (x i64))
(module main)
(import pkg.data)
(define (main) : i64
  (+
    (data.get)
    (+
      (let [p : data.Point (data.Point 7)]
        p.x)
      (match (data.Maybe.Some 3)
        [(data.Maybe.Some v) v]
        [data.Maybe.None 0]))))")
    (compiler-typecheck-ok?
      "(defstruct Pair (x i64) (y i64))
(defstruct Outer (p Pair) (z i64))
(define (take [r : (& n i64)]) : i64 5)
(define (main) : i64
  (let [o : Outer (Outer (Pair 1 2) 3)]
    (begin
      (set! o.p.x 17)
      (+ o.p.x (+ o.p.y (+ o.z (take (& o.p.x))))))))")
    (compiler-typecheck-ok?
      "(defstruct Pair (left i64) (right i64))
(define global-pair : Pair (Pair 20 22))
(define (main) : i64
  (begin
    (set! global-pair.left 21)
    (+ global-pair.left global-pair.right)))")
    (compiler-typecheck-ok?
      "(defstruct Bag (items (Array i64 1)))
(defmacro (emit) : Decls
  `(begin
    (define (first [bag : (&mut bag Bag)]) : (&mut bag i64)
      (&mut (array-ref bag.items 0)))))
(emit)
(define (main) : i64
  (let
    [bag : Bag (Bag (array 1))]
    [slot : (&mut bag i64) (first (&mut bag))]
    (begin
      (set! (deref slot) 64)
      (array-ref bag.items 0))))")
    (compiler-typecheck-ok?
      "(module pkg.data)
(define (value) : i64 99)
(module main)
(import pkg.data)
(defstruct Pair (value i64))
(define (main) : i64
  (let [data : Pair (Pair 42)]
    data.value))")
    (compiler-typecheck-ok?
      "(module pkg.data)
(define (get) : i64 20)
(module pkg.macros)
(defmacro (identity [x : Expr]) : Expr x)
(module main)
(import pkg.data)
(define (main) : i64 (+ (data.get) 1))")
    (compiler-typecheck-ok?
      "(module pkg.data)
(define (get) : i64 20)
(module main)
(import pkg.data)
(define (main) : i64 (pkg.data.get))")
    (compiler-typecheck-error-ok?
      "(module pkg.data)
(define (get) : i64 20)
(module main)
(define (main) : i64 (pkg.data.get))"
      "typecheck: unknown qualified name pkg.data.get; import the module or use a visible dotted module alias")
    (compiler-typecheck-ok?
      "(module left.same)
(define (get) : i64 20)
(module right.same)
(define (get) : i64 22)
(module main)
(import left.same as l)
(import right.same as r)
(define (main) : i64 (+ (l.get) (r.get)))")
    (compiler-typecheck-error-ok?
      "(module pkg.data)
(define (get) : i64 20)
(module main)
(import pkg.data)
(define (main) : i64 (get))"
      "typecheck: unbound name get")
    (compiler-typecheck-error-ok?
      "(module data)
(define (get) : i64 20)
(module main)
(import data as d)
(define (main) : i64 (missing.get))"
      "typecheck: unknown qualified name missing.get; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(module data)
(define (get) : i64 20)
(module main)
(import data as d)
(define (main) : i64 (d.missing))"
      "typecheck: unbound name d.missing")
    (compiler-typecheck-error-ok?
      "(module data)
(define (get) : i64 20)
(module main)
(import data as d)
(define (main) : i64 (d/get))"
      "typecheck: slash-qualified name d/get is no longer supported; use d.get")
    (compiler-typecheck-repr-c-tests-ok?)
    (compiler-typecheck-inline-layout-tests-ok?)))

(define (compiler-typecheck-with-escape-string-source) : String
  (compiler-typecheck-with-arena-source
    "(define (main) : String
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch (string.int->string 42))))"))

(define (compiler-typecheck-with-escape-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : i64
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch 40 42)))"))
    (compiler-typecheck-ok? (compiler-typecheck-with-escape-string-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : String
  (let
    [scratch : Arena (arena-make)]
    (with-arena r
      (with-escape scratch (string.int->string 42)))))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : (__tl_dyn-array i64)
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch (__tl_make-array i64 4))))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : (Box String)
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch (box (string.int->string 4)))))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(defstruct EscapePayload
  (name String)
  (items (__tl_dyn-array String))
  (cell (Box String)))
(defenum EscapeResult
  (EscapeOk EscapePayload)
  (EscapeNone))
(define (main) : EscapeResult
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch
      (let
        [items : (__tl_dyn-array String) (__tl_make-array String 2)]
        (begin
          (set! (array-ref items 0) (string.int->string 1))
          (set! (array-ref items 1) (string.int->string 2))
          (EscapeOk
            (EscapePayload
              (string.int->string 3)
              items
              (box (string.int->string 4)))))))))"))
    (compiler-typecheck-error-ok?
      "(define (main) : i64
  (with-escape true 1))"
      "typecheck: with-escape arena must be Arena")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (inc [x : i64]) : i64 (+ x 1))
(define (main) : (-> i64 i64)
  (let
    [scratch : Arena (arena-make)]
    (with-escape scratch inc)))")
      "typecheck: with-escape result type is not clone-supported: (-> i64 i64)")))

(define (compiler-typecheck-in-arena-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : i64
  (let
    [scratch : Arena (arena-make)]
    (in-arena scratch (__tl_string_length (string.int->string 42)))))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : (__tl_dyn-array i64)
  (let
    [scratch : Arena (arena-make)]
    (in-arena scratch (__tl_make-array i64 4))))")
      "typecheck: reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : (Box String)
  (let
    [scratch : Arena (arena-make)]
    (in-arena scratch (box (string.int->string 4)))))")
      "typecheck: reference value would escape lexical scope")
    (compiler-typecheck-error-ok?
      "(define (main) : i64
  (in-arena true 1))"
      "typecheck: in-arena arena must be Arena")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : String
  (let
    [scratch : Arena (arena-make)]
    (in-arena scratch
      (with-arena inner (string.int->string 1)))))")
      "typecheck: region-tagged value cannot escape with-arena 'inner'")))

(define (compiler-typecheck-box-render-ok?) : bool
  (and
    (string.eq (tc_core.tc-type-render (ast.ast-ty-box (I64))) "(Box i64)")
    (tc_core.tc-type-eq
      (ast.ast-ty-box (ast.ast-ty-region cbi.compiler-builtin-id-fix-n (I64)))
      (ast.ast-ty-box (I64)))
    (tc_core.tc-type-contains-region
      (ast.ast-ty-box
        (ast.ast-ty-region cbi.compiler-builtin-id-fix-n (String)))
      cbi.compiler-builtin-id-fix-n)))

(define (compiler-typecheck-box-tests-ok?) : bool
  (and
    (compiler-typecheck-box-render-ok?)
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [b : (Box i64) (box 7)]
    (deref b)))")
    (compiler-typecheck-ok? "(define (main) : i64 (deref (box 7)))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [b : (Box i64) (box 7)]
    (deref b)))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [b : (Box i64) (box 7)]
    (begin
      (set! (deref b) 9)
      (deref b))))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [cell : (Box i64) (box 21)]
    [view : (& cell i64) (& (deref cell))]
    (+ (deref view) (deref cell))))")
    (compiler-typecheck-ok?
      "(define (write [value : (&mut value i64)]) : unit
  (set! (deref value) 42))
(define (main) : i64
  (let [value : i64 0]
    (begin
      (write (&mut value))
      value)))")
    (compiler-typecheck-ok?
      "(defstruct Pair (x i64) (y i64))
(define (set-x [pair : (&mut pair Pair)]) : i64
  (begin
    (set! pair.x 9)
    pair.x))
(define (main) : i64
  (let
    [b : (Box Pair) (box (Pair 1 2))]
    (set-x (&mut (deref b)))))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (with-arena r
    (let
      [b : (in r (Box i64)) (box 7)]
      (deref b))))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : String
  (with-arena r
    (let
      [b : (in r (Box String)) (box (string.int->string 41))]
      (deref b))))")
      "typecheck: region-tagged value cannot escape with-arena 'r'")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (deref 1))"
      "typecheck: deref requires Box or reference type")
    (compiler-typecheck-error-ok?
      "(define (main) : unit
  (let
    [b : (Box i64) (box 7)]
    (set! (deref b) false)))"
      "typecheck: box assignment type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (deref 1))"
      "typecheck: deref requires Box or reference type")))

;; A raw-pointer `deref` is an unsafe place only as a struct-field projection
;; receiver, and only a `MutPtr` field is assignable.
(define (compiler-typecheck-raw-deref-field-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defstruct Inner (a i64) (b i64))
(defstruct Point (x i64) (inner Inner) (items (Array i64 2)))
(define (bump [p : (MutPtr Point)]) : i64
  (unsafe
    (begin
      (set! (deref p).x (+ (deref p).x 1))
      (set! (deref p).inner.b 2)
      (set! (array-ref (deref p).items 1) 3)
      (+ (deref p).inner.a (array-ref (deref p).items 0)))))
(define (read [p : (Ptr Point)]) : i64
  (unsafe (deref p).inner.b))
(define (main) : i64 0)")
    (compiler-typecheck-error-ok?
      "(defstruct Point (x i64) (y i64))
(define (main [p : (MutPtr Point)]) : unit
  (set! (deref p).x 1))"
      "typecheck: deref of a raw pointer requires unsafe context")
    (compiler-typecheck-error-ok?
      "(defstruct Point (x i64) (y i64))
(define (main [p : (Ptr Point)]) : unit
  (unsafe (set! (deref p).x 1)))"
      (tc_core.tc-raw-deref-read-only-message))
    (compiler-typecheck-error-ok?
      "(defstruct Point (x i64) (y i64))
(define (main [p : (MutPtr Point)]) : Point
  (unsafe (deref p)))"
      (tc_core.tc-raw-deref-whole-message))))

(define (compiler-typecheck-init-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some i64))
(define (main) : i64
  (let
    [n : i64 (init : i64)]
    [flag : bool (init : bool)]
    [text : String (init : String)]
    [items : (__tl_dyn-array i64) (init : (__tl_dyn-array i64))]
    [tupled : (Tuple i64 bool) (init : (Tuple i64 bool))]
    [fixed : (Array i64 2) (init : (Array i64 2))]
    [point : Point (init : Point)]
    [maybe : Maybe (init : Maybe)]
    [boxed : (Box i64) (init : (Box i64))]
    (+ n (+ point.x (+ (tuple-ref tupled 0) (+ (array-ref fixed 0) (deref boxed)))))))")
    (compiler-typecheck-ok?
      "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some i64))
(define zero : i64 (init))
(define (take [n : i64]) : i64 n)
(define (return-init) : i64 (init))
(define (point-x [p : Point]) : i64 p.x)
(define (main) : i64
  (let
    [n : i64 (init)]
    [items : (__tl_dyn-array i64) (init)]
    [fixed : (Array i64 2) (array (init) 5)]
    [point : Point (Point (init) (init))]
    [maybe : Maybe (Some (init))]
    (begin
      (set! (array-ref fixed 0) (init))
      (__tl_array-push! items (init))
      (+ zero
        (+ n
          (+ (return-init)
            (+ (take (init))
              (+ (point-x (init))
                (+ point.x
                  (+ (array-ref fixed 0)
                    (match maybe [(Some v) v] [(None) 0])))))))))))")
    (compiler-typecheck-error-ok?
      "(define (main) : (-> i64) (init : (-> i64)))"
      "typecheck: init unsupported type (->  i64)")
    (compiler-typecheck-error-ok?
      "(define (main) : (-> i64) (init))"
      "typecheck: init unsupported type (->  i64)")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (let [n (init)] n))"
      "typecheck: contextual init requires an expected type; use (init : T) or add an annotation")
    (compiler-typecheck-error-ok?
      "(defstruct Raw (:repr c) (x i64))
(define (main) : Raw (init : Raw))"
      "typecheck: init supports only default-layout structs")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : (& n i64) (init : (& n i64)))"
      "typecheck: init unsupported type (& n i64)")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main) : FileHandle (init : FileHandle))"
      "typecheck: init does not support cleanup-owning aggregate FileHandle")))

(define (compiler-typecheck-region-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : i64
  (with-arena r
    (let
      [s : String (string.int->string 41)]
      (__tl_string_length s))))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : String
  (with-arena r (string.int->string 41)))")
      "typecheck: region-tagged value cannot escape with-arena 'r'")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (sink [s : String]) : i64 (__tl_string_length s))
(define (main) : i64
  (with-arena r
    (let
      [s : String (string.int->string 41)]
      (sink s))))")
      "typecheck: cannot pass region-tagged value to function parameter; region value would escape")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : i64
  (with-arena oute
    (let
      [s : String (with-arena inner (string.int->string 1))]
      0)))")
      "typecheck: region-tagged value cannot escape with-arena 'inner'")
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : i64
  (with-arena oute
    (let
      [s : String (string.int->string 1)]
      (with-arena inner (__tl_string_length s)))))"))
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : i64
  (with-arena r
    (let
      [a : (__tl_dyn-array i64) (__tl_make-array i64 n)]
      (begin
        (set! (array-ref a 0) 7)
        (array-length a)))))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(defstruct Box (s String))
(define (main) : String
  (with-arena r
    (let
      [b : Box (Box (string.int->string 1))]
      b.s)))")
      "typecheck: region-tagged value cannot escape with-arena 'r'")
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(defenum Token (Text String) (End))
(define (main) : i64
  (with-arena r
    (match (Text (string.int->string 1))
      [(Text s) (__tl_string_length s)]
      [End 0])))"))))

(define (compiler-typecheck-try-query-result-info-ok?
  [operand-info : tc_core.TcResultInfo]
  [return-info : tc_core.TcResultInfo]
  [operand-id : i64]
  [return-id : i64]) : bool
  (and
    (match (tc_core.tc-result-info-kind
      (tc_core.tc-global-shared-view operand-info))
      [(TcTryResult) true]
      [(TcTryOption) false])
    (match (tc_core.tc-result-info-kind
      (tc_core.tc-global-shared-view return-info))
      [(TcTryResult) true]
      [(TcTryOption) false])
    (=
      (tc_core.tc-result-info-enum-id
        (tc_core.tc-global-shared-view operand-info))
      operand-id)
    (=
      (tc_core.tc-result-info-enum-id
        (tc_core.tc-global-shared-view return-info))
      return-id)
    (not (= operand-id return-id))
    (not
      (=
        (tc_core.tc-result-info-ok-id
          (tc_core.tc-global-shared-view operand-info))
        (tc_core.tc-result-info-ok-id
          (tc_core.tc-global-shared-view return-info))))
    (not
      (=
        (tc_core.tc-result-info-err-id
          (tc_core.tc-global-shared-view operand-info))
        (tc_core.tc-result-info-err-id
          (tc_core.tc-global-shared-view return-info))))
    (tc_core.tc-type-eq
      (tc_core.tc-result-info-ok-type
        (tc_core.tc-global-shared-view operand-info))
      (I64))
    (tc_core.tc-type-eq
      (tc_core.tc-result-info-ok-type
        (tc_core.tc-global-shared-view return-info))
      (Bool))
    (tc_core.tc-type-eq
      (tc_core.tc-result-info-err-type operand-info)
      (tc_core.tc-result-info-err-type return-info))))

(define (compiler-typecheck-try-query-option-info-ok?
  [operand-info : tc_core.TcResultInfo]
  [return-info : tc_core.TcResultInfo]
  [operand-id : i64]
  [return-id : i64]) : bool
  (and
    (match (tc_core.tc-result-info-kind
      (tc_core.tc-global-shared-view operand-info))
      [(TcTryResult) false]
      [(TcTryOption) true])
    (match (tc_core.tc-result-info-kind
      (tc_core.tc-global-shared-view return-info))
      [(TcTryResult) false]
      [(TcTryOption) true])
    (=
      (tc_core.tc-result-info-enum-id
        (tc_core.tc-global-shared-view operand-info))
      operand-id)
    (=
      (tc_core.tc-result-info-enum-id
        (tc_core.tc-global-shared-view return-info))
      return-id)
    (not (= operand-id return-id))
    (tc_core.tc-type-eq
      (tc_core.tc-result-info-ok-type
        (tc_core.tc-global-shared-view operand-info))
      (I64))
    (tc_core.tc-type-eq
      (tc_core.tc-result-info-ok-type
        (tc_core.tc-global-shared-view return-info))
      (Bool))
    (tc_core.tc-type-eq (tc_core.tc-result-info-err-type operand-info) (Unit))
    (tc_core.tc-type-eq (tc_core.tc-result-info-err-type return-info) (Unit))))

(define (compiler-typecheck-try-query-residual-mismatch-ok?
  [result : tc_core.TcTryQueryResult]
  [operand-id : i64]
  [return-id : i64]) : bool
  (match result
    [(TcTryQueryCompatible _ _)
      (io.panic "typecheck: residual mismatch query was compatible")]
    [(TcTryQueryIncompatible
        (TcTryCarrier operand-info)
        (TcTryCarrier return-info)
        (TcTryResidualTypeMismatch operand-residual return-residual))
      (and
        (= (tc_core.tc-result-info-enum-id operand-info) operand-id)
        (= (tc_core.tc-result-info-enum-id return-info) return-id)
        (match (tc_core.tc-global-shared-view operand-residual)
          [(Struct operand-error-id)
            (match (tc_core.tc-global-shared-view return-residual)
              [(Struct return-error-id)
                ;; Both declarations were spelled `Error` in source, but the
                ;; resolved nominal identities belong to different modules.
                (if (= operand-error-id return-error-id)
                  (io.panic "typecheck: residual Error identities matched")
                  true)]
              [_
                (io.panic
                  (str_cat.str-cat
                    "typecheck: return residual was "
                    (tc_core.tc-type-render return-residual)))])]
          [_
            (io.panic
              (str_cat.str-cat
                "typecheck: operand residual was "
                (tc_core.tc-type-render operand-residual)))]))]
    [(TcTryQueryIncompatible _ _ reason)
      (io.panic (tc_core.tc-try-incompatibility-message reason))]))

(define (compiler-typecheck-try-query-forbidden-ok?
  [result : tc_core.TcTryQueryResult]) : bool
  (match result
    [(TcTryQueryCompatible _ _) false]
    [(TcTryQueryIncompatible
        (TcTryCarrier _)
        (TcTryCarrier _)
        (TcTryEarlyExitForbidden (TcTryEarlyExitForbiddenSpmd)))
      true]
    [(TcTryQueryIncompatible _ _ _) false]))

(define (compiler-typecheck-try-query-context-ok? [ctx : tc_core.TcContext]) : bool
  (let
    [program : ast.AstProgram (tc_api.compiler-typecheck-context-program ctx)]
    [input-result-id : i64
      (compiler-typecheck-fixture-nominal-id program "InputResult")]
    [outer-result-id : i64
      (compiler-typecheck-fixture-nominal-id program "OuterResult")]
    [other-result-id : i64
      (compiler-typecheck-fixture-nominal-id program "OtherResult")]
    [input-option-id : i64
      (compiler-typecheck-fixture-nominal-id program "InputOption")]
    [outer-option-id : i64
      (compiler-typecheck-fixture-nominal-id program "OuterOption")]
    (unless
      (and
        (>= input-result-id 0)
        (>= outer-result-id 0)
        (>= other-result-id 0)
        (>= input-option-id 0)
        (>= outer-option-id 0))
      (io.panic "typecheck: try query fixture identity lookup failed"))
    (unless
      (match (tc_core.tc-try-query
        ctx
        (Enum input-result-id)
        (Enum outer-result-id)
        TcTryEarlyExitAllowed)
        [(TcTryQueryCompatible operand-info return-info)
          (compiler-typecheck-try-query-result-info-ok?
            operand-info
            return-info
            input-result-id
            outer-result-id)]
        [(TcTryQueryIncompatible _ _ _) false])
      (io.panic "typecheck: compatible Result try query failed"))
    (unless
      (match (tc_core.tc-try-query
        ctx
        (Enum input-option-id)
        (Enum outer-option-id)
        TcTryEarlyExitAllowed)
        [(TcTryQueryCompatible operand-info return-info)
          (compiler-typecheck-try-query-option-info-ok?
            operand-info
            return-info
            input-option-id
            outer-option-id)]
        [(TcTryQueryIncompatible _ _ _) false])
      (io.panic "typecheck: compatible Option try query failed"))
    (unless
      (compiler-typecheck-try-query-residual-mismatch-ok?
        (tc_core.tc-try-query
          ctx
          (Enum input-result-id)
          (Enum other-result-id)
          TcTryEarlyExitAllowed)
        input-result-id
        other-result-id)
      (io.panic "typecheck: residual mismatch try query failed"))
    (unless
      (compiler-typecheck-try-query-forbidden-ok?
        (tc_core.tc-try-query
          ctx
          (Enum input-result-id)
          (Enum outer-result-id)
          TcTryEarlyExitForbiddenSpmd))
      (io.panic "typecheck: forbidden-context try query failed"))
    true))

(define (compiler-typecheck-try-query-tests-ok?) : bool
  (match (parser.parse-ast-source
    "(module try_query_left)
(defstruct Error (code i64))
(defenum InputResult (OkInput i64) (ErrInput Error))
(defenum OuterResult (OkOuter bool) (ErrOuter Error))
(defenum InputOption (SomeInput i64) (NoneInput))
(module try_query_right)
(defstruct Error (code i64))
(defenum OtherResult (OkOther i64) (ErrOther Error))
(defenum OuterOption (SomeOuter bool) (NoneOuter))")
    [(Ok program)
      (match (tc_api.typecheck-compiler-program-with-paths-checked
        program
        (ast.ast-decl-path-list-new))
        [(Ok _ ctx _ _) (compiler-typecheck-try-query-context-ok? ctx)]
        [(Partial _ _ _ _) false]
        [(Err _) false])]
    [(Err _) false]))

(define (compiler-typecheck-resource-with-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([a 1 close]
         [b (+ a 1) close])
    (+ a b)))")
    (compiler-typecheck-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([outer 1 close])
    (with ([inner (+ outer 1) close])
      (+ outer inner))))")
    (compiler-typecheck-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let [h : i64 2]
      ((lambda () : i64 h)))))")
    (compiler-typecheck-error-ok?
      "(define (close [h : bool]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    h))"
      "typecheck: with cleanup function type mismatch: expected i32, found bool")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : i64 h)
(define (main) : i64
  (with ([h 1 close])
    h))"
      "typecheck: with cleanup function type mismatch")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 (close h)])
    h))"
      "typecheck: with cleanup must be a direct function name")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let [copy h]
      copy)))"
      "typecheck: ordinary let cannot own cleanup-required resource; use with")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main) : i64
  (let [h : FileHandle (FileHandle 1)]
    0))"
      "typecheck: cleanup obligation of `h` is not discharged at the end of its let scope")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    h))"
      "typecheck: cleanup-required resource would escape with scope")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let [t : (Tuple i64 i64) (tuple h 2)]
      0)))"
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let [items : (Array i64 2) (array h 2)]
      0)))"
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    (compiler-typecheck-error-ok?
      "(defstruct Box (value i64))
(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let [box : Box (Box h)]
      0)))"
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    (compiler-typecheck-error-ok?
      "(defenum Maybe (Some i64))
(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let [m : Maybe (Some h)]
      0)))"
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    ;; Two enums declare `Some`, so typecheck qualifies the constructor first.
    (compiler-typecheck-error-ok?
      "(defenum Maybe (Some i64))
(defenum Other (Some i64))
(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    (let [m : Maybe (Some h)]
      0)))"
      "typecheck: cannot store cleanup-required resource in ordinary aggregate")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close])
    ((lambda () : i64 h))))"
      "typecheck: lambda cannot capture cleanup-required resource; resource value would escape")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (with ([h 1 close]
         [copy h close])
    copy))"
      "typecheck: cleanup-required resource already has a cleanup owner")
    (compiler-typecheck-error-ok?
      "(define (close [h : i64]) : unit unit)
(define (main) : i64
  (let [slot : i64 0]
    (with ([h 1 close])
      (set! slot h))))"
      "typecheck: cannot store cleanup-required resource in longer-lived binding")))

(define (compiler-typecheck-cleanup-struct-repr-c-ast-program) : ast.AstProgram
  (ast.ast-program
    (ast.ast-decl-cons
      (ast.ast-decl-def-struct-id
        (ci.intern-generated-name "Bad")
        (ast.ast-struct-repr-c)
        (ast.ast-struct-cleanup-fn-id
          (ci.intern-syntax-id-from-raw
            (ci.intern-generated-name "cleanup-bad")))
        (ast.ast-field-def-cons
          (ast.ast-field-def-id
            (ci.intern-syntax-id-from-raw (ci.intern-generated-name "fd"))
            (I64)
            (No))
          (ast.ast-field-def-list-new)))
      (ast.ast-decl-list-new))))

(define (compiler-typecheck-cleanup-struct-field-outside-ast-program) : ast.AstProgram
  (ast.ast-program
    (ast.ast-decl-cons
      (ast.ast-decl-def-struct-id
        (ci.intern-generated-name "Bad")
        (Default)
        (No)
        (ast.ast-field-def-cons
          (ast.ast-field-def-id
            (ci.intern-syntax-id-from-raw (ci.intern-generated-name "fd"))
            (I64)
            (ast.ast-field-cleanup-fn-id
              (ci.intern-syntax-id-from-raw
                (ci.intern-generated-name "close-fd"))))
          (ast.ast-field-def-list-new)))
      (ast.ast-decl-list-new))))

(define (compiler-typecheck-cleanup-struct-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main [h : FileHandle]) : i64 h.fd)")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct BufferedFile
  (:cleanup cleanup-buffered-file)
  (handle FileHandle (:owned))
  (size i64))
(define (main [b : BufferedFile]) : i64 b.size)")
    (compiler-typecheck-ok?
      "(module cleanup)
(define (close-fd [fd : i64]) : unit unit)
(module main)
(import cleanup as c)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup c/close-fd)))
(define (main [h : FileHandle]) : i64 h.fd)")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main [h : FileHandle]) : i64 h.fd)")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Bad
  (handle FileHandle))"
      "typecheck: struct Bad field handle stores cleanup-owning type FileHandle without :owned")
    (compiler-typecheck-error-ok?
      "(define (close-bool [fd : bool]) : unit unit)
(defstruct Bad
  (:cleanup cleanup-bad)
  (fd i64 (:cleanup close-bool)))"
      "typecheck: struct Bad field fd cleanup function close-bool type mismatch: expected (-> i64 unit), found (-> bool unit)")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : i64 fd)
(defstruct Bad
  (:cleanup cleanup-bad)
  (fd i64 (:cleanup close-fd)))"
      "typecheck: struct Bad field fd cleanup function close-fd type mismatch: expected (-> i64 unit), found (-> i64 i64)")
    (compiler-typecheck-error-ok?
      "(defstruct Bad
  (:cleanup cleanup-bad)
  (n i64 (:owned)))"
      "typecheck: struct Bad field n uses :owned but type i64 is not cleanup-owning")
    (compiler-typecheck-program-error-ok?
      (compiler-typecheck-cleanup-struct-repr-c-ast-program)
      "typecheck: cleanup-owning struct Bad cannot use repr c")
    (compiler-typecheck-program-error-ok?
      (compiler-typecheck-cleanup-struct-field-outside-ast-program)
      "typecheck: struct Bad field fd has cleanup metadata but struct is not cleanup-owning")))

(define (compiler-typecheck-cleanup-enum-payload-outside-ast-program) : ast.AstProgram
  (ast.ast-program
    (ast.ast-decl-cons
      (ast.ast-decl-def-enum-id
        (ci.intern-generated-name "Bad")
        (No)
        (ast.ast-variant-def-cons
          (ast.ast-variant-def-id
            (ci.intern-generated-name "A")
            (ast.ast-type-cons (I64) (ast.ast-type-list-new))
            (ast.ast-variant-payload-cleanup-cons
              (ast.ast-variant-payload-cleanup-fn-id
                (ci.intern-syntax-id-from-raw
                  (ci.intern-generated-name "close-fd")))
              (ast.ast-variant-payload-cleanup-list-new)))
          (ast.ast-variant-def-list-new)))
      (ast.ast-decl-list-new))))

(define (compiler-typecheck-cleanup-enum-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
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
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defenum Bad
  (Some FileHandle))"
      "typecheck: enum Bad variant Some stores cleanup-owning type FileHandle without :owned")
    (compiler-typecheck-error-ok?
      "(define (close-bool [fd : bool]) : unit unit)
(defenum Bad
  (:cleanup cleanup-bad)
  (A i64 (:cleanup close-bool)))"
      "typecheck: enum Bad variant A cleanup function close-bool type mismatch: expected (-> i64 unit), found (-> bool unit)")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : i64 fd)
(defenum Bad
  (:cleanup cleanup-bad)
  (A i64 (:cleanup close-fd)))"
      "typecheck: enum Bad variant A cleanup function close-fd type mismatch: expected (-> i64 unit), found (-> i64 i64)")
    (compiler-typecheck-error-ok?
      "(defenum Bad
  (:cleanup cleanup-bad)
  (A i64 (:owned)))"
      "typecheck: enum Bad variant A uses :owned but type i64 is not cleanup-owning")
    (compiler-typecheck-program-error-ok?
      (compiler-typecheck-cleanup-enum-payload-outside-ast-program)
      "typecheck: enum Bad variant A has payload cleanup metadata but enum is not cleanup-owning")))

(define (compiler-typecheck-result-try-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (read [flag : bool]) : result_i64_string.Result
  (if flag (result_i64_string.ok 41) (result_i64_string.err \"read failed\")))
(define (step [flag : bool]) : result_i64_string.Result
  (result_i64_string.ok (try (read flag))))
(define (main [a : bool] [b : bool]) : result_i64_string.Result
  (let [x : i64 (try (step a))]
    [y : i64 0]
    (begin
      (set! y (try (read b)))
      (result_i64_string.ok (+ x y)))))")
    (compiler-typecheck-ok?
      "(defenum TryCount (SomeCount i64) (NoneCount))
(defenum MaybeBool (NoneBool) (SomeBool bool))
(define (read [flag : bool]) : TryCount
  (if flag (SomeCount 41) NoneCount))
(define (main [flag : bool]) : MaybeBool
  (let [x : i64 (try (read flag))]
    (SomeBool (> x 0))))")
    (compiler-typecheck-error-ok?
      "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (main) : result_i64_string.Result
  (result_i64_string.ok (try 1)))"
      "typecheck: try operand must be Result-like enum")
    (compiler-typecheck-error-ok?
      "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (read) : result_i64_string.Result (result_i64_string.ok 1))
(define (main) : i64
  (try (read)))"
      "typecheck: try requires enclosing Result-like function")
    (compiler-typecheck-error-ok?
      "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(defenum OtherResult (OkOther i64) (ErrOther i64))
(define (read) : OtherResult (ErrOther 7))
(define (main) : result_i64_string.Result
  (result_i64_string.ok (try (read))))"
      "typecheck: try error type mismatch: expected String, found i64")
    (compiler-typecheck-error-ok?
      "(defenum TryCount (SomeCount i64) (NoneCount))
(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (read) : TryCount (SomeCount 1))
(define (main) : result_i64_string.Result
  (result_i64_string.ok (try (read))))"
      "typecheck: try carrier mismatch")
    (compiler-typecheck-error-ok?
      "(defenum TryPayloadless (SomePayloadless) (NonePayloadless))
(define (read) : TryPayloadless SomePayloadless)
(define (main) : i64
  (try (read)))"
      "typecheck: try operand must be Result-like enum")
    (compiler-typecheck-error-ok?
      "(defenum TryPayloadedNone (SomePayloadedNone i64) (NonePayloadedNone i64))
(define (read) : TryPayloadedNone (SomePayloadedNone 1))
(define (main) : i64
  (try (read)))"
      "typecheck: try operand must be Result-like enum")
    ;; A payload-free Ok yields unit, and the enclosing family's Ok may carry
    ;; no payload or several; an operand's Ok still carries at most one.
    (compiler-typecheck-ok?
      "(defenum TryCheck (OkCheck) (ErrCheck i64))
(defenum TryPair (OkPair i64 bool) (ErrPair i64))
(define (check [flag : bool]) : TryCheck
  (if flag OkCheck (ErrCheck 7)))
(define (validate [flag : bool]) : TryCheck
  (let [u : unit (try (check flag))] OkCheck))
(define (main [flag : bool]) : TryPair
  (begin (try (validate flag)) (OkPair 1 flag)))")
    (compiler-typecheck-error-ok?
      "(defenum TryPair (OkPair i64 bool) (ErrPair i64))
(defenum TrySingle (OkSingle i64) (ErrSingle i64))
(define (pair) : TryPair (OkPair 1 true))
(define (main) : TrySingle
  (OkSingle (try (pair))))"
      "typecheck: try operand must be Result-like enum")
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (main [flag : bool]) : result_i64_string.Result
  (if flag (io.panic \"stop\") (result_i64_string.ok 1)))"))
    (compiler-typecheck-try-query-tests-ok?)))

(define (compiler-typecheck-move-kind-copyable-group-ok?
  [ctx : tc_core.TcContext]) : bool
  (and
    (tc_core.tc-type-copyable? ctx (I64))
    (tc_core.tc-type-copyable? ctx (I32))
    (tc_core.tc-type-copyable? ctx (F64))
    (tc_core.tc-type-copyable? ctx (F32))
    (tc_core.tc-type-copyable? ctx (Bool))
    (tc_core.tc-type-copyable? ctx (Char))
    (tc_core.tc-type-copyable? ctx (Unit))
    (tc_core.tc-type-copyable? ctx (Never))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-func (ast.ast-type-list-new) (I64)))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-ptr
        (ast.ast-ty-region cbi.compiler-builtin-id-fix-value (String))))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-mut-ptr (ast.ast-ty-dyn-array (I64))))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (String)))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (Str)))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (Bytes)))
    ;; Arrays and tuples are structurally Copyable.
    (tc_core.tc-type-copyable? ctx (ast.ast-ty-array (I64) 4))
    (tc_core.tc-type-copyable? ctx (ast.ast-ty-array (I64) 0))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-tuple
        (ast.ast-type-cons
          (I64)
          (ast.ast-type-cons (Bool) (ast.ast-type-list-new)))))
    (tc_core.tc-type-copyable? ctx (ast.ast-ty-tuple (ast.ast-type-list-new)))
    (tc_core.tc-type-copyable? ctx (Struct (ci.intern "Scalar")))
    (tc_core.tc-type-copyable? ctx (Struct (ci.intern "ScalarC")))
    (tc_core.tc-type-copyable? ctx (Enum (ci.intern "ScalarEnum")))
    ;; One recursive positive chain covers array + tuple +
    ;; struct + enum + shared reference.
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-struct-args
        (ci.intern "NestedCopy")
        (ast.ast-lifetime-cons
          cbi.compiler-builtin-id-fix-n
          (ast.ast-lifetime-list-new))))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-enum-args
        (ci.intern "NestedChoice")
        (ast.ast-lifetime-cons
          cbi.compiler-builtin-id-fix-n
          (ast.ast-lifetime-list-new))))
    ;; Lifetime arguments do not affect Copy; shared refs do.
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-struct-args
        (ci.intern "RefBox")
        (ast.ast-lifetime-cons
          cbi.compiler-builtin-id-fix-n
          (ast.ast-lifetime-list-new))))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-enum-args
        (ci.intern "RefOption")
        (ast.ast-lifetime-cons
          cbi.compiler-builtin-id-fix-n
          (ast.ast-lifetime-list-new))))
    (tc_core.tc-type-copyable? ctx (I64))))

(define (compiler-typecheck-move-kind-move-only-group-ok?
  [ctx : tc_core.TcContext]) : bool
  (and
    (tc_core.tc-type-move-only? ctx (String))
    (tc_core.tc-type-move-only? ctx (Str))
    (tc_core.tc-type-move-only? ctx (Bytes))
    (tc_core.tc-type-move-only? ctx (ast.ast-ty-dyn-array (I64)))
    ;; Zero-length arrays still classify by element.
    (tc_core.tc-type-move-only? ctx (ast.ast-ty-array (String) 0))
    (tc_core.tc-type-move-only? ctx (ast.ast-ty-box (I64)))
    (tc_core.tc-type-move-only? ctx (Struct (ci.intern "Box")))
    (tc_core.tc-type-move-only? ctx (Enum (ci.intern "MoveOnlyEnum")))
    (tc_core.tc-type-move-only? ctx (Struct (ci.intern "CleanupScalar")))
    (tc_core.tc-type-move-only? ctx (Enum (ci.intern "CleanupEnum")))
    (tc_core.tc-type-move-only? ctx (Struct (ci.intern "Cycle")))
    ;; Nested enum/struct poison must propagate through every aggregate layer.
    (tc_core.tc-type-move-only? ctx (Enum (ci.intern "PoisonChoice")))
    (tc_core.tc-type-move-only? ctx (Struct (ci.intern "NestedPoison")))
    ;; Missing lifetime arguments are conservative.
    (tc_core.tc-type-move-only? ctx (Struct (ci.intern "RefBox")))
    (tc_core.tc-type-move-only?
      ctx
      (ast.ast-ty-enum-args (ci.intern "RefOption") (ast.ast-lifetime-list-new)))
    (tc_core.tc-type-move-only?
      ctx
      (ast.ast-ty-mut-ref cbi.compiler-builtin-id-fix-value (I64)))
    (tc_core.tc-type-move-only?
      ctx
      (ast.ast-ty-tuple
        (ast.ast-type-cons
          (Struct (ci.intern "Box"))
          (ast.ast-type-cons
            (ast.ast-ty-dyn-array (I64))
            (ast.ast-type-list-new)))))))

(define (compiler-typecheck-move-kind-wrapper-group-ok?
  [ctx : tc_core.TcContext]) : bool
  (and
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-region cbi.compiler-builtin-id-fix-n (I64)))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-region
        cbi.compiler-builtin-id-fix-n
        (ast.ast-ty-ref cbi.compiler-builtin-id-fix-value (String))))
    (tc_core.tc-type-copyable?
      ctx
      (ast.ast-ty-region
        cbi.compiler-builtin-id-fix-n
        (ast.ast-ty-tuple (ast.ast-type-cons (I64) (ast.ast-type-list-new)))))
    (tc_core.tc-type-move-only?
      ctx
      (ast.ast-ty-region cbi.compiler-builtin-id-fix-n (String)))
    (tc_core.tc-type-move-only?
      ctx
      (ast.ast-ty-region
        cbi.compiler-builtin-id-fix-value
        (ast.ast-ty-mut-ref cbi.compiler-builtin-id-fix-value (I64))))
    (tc_core.tc-type-copyable? ctx (I64))
    (tc_core.tc-type-move-only? ctx (String))))

(define (compiler-typecheck-move-kind-memo
  [ctx : tc_core.TcContext]
  [name : String]) : i64
  (tc_core.tc-type-handle-cache-move-kind
    (tc_core.tc-job-state-nominal-cache (tc_core.tc-context-job-state ctx))
    (tc_core.tc-context-symbols-ref (& ctx))
    (ci.intern name)))

;; A top-level nominal kind is memoized beside its type-handle slot; one reached
;; only through another declaration's fields is not. `Scalar` has no nominal
;; field and `Cycle` looks up only itself, so no other key can evict them
;; between the query and the check. A second pass is answered from the memo and
;; must agree with the first.
(define (compiler-typecheck-move-kind-memo-ok? [ctx : tc_core.TcContext]) : bool
  (and
    (tc_core.tc-type-copyable? ctx (Struct (ci.intern "Scalar")))
    (= (compiler-typecheck-move-kind-memo ctx "Scalar") 1)
    (tc_core.tc-type-move-only? ctx (Struct (ci.intern "Cycle")))
    (= (compiler-typecheck-move-kind-memo ctx "Cycle") 2)
    (tc_core.tc-type-move-only? ctx (Struct (ci.intern "NestedPoison")))
    (= (compiler-typecheck-move-kind-memo ctx "TextPacket") 0)
    (compiler-typecheck-move-kind-copyable-group-ok? ctx)
    (compiler-typecheck-move-kind-move-only-group-ok? ctx)
    (compiler-typecheck-move-kind-wrapper-group-ok? ctx)))

(define (compiler-typecheck-move-kind-fixture-tests-ok?) : bool
  (match (parser.parse-ast-source
    "(defstruct Scalar (value i64))
(defenum ScalarEnum (None) (Some i64))
(defstruct ScalarC
  (:repr c)
  (value i64))
(defstruct RefBox (:lifetimes a) (value (& a i64)))
(defstruct NestedCopy (:lifetimes a)
  (array (Array i64 2))
  (tuple (Tuple i64 (& a i64)))
  (scalar ScalarC)
  (choice ScalarEnum))
(defenum NestedChoice (:lifetimes a)
  (None)
  (SomeNested (NestedCopy a)))
(defstruct CleanupScalar (:cleanup cleanup-scalar) (value i64))
(defenum CleanupEnum (:cleanup cleanup-enum) (Value i64))
(defstruct Cycle (next Cycle))
(defstruct TextPacket (text String))
(defenum PoisonChoice (None) (Text TextPacket))
(defstruct NestedPoison (choice PoisonChoice))
(defenum RefOption (:lifetimes a) (None) (SomeRef (& a i64)))
(defenum MoveOnlyEnum (Text String))")
    [(Ok program)
      (match (csym.build-compiler-symbols program)
        [(Ok symbols)
          (match (csym.build-compiler-registries program)
            [(Ok registries)
              (let
                [ctx : tc_core.TcContext
                  (tc_core.tc-context-new
                    program
                    symbols
                    registries
                    ""
                    cbi.compiler-builtin-id-fix-empty
                    (ast.ast-node-pool-context-capture-active))]
                (and
                  (compiler-typecheck-move-kind-copyable-group-ok? ctx)
                  (compiler-typecheck-move-kind-move-only-group-ok? ctx)
                  (compiler-typecheck-move-kind-wrapper-group-ok? ctx)
                  (compiler-typecheck-move-kind-memo-ok? ctx)))]
            [(Err _) false])]
        [(Err _) false])]
    [(Err _) false]))

;; Function bodies typecheck against a function-local fork of the module
;; environment (#8375): zero and many parameters, shadows, arena and unsafe
;; markers, CTFE and a body that crosses several binding segments, checked
;; twice as two jobs. An invalid body is reported once while later functions
;; still see every parent signature.
(define (compiler-typecheck-function-store-fork-tests-ok?) : bool
  (let
    [ok-source : String
      "(import stdlib.arena)
(defstruct Pair (a i64) (b i64))
(define (zero) : i64 7)
(define (many [a : i64] [b : i64] [c : i64] [d : i64] [e : i64] [f : i64] [g : i64] [h : i64] [i : i64]) : i64 (+ a i))
(define (shadow [x : i64]) : i64
  (let [x : bool true] [x : i64 (zero)] (+ x (many x x x x x x x x x))))
(define (marks [p : Pair]) : i64
  (let [s (arena.make)]
    (begin (in-arena s (Pair 1 2)) (arena.destroy-safe! s) (unsafe (+ p.a p.b)))))
(define (folded) : i64 (comptime (+ 40 2)))
(define (deep [n : i64]) : i64
  (let
    [a0 : i64 n]
    [a1 : i64 a0]
    [a2 : i64 a1]
    [a3 : i64 a2]
    [a4 : i64 a3]
    [a5 : i64 a4]
    [a6 : i64 a5]
    [a7 : i64 a6]
    [a8 : i64 a7]
    [a9 : i64 a8]
    [a10 : i64 a9]
    [a11 : i64 a10]
    [a12 : i64 a11]
    [a13 : i64 a12]
    [a14 : i64 a13]
    [a15 : i64 a14]
    [a16 : i64 a15]
    [a17 : i64 a16]
    [a18 : i64 a17]
    [a19 : i64 a18]
    [a20 : i64 a19]
    [a21 : i64 a20]
    [a22 : i64 a21]
    [a23 : i64 a22]
    [a24 : i64 a23]
    [a25 : i64 a24]
    [a26 : i64 a25]
    [a27 : i64 a26]
    [a28 : i64 a27]
    [a29 : i64 a28]
    [a30 : i64 a29]
    [a31 : i64 a30]
    [a32 : i64 a31]
    [a33 : i64 a32]
    [a34 : i64 a33]
    [a35 : i64 a34]
    [a36 : i64 a35]
    [a37 : i64 a36]
    [a38 : i64 a37]
    [a39 : i64 a38]
    [a40 : i64 a39]
    [a41 : i64 a40]
    [a42 : i64 a41]
    [a43 : i64 a42]
    [a44 : i64 a43]
    [a45 : i64 a44]
    [a46 : i64 a45]
    [a47 : i64 a46]
    [a48 : i64 a47]
    [a49 : i64 a48]
    [a50 : i64 a49]
    [a51 : i64 a50]
    [a52 : i64 a51]
    [a53 : i64 a52]
    [a54 : i64 a53]
    [a55 : i64 a54]
    [a56 : i64 a55]
    [a57 : i64 a56]
    [a58 : i64 a57]
    [a59 : i64 a58]
    [a60 : i64 a59]
    [a61 : i64 a60]
    [a62 : i64 a61]
    [a63 : i64 a62]
    [a64 : i64 a63]
    [a65 : i64 a64]
    [a66 : i64 a65]
    [a67 : i64 a66]
    [a68 : i64 a67]
    [a69 : i64 a68]
    [a70 : i64 a69]
    [a71 : i64 a70]
    [a72 : i64 a71]
    [a73 : i64 a72]
    [a74 : i64 a73]
    [a75 : i64 a74]
    [a76 : i64 a75]
    [a77 : i64 a76]
    [a78 : i64 a77]
    [a79 : i64 a78]
    a79))
(define (main) : i64 (+ (shadow 1) (marks (Pair 3 4)) (deep 2) (zero) (folded)))"]
    [bad-source : String
      "(define (first [x : i64]) : i64 (+ x 1))
(define (broken [y : i64]) : bool (+ y (first y)))
(define (later [z : i64]) : i64 (first (first z)))
(define (main) : i64 (later 1))"]
    (and
      (compiler-typecheck-ok? (stdlib.string.copy (& ok-source)))
      (compiler-typecheck-ok? (stdlib.string.copy (& ok-source)))
      (compiler-typecheck-error-count-ok?
        (stdlib.string.copy (& bad-source))
        "typecheck: return type mismatch: expected bool, found i64"
        1)
      (compiler-typecheck-error-count-ok?
        bad-source
        "typecheck: return type mismatch: expected bool, found i64"
        1))))

(define (compiler-typecheck-move-kind-tests-ok?) : bool
  (compiler-typecheck-move-kind-fixture-tests-ok?))

(define (compiler-typecheck-raw-pointer-render-ok?) : bool
  (and
    (string.eq (tc_core.tc-type-render (ast.ast-ty-ptr (I64))) "(Ptr i64)")
    (string.eq
      (tc_core.tc-type-render (ast.ast-ty-mut-ptr (ast.ast-ty-ptr (U8))))
      "(MutPtr (Ptr u8))")
    (tc_core.tc-type-eq (ast.ast-ty-ptr (I64)) (ast.ast-ty-ptr (I64)))
    (not (tc_core.tc-type-eq (ast.ast-ty-ptr (I64)) (ast.ast-ty-mut-ptr (I64))))
    (tc_core.tc-type-eq
      (ast.ast-ty-ptr (ast.ast-ty-region cbi.compiler-builtin-id-fix-n (I64)))
      (ast.ast-ty-ptr (I64)))))

(define (compiler-typecheck-raw-pointer-op-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
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
    (compiler-typecheck-ok?
      "(define (main [n : u64]) : (Ptr u8)
  (unsafe (ptr-cast (int->ptr n : (MutPtr i64)) : (Ptr u8))))")
    (compiler-typecheck-ok?
      "(define (main [text : String]) : (MutPtr String)
  (unsafe (ptr-addr-of text)))")
    (compiler-typecheck-ok?
      "(defstruct Wide (x i64) (y i64) (z i64))
(define (main) : (MutPtr i64)
  (let [item : Wide (Wide 1 2 3)]
    (unsafe (ptr-addr-of item.y))))")
    (compiler-typecheck-ok?
      "(defstruct Pair (x i64) (y i64))
(define (main) : (MutPtr i64)
  (let [item : Pair (Pair 1 2)]
    (unsafe (ptr-addr-of item.y))))")
    (compiler-typecheck-ok?
      "(defstruct Pair (x i64) (y i64))
(define (main) : (MutPtr Pair)
  (let [item : Pair (Pair 1 2)]
    (unsafe (ptr-addr-of item))))")
    (compiler-typecheck-ok?
      "(defstruct Tiny (a i32) (b i32))
(defstruct Wrap (tiny Tiny))
(define (main) : (MutPtr i32)
  (let [item : Wrap (Wrap (Tiny (cast 1 : i32) (cast 2 : i32)))]
    (unsafe (ptr-addr-of item.tiny.b))))")
    (compiler-typecheck-ok?
      "(define (main [i : i64]) : (MutPtr i64)
  (let [items : (Array i64 2) (array 1 2)]
    (unsafe (ptr-addr-of (array-ref items i)))))")
    (compiler-typecheck-ok?
      "(defstruct Bag (slots (Array i64 2)))
(define (main [i : i64]) : (MutPtr i64)
  (let [bag : Bag (Bag (array 1 2))]
    (unsafe (ptr-addr-of (array-ref bag.slots i)))))")
    (compiler-typecheck-ok?
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
    (compiler-typecheck-ok?
      "(define (main
  [r64 : (Ptr i64)]
  [p64 : (MutPtr i64)]
  [q64 : (MutPtr u64)]
  [r32 : (Ptr u32)]
  [p32 : (MutPtr i32)]
  [q32 : (MutPtr u32)]) : i64
  (unsafe
    (begin
      (volatile-load r64)
      (volatile-store! p64 1)
      (volatile-store! q64 (cast 1 : u64))
      (volatile-load r32)
      (volatile-store! p32 (cast 1 : i32))
      (volatile-store! q32 (cast 1 : u32))
      (volatile-load p64))))")
    (compiler-typecheck-error-ok?
      "(define (main [x : i64]) : (MutPtr i64) (ptr-addr-of x))"
      "typecheck: ptr-addr-of requires unsafe context")
    (compiler-typecheck-error-ok?
      "(define (main [p : (Ptr i64)]) : i64
  (let [__tl_unsafe_context : unit unit] (ptr-read p)))"
      "typecheck: ptr-read requires unsafe context")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (unsafe (syscall true)))"
      "typecheck: syscall operands must be integer")
    (compiler-typecheck-error-ok?
      "(define (main [p : (Ptr i64)]) : unit (unsafe (ptr-write! p 1)))"
      "typecheck: ptr-write! requires a MutPtr pointer operand")
    (compiler-typecheck-error-ok?
      "(define (main [p : (MutPtr i64)]) : unit (unsafe (ptr-write! p true)))"
      "typecheck: ptr-write! value type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main [p : (Ptr i64)]) : (Ptr i64) (unsafe (ptr-offset p true)))"
      "typecheck: ptr-offset requires an integer offset")
    (compiler-typecheck-error-ok?
      "(define (main [p : (Ptr i64)]) : i64 (unsafe (ptr-cast p : i64)))"
      "typecheck: ptr-cast target must be a raw pointer type")
    (compiler-typecheck-error-ok?
      "(define (main [b : bool]) : (Ptr i64) (unsafe (int->ptr b : (Ptr i64))))"
      "typecheck: int->ptr requires an integer operand")
    ;; Globals are permanent places. Taking their address is permitted only at
    ;; this explicit unsafe boundary; the global-move guard still rejects a
    ;; normal by-value transfer of non-Copy global storage.
    (compiler-typecheck-ok?
      "(define x : i64 1)
(define (main) : (MutPtr i64) (unsafe (ptr-addr-of x)))")
    (compiler-typecheck-error-ok?
      "(define (main [items : (__tl_dyn-array i64)] [i : i64]) : (MutPtr i64)
  (unsafe (ptr-addr-of (array-ref items i))))"
      "typecheck: ptr-addr-of dynamic array elements are not addressable; use __tl_array-data plus ptr-offset")
    (compiler-typecheck-ok?
      "(define (main [r : (& r i64)]) : (MutPtr (& r i64))
  (unsafe (ptr-addr-of r)))")
    (compiler-typecheck-ok?
      "(define (main [r : (&mut r i64)]) : (MutPtr (&mut r i64))
  (unsafe (ptr-addr-of r)))")
    (compiler-typecheck-error-ok?
      "(defstruct Cell (value i64))
(define (main [r : (& r Cell)]) : (MutPtr i64)
  (unsafe (ptr-addr-of r.value)))"
      "typecheck: ptr-addr-of requires a local/parameter, dotted field, or fixed-array array-ref place")
    (compiler-typecheck-error-ok?
      "(define (main [x : i64]) : (MutPtr i64)
  (unsafe (ptr-addr-of (+ x 1))))"
      "typecheck: ptr-addr-of requires a local/parameter, dotted field, or fixed-array array-ref place")
    (compiler-typecheck-error-ok?
      "(define (main [p : (MutPtr i64)]) : i64
  (atomic-load p))"
      "typecheck: atomic-load requires unsafe context")
    (compiler-typecheck-error-ok?
      "(define (main [p : (MutPtr i64)]) : unit
  (unsafe (atomic-store! p true)))"
      "typecheck: atomic value type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main [p : (Ptr i64)]) : unit
  (unsafe (atomic-add! p 1)))"
      "typecheck: atomic-add! requires a MutPtr pointer operand")
    (compiler-typecheck-error-ok?
      "(define (main [p : (MutPtr u8)]) : u8
  (unsafe (atomic-load p)))"
      "typecheck: atomic pointer element must be i32, i64, u32, or u64")
    (compiler-typecheck-error-ok?
      "(define (main [p : (Ptr i64)]) : i64
  (volatile-load p))"
      "typecheck: volatile-load requires unsafe context")
    (compiler-typecheck-error-ok?
      "(define (main [p : (MutPtr i64)]) : unit
  (unsafe (volatile-store! p true)))"
      "typecheck: volatile value type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main [p : (Ptr i64)]) : unit
  (unsafe (volatile-store! p 1)))"
      "typecheck: volatile-store! requires a MutPtr pointer operand")
    (compiler-typecheck-error-ok?
      "(define (main [p : (Ptr u8)]) : u8
  (unsafe (volatile-load p)))"
      "typecheck: volatile pointer element must be i32, i64, u32, or u64")))

(define (compiler-typecheck-raw-pointer-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(extern (raw-sink [arg0 : (Ptr i64)]) : unit)
(extern (raw-make) : (MutPtr (Ptr u8)))
(define (main [p : (Ptr i64)]) : unit
  (raw-sink p))")
    (compiler-typecheck-raw-pointer-render-ok?)))

(define (compiler-typecheck-extern-head-varargs-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(extern (local-add [a : i64] [b : i64]) : i64 (:symbol \"foreign_add_exact\"))
(define (main) : i64
  (local-add 1 2))")
    (compiler-typecheck-ok?
      "(extern (printf [fmt : (Ptr u8)] ...) : i32 (:symbol \"printf\"))
(define (main [fmt : (Ptr u8)]) : i64
  (cast (printf fmt 1 2.0) : i64))")
    (compiler-typecheck-ok?
      "(extern (sumf [count : i64] [value : ...f64]) : i32 (:symbol \"sumf\"))
(define (main) : i64
  (cast (sumf 2 1.0 2.0) : i64))")
    (compiler-typecheck-error-ok?
      "(extern (sumf [count : i64] [value : ...f64]) : i32 (:symbol \"sumf\"))
(define (main) : i64
  (cast (sumf 1 true) : i64))"
      "typecheck: call `sumf` argument 2 type mismatch: expected f64, found bool")
    (compiler-typecheck-ok?
      "(defenum VarargPayload (VarargPayloadI64 i64))
(extern (bad [count : i64] [value : ...VarargPayload]) : i64 (:symbol \"bad\"))")
    (compiler-typecheck-ok?
      "(extern (resolve [name : (Ptr u8)]) : (CFunc non-null (-> i64 i64)) (:symbol \"resolve\"))
(define (main) : i64
  (let [resolved : (CFunc non-null (-> i64 i64)) (resolve (ptr-null : (Ptr u8)))]
    (resolved 41)))")
    (compiler-typecheck-error-ok?
      "(extern raw-fn (:symbol \"tl_test_raw_fn\") : (-> i64 i64))
(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64 (f x))
(define (main) : i64
  (let [copied : (-> i64 i64) raw-fn]
    (apply1 copied 41)))"
      "typecheck: raw C function pointer requires an explicit CFunc type")
    (compiler-typecheck-error-ok?
      "(extern (resolve [name : (Ptr u8)]) : (-> i64 i64) (:symbol \"resolve\"))
(define (apply1 [f : (-> i64 i64)] [x : i64]) : i64 (f x))
(define (main) : i64
  (apply1 (resolve (ptr-null : (Ptr u8))) 41))"
      "typecheck: raw C function pointer requires an explicit CFunc type")))

(define (compiler-typecheck-extern-abi-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defstruct Box (value i64))
(extern (foreign-callback [arg0 : (Ptr i64)] [arg1 : (-> i64 i64)]) : i64 (:abi c) (:symbol \"foreign_callback\") (:link-lib \"ffi_callback\") (:link-search \"native\") (:link-arg \"-Wl,--whole-archive\"))
(extern (foreign-box [arg0 : Box]) : unit (:abi c) (:symbol \"foreign_box\"))")
    (compiler-typecheck-ok?
      "(extern (observe [value : String]) : unit)
(define (main) : String
  (let [value : String \"retained\"]
    (begin
      (observe value)
      value)))")
    (compiler-typecheck-extern-head-varargs-tests-ok?)
    (compiler-typecheck-error-location-ok?
      "(module main)
(extern (bad [arg0 : (Tuple i64 i64)]) : i64 (:abi c) (:symbol \"bad_tuple\"))"
      "typecheck: extern ABI c does not support parameter type (Tuple i64 i64)"
      2
      1)
    (compiler-typecheck-error-ok?
      "(extern (bad [arg0 : (Array i64 2)]) : i64 (:abi c) (:symbol \"bad_array\"))"
      "typecheck: extern ABI c does not support parameter type (Array i64 2)")
    ;; Scalar `f32` is a supported C ABI extern parameter and return type
    ;; (passed/returned in XMM registers via single-precision `movss`).
    (compiler-typecheck-ok?
      "(extern (bad [arg0 : f32]) : f32 (:abi c) (:symbol \"bad_f32\"))")
    (compiler-typecheck-ok?
      "(defenum Status (Ready) (Done) (Failed))
(extern (status-echo [arg0 : Status]) : Status (:abi c) (:symbol \"status_echo\"))
(extern (status-varargs [arg0 : Status] [arg1 : ...Status]) : i64 (:abi c) (:symbol \"status_varargs\"))
(extern status-echo-ptr (:symbol \"status_echo_ptr\") : (CFunc non-null (-> Status Status)))
(define (main) : i64
  (let
    [copied : (CFunc non-null (-> Status Status)) status-echo-ptr]
    [echoed : Status (status-echo (Ready))]
    [copied-echoed : Status (copied echoed)]
    (status-varargs copied-echoed (Done) (Failed))))")
    (compiler-typecheck-ok?
      "(defenum AbiPayload (AbiPayloadI64 i64))
(extern (bad [arg0 : AbiPayload]) : i64 (:abi c) (:symbol \"bad_enum_param\"))")
    (compiler-typecheck-ok?
      "(defenum AbiPayload (AbiPayloadI64 i64))
(extern (bad [arg0 : i64]) : AbiPayload (:abi c) (:symbol \"bad_enum_return\"))")
    (compiler-typecheck-ok?
      "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))
(extern (bad [arg0 : (RefOption n)]) : i64 (:abi c) (:symbol \"bad_enum_args_param\"))")
    (compiler-typecheck-ok?
      "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))
(extern (bad [arg0 : i64]) : (RefOption n) (:abi c) (:symbol \"bad_enum_args_return\"))")))

(define (compiler-typecheck-reference-return-param-ref-source) : String
  "(define (id [r : (& n i64)]) : (& n i64) r)
(define (main [n : i64]) : (& n i64)
  (id (& n)))")

(define (compiler-typecheck-owner-model-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [x : i64 1]
    (let [r : (& x i64) (& x)] x)))")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : (& n i64)
  (let [x : i64 1] (& x)))"
      "typecheck: reference value would escape lexical scope")
    (compiler-typecheck-ok?
      (compiler-typecheck-reference-return-param-ref-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : String
  (let
    [text : String (string.int->string 42)]
    (with-arena phase
      (let [n : i64 (__tl_string_length text)] text))))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : i64
  (with-arena phase
    (let
      [text : String (string.int->string 42)]
      (__tl_string_length text))))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : String
  (with-arena phase (string.int->string 42)))")
      "typecheck: region-tagged value cannot escape with-arena 'phase'")
    (compiler-typecheck-ok?
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
    [owner : Arena (arena-make-atomic)]
    [channel : ChannelString (ChannelString 0)]
    [message (in-arena owner (string.append \"atom\" \"ic\"))]
    (match (channel-string-send channel message)
      [(ChannelStringSendOk) 42]
      [(ChannelStringSendErr _) 2])))"))
    (compiler-typecheck-ok?
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
    [owner : Arena (arena-make-atomic)]
    [channel : ChannelString (ChannelString 0)]
    [message (in-arena owner (string.append \"atom\" \"ic\"))]
    [sent : ChannelStringSendResult (channel-string-send channel message)]
    (match sent
      [(ChannelStringSendOk) 42]
      [(ChannelStringSendErr _) 2])))"))
    (compiler-typecheck-error-ok?
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
    [owner : Arena (arena-make)]
    [channel : ChannelString (ChannelString 0)]
    [message (in-arena owner (string.append \"ordinary\" \"arena\"))]
    [sent : ChannelStringSendResult (channel-string-send channel message)]
    42))")
      "typecheck: cannot pass region-tagged value to function parameter; region value would escape")
    (compiler-typecheck-ok? (compiler-typecheck-with-escape-string-source))))

(define (compiler-typecheck-reference-render-ok?) : bool
  (let
    [string-ref-render-ok : bool
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (String)))
        "(& n String)")]
    [str-ref-render-ok : bool
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (Str)))
        "(& n str)")]
    [bytes-ref-render-ok : bool
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (Bytes)))
        "(& n bytes)")]
    [bytes-mut-ref-render-ok : bool
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-ty-mut-ref cbi.compiler-builtin-id-fix-n (Bytes)))
        "(&mut n bytes)")]
    [mut-ref-render-ok : bool
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-ty-mut-ref
            cbi.compiler-builtin-id-fix-value
            (ast.ast-ty-dyn-array (I64))))
        "(&mut value (__tl_dyn-array i64))")]
    [structural-lifetime-source : i64 (ci.intern "macro-lifetime")]
    [intern-state : ci.InternCompatState
      (ci.intern-compat-state-capture-active)]
    [structural-session : cis.InternStructuralSessionHandle
      (cis.intern-structural-session-handle-from-source-names
        (ci.intern-source-name-session-handle-from-state intern-state))]
    [structural-lifetime-render-ok : bool
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-ty-ref
            (cis.intern-fresh-local-identity-raw
              (cis.intern-structural-session-fresh-local-identity
                structural-session
                7
                structural-lifetime-source))
            (I64)))
        "(& macro-lifetime i64)")]
    [invalid-lifetime-render-ok : bool
      (string.eq
        (tc_core.tc-type-render (ast.ast-ty-ref (ci.intern-capacity) (I64)))
        (str_cat.str-cat
          "(& <id:"
          (string.int->string (ci.intern-capacity))
          "> i64)"))]
    [nominal-lifetime-render-ok : bool
      (string.eq
        (tc_core.tc-type-render
          (ast.ast-ty-struct-args
            (ci.intern "RefBox")
            (ast.ast-lifetime-cons
              cbi.compiler-builtin-id-fix-n
              (ast.ast-lifetime-list-new))))
        "(RefBox n)")]
    [str-eq-ok : bool (tc_core.tc-type-eq (Str) (Str))]
    [str-distinct-ok : bool (not (tc_core.tc-type-eq (Str) (String)))]
    [bytes-eq-ok : bool (tc_core.tc-type-eq (Bytes) (Bytes))]
    [bytes-distinct-ok : bool (not (tc_core.tc-type-eq (Bytes) (Str)))]
    [nominal-lifetime-distinct-ok : bool
      (not
        (tc_core.tc-type-eq
          (ast.ast-ty-struct-args
            (ci.intern "RefBox")
            (ast.ast-lifetime-cons
              cbi.compiler-builtin-id-fix-n
              (ast.ast-lifetime-list-new)))
          (ast.ast-ty-struct-args
            (ci.intern "RefBox")
            (ast.ast-lifetime-cons
              cbi.compiler-builtin-id-fix-m
              (ast.ast-lifetime-list-new)))))]
    [region-erased-eq-ok : bool
      (tc_core.tc-type-eq
        (ast.ast-ty-ref
          cbi.compiler-builtin-id-fix-n
          (ast.ast-ty-region cbi.compiler-builtin-id-fix-value (I64)))
        (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (I64)))]
    [region-distinct-ok : bool
      (not
        (tc_core.tc-type-eq
          (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (I64))
          (ast.ast-ty-ref cbi.compiler-builtin-id-fix-m (I64))))]
    [mut-distinct-ok : bool
      (not
        (tc_core.tc-type-eq
          (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (I64))
          (ast.ast-ty-mut-ref cbi.compiler-builtin-id-fix-n (I64))))]
    [region-contains-ok : bool
      (tc_core.tc-type-contains-region
        (ast.ast-ty-ref cbi.compiler-builtin-id-fix-n (I64))
        cbi.compiler-builtin-id-fix-n)]
    [inner-region-contains-ok : bool
      (tc_core.tc-type-contains-region
        (ast.ast-ty-mut-ref
          cbi.compiler-builtin-id-fix-value
          (ast.ast-ty-region cbi.compiler-builtin-id-fix-m (String)))
        cbi.compiler-builtin-id-fix-m)]
    (and
      string-ref-render-ok
      str-ref-render-ok
      bytes-ref-render-ok
      bytes-mut-ref-render-ok
      mut-ref-render-ok
      structural-lifetime-render-ok
      invalid-lifetime-render-ok
      str-eq-ok
      str-distinct-ok
      bytes-eq-ok
      bytes-distinct-ok
      nominal-lifetime-render-ok
      nominal-lifetime-distinct-ok
      region-erased-eq-ok
      region-distinct-ok
      mut-distinct-ok
      region-contains-ok
      inner-region-contains-ok)))

;; A fixed array of lifetime-parameterized records, or of shared references,
;; borrows as a shared Slice (#8111). The shared Slice may shorten the element
;; lifetime; a mutable one may not, and the borrow still keeps its owners.
(define (compiler-typecheck-slice-borrowed-records-source [body : String]) : String
  (str_cat.str-cat
    "(defstruct Item (:lifetimes source) (text (& source str)))
(define (count [items : (& source (Slice (Item source)))]) : i64
  (array-length items))
(define (count-mut [items : (&mut source (Slice (Item source)))]) : i64
  (array-length items))
"
    body))

(define (compiler-typecheck-slice-borrowed-records-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-slice-borrowed-records-source
        "(define (main) : i64
  (let
    [text : String \"payload\"]
    [items : (Array (Item text) 1) (array (Item (& text)))]
    (+ (count (& items)) (count (slice-view items 0 1)))))"))
    (compiler-typecheck-ok?
      "(define (count-refs [r : (& s (Slice (& s i64)))]) : i64 (array-length r))
(define (main) : i64
  (let
    [a : i64 1]
    [refs : (Array (& a i64) 2) (array (& a) (& a))]
    (count-refs (& refs))))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-slice-borrowed-records-source
        "(define (main) : i64
  (let
    [text : String \"payload\"]
    [items : (Array (Item text) 1) (array (Item (& text)))]
    (count-mut (&mut items))))")
      "typecheck: call `count-mut` argument 1 (parameter `items`) type mismatch: expected (&mut source (Slice (Item source))), found (&mut items (Array (Item text) 1)); source lifetime `text` cannot satisfy required lifetime `source` because mutable reference referent type is invariant")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-slice-borrowed-records-source
        "(define (bad [s : (& s str)]) : (& s (Slice (Item s)))
  (let
    [items : (Array (Item s) 1) (array (Item s))]
    (slice-view items 0 1)))
(define (main) : i64 0)")
      "typecheck: reference value would escape lexical scope")))

(define (compiler-typecheck-reference-tests-ok?) : bool
  (let
    [render-ok : bool (compiler-typecheck-reference-render-ok?)]
    [local-ok : bool
      (compiler-typecheck-ok?
        "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (let [r : (& n i64) (& n)]
    (take r)))")]
    [param-ok : bool
      (compiler-typecheck-ok?
        "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& n)))")]
    [projection-ok : bool
      (compiler-typecheck-ok?
        "(defstruct Pair (left i64) (right i64))
(define (take-pair [r : (& p i64)]) : unit unit)
(define (take-tuple [r : (& t i64)]) : unit unit)
(define (take-array [r : (& items i64)]) : unit unit)
(define (main [p : Pair] [t : (Tuple i64 bool)] [items : (__tl_dyn-array i64)]) : unit
  (begin
    (take-pair (& p.left))
    (take-tuple (& (tuple-ref t 0)))
    (take-array (& (array-ref items 0)))))")]
    [str-ok : bool
      (compiler-typecheck-ok?
        "(define (take [s : (& text str)]) : unit unit)
(define (main [text : String]) : unit
  (let [view : (& text str) (& text)]
    (take view)))")]
    [str-auto-borrow-ok : bool
      (compiler-typecheck-ok?
        "(define (take [s : (& text str)]) : unit unit)
(define (main [text : String]) : unit
  (take text))")]
    [str-region-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-with-alloc-string-helper-source
          "(define (take [s : (& r str)]) : unit unit)
(define (main) : unit
  (with-arena r
    (let [text : String (string.int->string 41)]
      (take (& r text)))))"))]
    [temp-call-arg-ok : bool
      (compiler-typecheck-ok?
        "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& (+ n 1))))")]
    [temp-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (let [r (& (+ n 1))] (take r)))"
        "typecheck: a borrowed temporary must be a direct function-call argument")]
    [mismatch-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (take [r : (& n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (& other n)))"
        "typecheck: borrow lifetime mismatch")]
    [return-ok : bool
      (compiler-typecheck-ok? "(define (main [n : i64]) : (& n i64)
  (& n))")]
    [return-param-ref-ok : bool
      (compiler-typecheck-ok?
        (compiler-typecheck-reference-return-param-ref-source))]
    [return-untied-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (main [n : i64]) : (& other i64)
  (& n))"
        "typecheck: returned reference lifetime must be tied to a parameter")]
    [return-local-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (main [n : i64]) : (& n i64)
  (let [x : i64 1] (& x)))"
        "typecheck: reference value would escape lexical scope")]
    [struct-field-ok : bool
      (compiler-typecheck-ok?
        "(defstruct RefBox (value (& n i64)))
(define (main [n : i64]) : i64
  (let
    [box : RefBox (RefBox (& n))]
    (let [value : (& n i64) box.value] 0)))")]
    [enum-payload-ok : bool
      (compiler-typecheck-ok?
        "(defenum RefOption (SomeRef (& n i64)) (NoRef))
(define (main [n : i64]) : i64
  (match (SomeRef (& n))
    [(SomeRef value) 0]
    [(NoRef) 1]))")]
    [lifetime-struct-return-ok : bool
      (compiler-typecheck-ok?
        "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [value : (& n i64)]) : (RefBox n)
  (RefBox value))")]
    [lifetime-struct-field-ok : bool
      (compiler-typecheck-ok?
        "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [n : i64]) : i64
  (let
    [box : (RefBox n) (RefBox (& n))]
    (let [value : (& n i64) box.value] 0)))")]
    [lifetime-enum-match-ok : bool
      (compiler-typecheck-ok?
        "(defenum RefOption (:lifetimes a) (SomeRef (& a i64)) (NoRef))
(define (main [n : i64]) : i64
  (match (SomeRef (& n))
    [(SomeRef value) (let [same : (& n i64) value] 0)]
    [(NoRef) 1]))")]
    [borrowed-enum-match-scalar-ok : bool
      (compiler-typecheck-ok?
        "(defenum Maybe (None) (Some i64))
(define (take [v : (& m i64)]) : i64 7)
(define (main [m : Maybe]) : i64
  (+
    (match (& m)
      [(Some v) (let [same : i64 v] (take (& same)))]
      [None 0])
    (match m
      [(Some _) 1]
      [None 0])))")]
    [borrowed-enum-match-str-ok : bool
      (compiler-typecheck-ok?
        "(defenum Item (Named String) (Empty))
(define (borrowed-name-length [s : (& item str)]) : i64 (__tl_string_length s))
(define (main [item : Item]) : i64
  (match (& item)
    [(Named s) (let [same : (& item str) s] (borrowed-name-length same))]
    [Empty 0]))")]
    [borrowed-enum-match-array-ok : bool
      (compiler-typecheck-ok?
        "(defenum Maybe (None) (Some String))
(define (take [v : (& items str)]) : i64 7)
(define (main [items : (Array Maybe 2)]) : i64
  (match (& (array-ref items 0))
    [(Some v) (let [same : (& items str) v] (take same))]
    [None 0]))")]
    [borrowed-enum-match-ref-struct-array-ok : bool
      (compiler-typecheck-ok?
        "(defenum Slot (Empty) (Occupied String))
(defstruct Bag (slots (__tl_dyn-array Slot)))
(defenum SlotLookup (:lifetimes bag) (SlotMissing) (SlotFound (& bag str)))
(define (take [v : (& bag str)]) : i64 7)
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) (SlotMissing))
(define (slot-found [value : (& bag str)]) : (SlotLookup bag) (SlotFound value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref bag.slots 0))
    [(Occupied v) (let [same : (& bag str) v] (slot-found same))]
    [Empty (slot-missing bag)]))
(define (score [bag : (& bag Bag)]) : i64
  (match (& (array-ref bag.slots 0))
    [(Occupied v) (let [same : (& bag str) v] (take same))]
    [Empty 0]))
(define (main [bag : Bag]) : i64
  (+ (score (& bag))
    (match (lookup (& bag))
      [(SlotFound v) (take v)]
      [SlotMissing 0])))")]
    [borrowed-enum-match-nested-ok : bool
      (compiler-typecheck-ok?
        "(defenum Inner (A i64) (B i64))
(defenum Outer (Wrap Inner) (Empty))
(define (take [v : (& o i64)]) : i64 7)
(define (main [o : Outer]) : i64
  (match (& o)
    [(Wrap (A 0)) 10]
    [(Wrap (A n)) (take n)]
    [(Wrap _) 1]
    [Empty 0]))")]
    [borrowed-enum-match-temp-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defenum Maybe (None) (Some i64))
(define (main) : i64
  (match (& (Some 1))
    [(Some _) 1]
    [None 0]))"
        "typecheck: a borrowed temporary must be a direct function-call argument")]
    [borrowed-enum-match-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        (compiler-typecheck-with-io-source
          "(defenum Maybe (None) (Some String))
(define (main [m : Maybe]) : (& other str)
  (match (& m)
    [(Some v) v]
    [None (io.panic \"none\")]))")
        "typecheck: returned reference lifetime must be tied to a parameter")]
    [returned-borrowed-lookup-assign-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defenum Slot (Empty) (Occupied String))
(defstruct Bag (slots (__tl_dyn-array Slot)))
(defenum SlotLookup (:lifetimes bag) (SlotMissing) (SlotFound (& bag str)))
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) (SlotMissing))
(define (slot-found [value : (& bag str)]) : (SlotLookup bag) (SlotFound value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref bag.slots 0))
    [(Occupied v) (slot-found v)]
    [Empty (slot-missing bag)]))
(define (bad [bag : Bag]) : unit
  (match (lookup (& bag))
    [(SlotFound value) (set! bag (Bag (__tl_make-array Slot 1)))]
    [SlotMissing unit]))"
        "typecheck: cannot assign to borrowed place `bag`")]
    [returned-borrowed-lookup-array-set-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defenum Slot (Empty) (Occupied String))
(defstruct Bag (slots (__tl_dyn-array Slot)))
(defenum SlotLookup (:lifetimes bag) (SlotMissing) (SlotFound (& bag str)))
(define (slot-missing [bag : (& bag Bag)]) : (SlotLookup bag) (SlotMissing))
(define (slot-found [value : (& bag str)]) : (SlotLookup bag) (SlotFound value))
(define (lookup [bag : (& bag Bag)]) : (SlotLookup bag)
  (match (& (array-ref bag.slots 0))
    [(Occupied v) (slot-found v)]
    [Empty (slot-missing bag)]))
(define (bad [bag : Bag]) : unit
  (match (lookup (& bag))
    [(SlotFound value) (set! (array-ref bag.slots 0) Empty)]
    [SlotMissing unit]))"
        "typecheck: cannot assign to borrowed place `bag.slots[0]`")]
    [regular-call-lifetime-subst-ok : bool
      (compiler-typecheck-ok?
        "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (ref-id [value : (& a i64)]) : (& a i64) value)
(define (box-id [value : (& a i64)]) : (RefBox a) (RefBox value))
(define (main [n : i64]) : i64
  (let
    [direct : (& n i64) (ref-id (& n))]
    [box : (RefBox n) (box-id (& n))]
    (let [value : (& n i64) box.value] 0)))")]
    [lifetime-iterator-mut-borrow-ok : bool
      (compiler-typecheck-ok?
        "(defstruct Iter
  (:lifetimes source)
  (slots (& source (__tl_dyn-array i64)))
  (index i64))
(define (advance [iter : (&mut iter (Iter source))]) : unit
  (set! iter.index (+ iter.index 1)))
(define (main [items : (__tl_dyn-array i64)]) : unit
  (let
    [iter : (Iter items) (Iter (& items) 0)]
    (advance (&mut iter))))")]
    [regular-call-lifetime-conflict-error-ok : bool
      (compiler-typecheck-ok?
        "(define (same-owner [a : (& source i64)] [b : (& source i64)]) : i64 0)
(define (main [n : i64]) : i64
  (let [other : i64 1] (same-owner (& n) (& other))))")]
    [lifetime-duplicate-error-ok : bool
      (compiler-typecheck-error-location-ok?
        "(module main)
(defstruct RefBox (:lifetimes a a) (value (& a i64)))"
        "typecheck: duplicate lifetime parameter"
        2
        1)]
    [lifetime-missing-args-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [box : RefBox]) : unit unit)"
        "typecheck: missing nominal lifetime arguments")]
    [lifetime-arity-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [box : (RefBox n extra)]) : unit unit)"
        "typecheck: nominal lifetime argument arity mismatch")]
    [lifetime-unknown-decl-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defstruct RefBox (:lifetimes a) (value (& b i64)))"
        "typecheck: unknown aggregate lifetime parameter")]
    [lifetime-untied-return-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [n : i64]) : (RefBox other)
  (RefBox (& n)))"
        "typecheck: returned reference lifetime must be tied to a parameter")]
    [lifetime-local-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defstruct RefBox (:lifetimes a) (value (& a i64)))
(define (main [n : i64]) : (RefBox n)
  (let [x : i64 1] (RefBox (& x))))"
        "typecheck: reference value would escape lexical scope")]
    [array-stored-ok : bool
      (compiler-typecheck-ok?
        "(define (main [n : i64]) : i64
  (let
    [items : (Array (& n i64) 1) (array (& n))]
    (let [value : (& n i64) (array-ref items 0)] 0)))")]
    [tuple-borrow-ok : bool
      (compiler-typecheck-ok?
        "(define (take [pair : (& pair (Tuple (& n i64) i64))]) : i64 42)
(define (main [n : i64]) : i64
  (let
    [pair : (Tuple (& n i64) i64) (tuple (& n) 7)]
    (take (& pair))))")]
    [struct-return-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defstruct RefBox (value (& n i64)))
(define (main [n : i64]) : RefBox
  (RefBox (& n)))"
        "typecheck: cannot store region-tagged value into return value; region value would escape")]
    [struct-local-escape-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defstruct RefBox (value (& x i64)))
(define (main) : RefBox
  (let [x : i64 1] (RefBox (& x))))"
        "typecheck: reference value would escape lexical scope")]
    [lambda-return-ok : bool
      (compiler-typecheck-ok?
        "(define (main [n : i64]) : i64
  (begin
    (lambda ([x : i64]) : (& x i64) (& x))
    n))")]
    [mut-ref-ok : bool
      (compiler-typecheck-ok?
        "(define (main [n : (&mut phase i64)]) : unit unit)")]
    [mut-borrow-ok : bool
      (compiler-typecheck-ok?
        "(define (take [r : (&mut n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (take (&mut n)))")]
    [mut-array-set-ok : bool
      (compiler-typecheck-ok?
        "(define (put [items : (&mut items (__tl_dyn-array i64))] [v : i64]) : unit
  (set! (array-ref items 0) v))
(define (main [items : (__tl_dyn-array i64)]) : unit
  (put (&mut items) 7))")]
    [mut-array-push-ok : bool
      (compiler-typecheck-ok?
        "(define (grow [items : (&mut items (__tl_dyn-array i64))] [v : i64]) : unit
  (__tl_array-push! items v))
(define (main [items : (__tl_dyn-array i64)]) : unit
  (grow (&mut items) 7))")]
    [immut-array-set-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (bad [items : (& items (__tl_dyn-array i64))]) : unit
  (set! (array-ref items 0) 7))"
        "typecheck: set! array element requires mutable array access")]
    [str-value-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (main [s : str]) : unit unit)"
        (tc_core.tc-source-str-value-policy-message))]
    [str-return-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (main) : str \"x\")"
        (tc_core.tc-source-str-value-policy-message))]
    [str-local-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (main) : unit (let [s : str \"x\"] unit))"
        (tc_core.tc-source-str-value-policy-message))]
    [str-global-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define bad : str \"x\")"
        (tc_core.tc-source-str-value-policy-message))]
    [str-field-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defstruct Bad (s str))"
        (tc_core.tc-source-str-value-policy-message))]
    [str-variant-error-ok : bool
      (compiler-typecheck-error-ok?
        "(defenum Bad (S str))"
        (tc_core.tc-source-str-value-policy-message))]
    [str-mut-ref-error-ok : bool
      (compiler-typecheck-error-ok?
        "(define (main [s : (&mut text str)]) : unit unit)"
        (tc_core.tc-source-str-mut-ref-policy-message))]
    (and
      render-ok
      local-ok
      param-ok
      projection-ok
      str-ok
      str-auto-borrow-ok
      str-region-ok
      temp-call-arg-ok
      temp-error-ok
      mismatch-error-ok
      return-ok
      return-param-ref-ok
      return-untied-error-ok
      return-local-escape-error-ok
      struct-field-ok
      enum-payload-ok
      lifetime-struct-return-ok
      lifetime-struct-field-ok
      lifetime-enum-match-ok
      borrowed-enum-match-scalar-ok
      borrowed-enum-match-str-ok
      borrowed-enum-match-array-ok
      borrowed-enum-match-ref-struct-array-ok
      borrowed-enum-match-nested-ok
      borrowed-enum-match-temp-error-ok
      borrowed-enum-match-escape-error-ok
      returned-borrowed-lookup-assign-error-ok
      returned-borrowed-lookup-array-set-error-ok
      regular-call-lifetime-subst-ok
      lifetime-iterator-mut-borrow-ok
      regular-call-lifetime-conflict-error-ok
      lifetime-duplicate-error-ok
      lifetime-missing-args-error-ok
      lifetime-arity-error-ok
      lifetime-unknown-decl-error-ok
      lifetime-untied-return-error-ok
      lifetime-local-escape-error-ok
      array-stored-ok
      tuple-borrow-ok
      struct-return-error-ok
      struct-local-escape-error-ok
      lambda-return-ok
      mut-ref-ok
      mut-borrow-ok
      mut-array-set-ok
      mut-array-push-ok
      immut-array-set-error-ok
      str-value-error-ok
      str-return-error-ok
      str-local-error-ok
      str-global-error-ok
      str-field-error-ok
      str-variant-error-ok
      str-mut-ref-error-ok)))

;; A type error whose offending expression (`missing`) is on source line 2, so
;; the diagnostic must locate it there (not at the 1:1 fallback), proving the
;; typechecker carries the nearest declaration-body `AstExpr.Spanned` span.
(define (compiler-typecheck-located-fn-source) : String
  "(define (main) : i64
  missing)")

(define (compiler-typecheck-located-source-ok? [src : String]) : bool
  (match (tc_api.typecheck-compiler-source src)
    [(Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (if (= (cdiag.compiler-diagnostic-line first) 2)
          (if (> (cdiag.compiler-diagnostic-col first) 0)
            (string.eq
              (cdiag.compiler-diagnostic-message first)
              "typecheck: unbound name missing")
            false)
          false))]
    [(Ok _) false]))

(define (compiler-typecheck-located-ok?) : bool
  (and
    (compiler-typecheck-located-source-ok?
      (compiler-typecheck-located-fn-source))
    (compiler-typecheck-located-source-ok? "(define bad : i64
  missing)")
    (match (tc_api.typecheck-compiler-source
      "(define (need3 [a : i64] [b : i64] [c : i64]) : i64 a)
(define (main) : i64
  (let
    [x : i64 1]
    [y : i64 2]
    [z : i64 3]
    (begin
      (+ x y)
      (need3 x y))))")
      [(Err diag)
        (let
          [first : cdiag.CompilerDiagnostic
            (cdiag.compiler-diagnostic-list-first (deref diag))]
          (and
            (string.eq
              (cdiag.compiler-diagnostic-message first)
              "typecheck: call arity mismatch: need3 expected 3 arguments, got 2 arguments")
            (= (cdiag.compiler-diagnostic-line first) 9)
            (= (cdiag.compiler-diagnostic-col first) 7)))]
      [(Ok _) false])))

(define (compiler-typecheck-nested-expression-diagnostic-span-ok?) : bool
  (let
    [span : ast.AstSourceSpan (ast.ast-source-span 7 5 7 12)]
    [inner : i64 (ast.ast-node-push (Var (ci.intern "missing")))]
    [spanned-inner : i64 (ast.ast-expr-spanned inner span)]
    [wrapped : i64 (ast_tests.ast-expr-ann spanned-inner (I64))]
    [diag : cdiag.CompilerDiagnostic
      (tc_core.tc-expr-diag
        (ast.ast-node-pool-active-expr-segment-bases)
        (ast.ast-node-get wrapped)
        "typecheck: nested expression diagnostic")]
    [located : String
      (tc_core.tc-locate-error-at-expr
        (ast.ast-node-pool-active-expr-segment-bases)
        (ast.ast-node-get (ast.ast-expr-return spanned-inner))
        "typecheck: nested located error")]
    [located-diag : cdiag.CompilerDiagnostic
      (tc_core.tc-located-error-diag located)]
    (and
      (string.eq
        (cdiag.compiler-diagnostic-message diag)
        "typecheck: nested expression diagnostic")
      (= (cdiag.compiler-diagnostic-line diag) 7)
      (= (cdiag.compiler-diagnostic-col diag) 5)
      (string.eq
        (cdiag.compiler-diagnostic-message located-diag)
        "typecheck: nested located error")
      (= (cdiag.compiler-diagnostic-line located-diag) 7)
      (= (cdiag.compiler-diagnostic-col located-diag) 5))))

;; Statement and control-flow type rules: if/while conditions, the
;; while-body unit rule, set!/let annotation mismatches, and `ann` mismatch,
;; plus an accepting program exercising the same forms. Migrated from
;; src/typechecker.rs unit coverage.
(define (compiler-typecheck-stmt-if-cond-source) : String
  "(define (main) : i64 (if 1 2 3))")

(define (compiler-typecheck-while-body-error-at? [body : String] [line : i64]) : bool
  (compiler-typecheck-error-location-ok?
    (str_cat.str-cat
      "(define (s) : i64 1)\n(define (main) : unit\n  (while false\n"
      body
      "))")
    "typecheck: while body must be unit: expected unit, found i64"
    line
    5))

(define (compiler-typecheck-while-unit-body-tests-ok?) : bool
  (and
    (compiler-typecheck-while-body-error-at? "    (s)\n    unit" 4)
    (compiler-typecheck-while-body-error-at? "    unit\n    (s)\n    unit" 5)
    (compiler-typecheck-while-body-error-at? "    unit\n    unit\n    (s)" 6)
    (compiler-typecheck-while-body-error-at? "    (s)" 4)
    (compiler-typecheck-while-body-error-at? "    (break)\n    (s)\n    unit" 5)
    (compiler-typecheck-while-body-error-at? "    (begin unit (s))" 4)
    ;; The stdlib/thread.tl shape (#8667): an i64 call under `unsafe` needs
    ;; its `(begin ... unit)`; spliced into the while body it is rejected.
    (compiler-typecheck-while-body-error-at?
      "    (unsafe\n      (s))\n    unit"
      4)
    (compiler-typecheck-ok?
      "(define (s) : i64 1)
(define (main) : unit
  (while false
    (begin
      (unsafe
        (s))
      unit)))")
    (compiler-typecheck-ok?
      "(define (main) : unit
  (while false (begin 1 unit) (begin (begin 2 unit) unit)))")
    (compiler-typecheck-ok?
      "(define (main) : unit
  (while true (break) (continue) (return unit)))")
    (compiler-typecheck-error-ok?
      "(defmacro (empty-body [items : Expr ...]) : Expr
  `(while false ,@items))
(define (main) : unit (empty-body))"
      "typecheck: while requires at least one body expression")
    (compiler-typecheck-error-code-ok?
      "(defmacro (empty-body [items : Expr ...]) : Expr
  `(while false ,@items))
(define (main) : unit (empty-body))"
      (cdiag.compiler-diagnostic-code-typecheck-arity-mismatch)
      "typecheck")
    (compiler-typecheck-error-ok?
      "(define (s) : i64 1)
(defmacro (loop [value : Expr]) : Expr `(while false ,value unit))
(define (main) : unit (loop (s)))"
      "typecheck: while body must be unit: expected unit, found i64")))

(define (compiler-typecheck-statement-tests-ok?) : bool
  (and
    (compiler-typecheck-while-unit-body-tests-ok?)
    (compiler-typecheck-error-ok?
      (compiler-typecheck-stmt-if-cond-source)
      "typecheck: if condition must be bool: expected bool, found i32")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : unit
  (let [i : i64 n] (while i (set! i (- i 1)))))"
      "typecheck: while condition must be bool: expected bool, found i64")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : unit
  (let [i : i64 n] (while (> i 0) i)))"
      "typecheck: while body must be unit: expected unit, found i64")
    (compiler-typecheck-error-ok?
      "(define (main) : i64
  (let [x : i64 0] (begin (set! x true) x)))"
      "typecheck: assignment type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (let [x : i64 true] x))"
      "typecheck: let binding `x` type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (ann true : i64))"
      "typecheck: annotation type mismatch: expected i64, found bool")
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : unit
  (let [i : i64 n] (while (> i 0) (set! i (- i 1)))))")
    (compiler-typecheck-ok?
      "(define (main [flag : bool]) : i64
  (let [x : i64 0] (begin (set! x 5) (if flag x 0))))")
    (compiler-typecheck-ok?
      "(define (main [c : char]) : i64 (ann (cast c : i64) : i64))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let [] unit)
  (let [i : i64 0]
    (while (< i 3)
      (let [copy : i64 i] unit)
      (set! i (+ i 1)))
    ((lambda ([x : i64]) : i64
      (let [] unit)
      (+ x i)) 39)))")))

;; Operator and call type rules: equality/comparison/integer operato
;; operand matching and call arity, plus accepting arithmetic/comparison/call
;; programs. Migrated from src/typechecker.rs unit coverage.
(define (compiler-typecheck-op-eq-mismatch-source) : String
  "(define (main) : bool (= 1 true))")

(define (compiler-typecheck-operator-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-op-eq-mismatch-source)
      "typecheck: equality operands must match")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (+ 1 true))"
      "typecheck: integer operator expects matching integer operands: expected i32, found bool")
    (compiler-typecheck-error-ok?
      "(define (main) : bool (< 1 true))"
      "typecheck: comparison expects matching ordered scalar operands, got i32 and bool")
    (compiler-typecheck-error-ok?
      "(define (f [x : i64]) : i64 x)
(define (main) : i64 (f 1 2))"
      "typecheck: call arity mismatch: f expected 1 argument, got 2 arguments")
    (compiler-typecheck-error-ok?
      "(define (f [x : i64] [y : i64]) : i64 (+ x y))
(define (main) : i64 (f 1))"
      "typecheck: call arity mismatch: f expected 2 arguments, got 1 argument")
    (compiler-typecheck-ok? "(define (main) : i64 (+ (* 2 3) (- 10 4)))")
    (compiler-typecheck-ok? "(define (main) : bool (if (< 1 2) (= 3 3) false))")
    (compiler-typecheck-ok? "(define (main) : u64 (shr (cast -1 : u64) 63))")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (shl 1 true))"
      "typecheck: shift count must be integer")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (shl true 1))"
      "typecheck: shift left operand must be integer")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : u64 (bit-and (cast -1 : u64) n))"
      "typecheck: integer operator expects matching integer operands: expected u64, found i64")
    (compiler-typecheck-ok?
      "(define (main [a : i64] [b : i64] [c : i64] [d : i64]) : i64
  (+
    (bit-and a b c d)
    (+
      (bit-or a b c d)
      (bit-xor a b c d))))")
    (compiler-typecheck-error-ok?
      "(define (main [a : i64] [b : i64] [c : bool]) : i64 (bit-xor a b c))"
      "typecheck: integer operator expects matching integer operands: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main [a : i64]) : i64 (bit-or a))"
      "parse: malformed binary expression")
    (compiler-typecheck-ok?
      "(define (add [a : i64] [b : i64]) : i64 (+ a b))
(define (main) : i64 (add 2 3))")))

;; Scalar/bool/float/cast parity: remaining Rust typechecker unit
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

;; Contextual scalar literals also flow through tuple element types:
;; the float literals resolve to f32 against the declared tuple element types.
(define (compiler-typecheck-scalar-tuple-context-source) : String
  "(define (pair) : (Tuple f32 bool) (tuple 1.0 true))
(define (first) : f32
  (tuple-ref (ann (tuple 1.0 true) : (Tuple f32 bool)) 0))")

;; ... and through a begin's final expression: the tail float literal
;; resolves to f32 against the function return type.
(define (compiler-typecheck-scalar-begin-context-source) : String
  "(define (f) : f32 (begin 1 1.0))")

(define (compiler-typecheck-scalar-parity-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-scalar-bool-ok-source))
    (compiler-typecheck-error-ok?
      "(define (main) : bool (not 5))"
      "typecheck: not expects bool")
    (compiler-typecheck-error-ok?
      "(define (main [a : bool]) : bool (= a 1))"
      "typecheck: equality operands must match")
    (compiler-typecheck-ok?
      "(defmacro (cond [arm : ExprClause] [fallback : ExprClause]) : Expr
  `(if ,(expr-clause-first arm)
    ,(expr-clause-second arm)
    ,(expr-clause-second fallback)))
(define (main [x : i64]) : i64 (cond [(= x 0) 1] [else 2]))")
    (compiler-typecheck-error-ok?
      "(defmacro (cond [arm : ExprClause] [fallback : ExprClause]) : Expr
  `(if ,(expr-clause-first arm)
    ,(expr-clause-second arm)
    ,(expr-clause-second fallback)))
(define (main) : i64 (cond [1 2] [else 3]))"
      "typecheck: if condition must be bool: expected bool, found i32")
    (compiler-typecheck-ok?
      "(define (narrow-u8 [n : u8]) : i64 (match n [0 1] [_ 0]))
(define (narrow-i16 [n : i16]) : i64 (match n [0 1] [_ 0]))
(define (main [n : u8]) : i64 (narrow-u8 n))")
    (compiler-typecheck-error-ok?
      "(define (main [n : u8]) : i64 (match n [true 1] [_ 0]))"
      "typecheck: literal pattern type mismatch")
    (compiler-typecheck-ok?
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
      (set! c.r 135)
      c.r)))
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
    (compiler-typecheck-ok?
      "(define (main) : i32
  (let
    [x (+ 1 2)]
    x))")
    (compiler-typecheck-error-ok?
      "(define (main) : i8 128)"
      "typecheck: integer literal 128 does not fit expected type i8")
    (compiler-typecheck-error-ok?
      "(define (main) : u8 256)"
      "typecheck: integer literal 256 does not fit expected type u8")
    (compiler-typecheck-error-ok?
      "(define (main) : u8 -1)"
      "typecheck: integer literal -1 does not fit expected type u8")
    (compiler-typecheck-error-ok?
      "(define (main) : u64 18446744073709551616)"
      "typecheck: integer literal 18446744073709551616 does not fit expected type u64")
    (compiler-typecheck-error-ok?
      "(define (main) : u64 0x10000000000000000)"
      "typecheck: integer literal 0x10000000000000000 does not fit expected type u64")
    (compiler-typecheck-error-ok?
      "(define (main) : u64 -1)"
      "typecheck: integer literal -1 does not fit expected type u64")
    (compiler-typecheck-error-ok?
      "(define (main [x : i8]) : i8 (+ 128 x))"
      "typecheck: integer literal 128 does not fit expected type i8")
    (compiler-typecheck-ok?
      "(define gx : f32 1.0)
(define (id [x : f32]) : f32 x)
(define (ret) : f32 1.0)
(define (annotated) : f32 (ann 1.0 : f32))
(define (call) : f32 (id 2.0))
(define (array-first) : f32
  (let
    [a : (Array f32 2) (array 1.0 2.0)]
    (array-ref a 0)))")
    (compiler-typecheck-ok?
      "(define (ret [x : f32]) : f64 x)
(define (io.arg [x : f64]) : f64 x)
(define (call [x : f32]) : f64 (io.arg x))
(define (branch [x : f32] [flag : bool]) : f64 (if flag x 2.0))")
    (compiler-typecheck-error-ok?
      "(define (main [x : f64]) : f32 x)"
      "typecheck: return type mismatch: expected f32, found f64")
    (compiler-typecheck-ok?
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
    (compiler-typecheck-ok? "(define (main) : f32 (cast 3.5 : f32))")
    (compiler-typecheck-ok? "(define (main [x : f32]) : f64 (cast x : f64))")
    ;; Float -> int casts truncate toward zero under the full numeric cast
    ;; matrix, so `(cast 3.5 : i64)` is accepted rather than rejected.
    (compiler-typecheck-ok? "(define (main) : i64 (cast 3.5 : i64))")
    (compiler-typecheck-ok? (compiler-typecheck-scalar-tuple-context-source))
    (compiler-typecheck-ok? (compiler-typecheck-scalar-begin-context-source))))

;; Match / pattern type rules: Rust inline coverage migrated to
;; selfhost-owned parser+typechecker fixtures.
(define (compiler-typecheck-match-arm-mismatch-source) : String
  "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(B) true]))")

;; A diverging arm (io.panic : never) must unify with a value arm rather than
;; being reported as a disagreement; mirrors never-in-if branch handling.
(define (compiler-typecheck-match-ok-never-arm-source) : String
  (compiler-typecheck-with-io-source
    "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(B) (io.panic \"no\")]))"))

;; A two-arm `cond` over the ExprClause capture the prelude macro uses.
(define (compiler-typecheck-multiform-cond-source [body : String]) : String
  (str_cat.str-cat
    "(defmacro (cond [arm : ExprClause] [fallback : ExprClause]) : Expr
  `(if ,(expr-clause-first arm)
    ,(expr-clause-second arm)
    ,(expr-clause-second fallback)))
"
    body))

;; Match and cond arms take a body sequence, `[pattern form ...]` and
;; `[test form ...]`, evaluated like `begin`: earlier values are discarded and
;; the last form gives the arm type.
(define (compiler-typecheck-multiform-arm-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defenum Op (Add i64) (Neg))
(define (apply [op : Op] [acc : i64]) : i64
  (let [total : i64 acc]
    (match op
      [(Add n) (set! total (+ total n)) (set! total (* total 2))]
      [(Neg) (set! total (- 0 total)) unit])
    total))
(define (main) : i64 (apply (Add 1) 2))")
    (compiler-typecheck-ok?
      "(define (bump [x : i64]) : i64 (+ x 1))
(define (main [x : i64]) : i64
  (match x
    [0 (bump x) (set! x 5) (bump x)]
    [_ x]))")
    (compiler-typecheck-ok?
      "(define (find [limit : i64]) : i64
  (let [i : i64 0]
    (while (< i limit)
      (match i
        [3 (set! i (+ i 10)) (break)]
        [_ (set! i (+ i 1)) unit]))
    (match i
      [13 (set! i 0) (return 7)]
      [_ i])))
(define (main) : i64 (find 5))")
    (compiler-typecheck-ok?
      "(defenum Opt (Some i64) (None))
(define (main [o : Opt]) : i64
  (let [seen : i64 0]
    (match o
      [(Some v)
        (set! seen 1)
        (match v
          [0 (set! seen 2) seen]
          [_ (set! seen (+ seen v)) (+ seen 1)])]
      [(None) (set! seen 3) seen])))")
    (compiler-typecheck-error-ok?
      "(define (main [x : i64]) : i64
  (match x
    [0 x]
    [_ (set! x 1) true]))"
      "typecheck: match arm result type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (take [s : String]) : i64 0)
(define (main [s : String] [x : i64]) : i64
  (match x
    [0 (take s) (take s)]
    [_ 1]))"
      "typecheck: use of moved value `s`")
    (compiler-typecheck-ok?
      (compiler-typecheck-multiform-cond-source
        "(define (main [x : i64]) : i64
  (let [y : i64 0]
    (cond
      [(= x 0) (set! y 2) (set! y (+ y 1)) y]
      [else (set! y 3) y])))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-multiform-cond-source
        "(define (main [x : i64]) : i64
  (cond [(= x 0) (set! x 1) true] [else 2]))")
      "typecheck: if branches must match")
    (compiler-typecheck-error-ok?
      "(defmacro (take-clause [arm : ExprClause]) : i64 (expr-clause-second arm))
(define (main) : i64 (take-clause [true]))"
      "typecheck: ExprClause macro operand expects bracket clause [expr expr ...]")
    (compiler-typecheck-ok?
      "(defmacro (take-clause [arm : ExprClause]) : i64 (expr-clause-second arm))
(define (main) : i64 (let [x : i64 1] (take-clause [true (set! x 2) (+ x 1)])))")
    (compiler-typecheck-ok?
      "(defmacro (choose [scrutinee : Expr] [first : Expr] [rest : Expr ...]) : i64
  `(match ,scrutinee [0 ,first ,@rest] [_ 0]))
(define (main [x : i64]) : i64 (choose x (set! x 4) (+ x 1)))")))

;; Both enums declare `Ok` and `Err`, in different orders, so a bare name that
;; resolved to the other enum would also have the other tag.
(define (compiler-typecheck-bare-variant-enums) : String
  "(defenum ResA (Ok i64) (Err i64))
(defenum ResB (Err i64) (Ok i64))
(defenum Light (Off) (On))
(defenum Switch (On) (Off))
(defstruct Holder (result ResB) (light Light))
(defenum Wrap (Outer ResB) (Nested Holder) (Empty))
(define (take [r : ResB]) : i64 (match r [(Ok v) v] [(Err e) e]))
")

(define (compiler-typecheck-bare-variant-ok? [body : String]) : bool
  (compiler-typecheck-ok?
    (str_cat.str-cat (compiler-typecheck-bare-variant-enums) body)))

;; SPEC 3.5.1: bare variant names resolve against the expected enum type; with
;; none, two visible declaring enums make the name ambiguous.
(define (compiler-typecheck-bare-variant-tests-ok?) : bool
  (and
    (compiler-typecheck-bare-variant-ok?
      "(define (returned [x : i64]) : ResB (Ok x))
(define (tail [b : bool] [x : i64]) : ResB
  (if b
    (begin (Ok x))
    (let [y : i64 (+ x 1)] (match y [0 (Err 0)] [_ (Err y)]))))
(define (light) : Light On)
(define (switch) : Switch (On))")
    (compiler-typecheck-bare-variant-ok?
      "(define (main) : i64
  (let
    [typed : ResB (Ok 1)]
    [holder : Holder (Holder (Err 2) Off)]
    [wrapped : Wrap (Nested (Holder (Ok 3) On))]
    [outer : Wrap (Outer (Err 4))]
    (begin
      (set! typed (Err 5))
      (set! holder.result (Ok 6))
      (set! holder.light On)
      (+ (take typed) (take (Ok 7)) (take holder.result)))))")
    ;; R1: a local binding of the name wins over the expected enum.
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-bare-variant-enums)
        "(define (keep [On : Switch]) : Light On)")
      "typecheck: return type mismatch: expected Light, found Switch")
    ;; One visible declaring enum keeps the ordinary unqualified lookup.
    (compiler-typecheck-bare-variant-ok?
      "(define (main) : i64 (let [light (Outer (ResB.Ok 1))] 0))")
    (compiler-typecheck-error-location-ok?
      (str_cat.str-cat
        (compiler-typecheck-bare-variant-enums)
        "(define (main) : i64 (let [r (Ok 1)] 0))")
      "typecheck: ambiguous variant `Ok`; qualify as ResA.Ok or ResB.Ok"
      8
      31)
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-bare-variant-enums)
        "(define (main) : i64 (take (On)))")
      "typecheck: ambiguous variant `On`; qualify as Light.On or Switch.On")
    ;; A bare binder in a payload position may not spell a payload variant.
    (compiler-typecheck-error-ok?
      "(defenum Ty (I64) (U8))
(defenum Instr (Mov i64 Ty) (Nop))
(define (main [i : Instr]) : i64 (match i [(Mov d I64) d] [_ 0]))"
      "typecheck: pattern binder `I64` spells a variant of the payload enum Ty; write `(I64)` to match that variant or rename the binder")
    (compiler-typecheck-ok?
      "(defenum Ty (I64) (U8))
(defenum Instr (Mov i64 Ty) (Nop))
(define (main [i : Instr]) : i64 (match i [(Mov d (I64)) d] [(Mov d ty) 1] [_ 0]))")))

(define (compiler-typecheck-match-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      (compiler-typecheck-match-arm-mismatch-source)
      "typecheck: match arm result type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(defenum E (A) (B))
(define (main [e : E]) : i64 (match e [(A) 1] [(C) 2]))"
      "typecheck: unknown variant C")
    (compiler-typecheck-ok?
      "(defenum Color (Red) (Green))
(define (main [c : Color]) : i64 (match c [Red 1] [Green 2]))")
    (compiler-typecheck-error-ok?
      "(defenum Color (Red) (Green))
(define (main [c : Color]) : i64 (match c [other 1] [_ 0]))"
      "typecheck: unknown variant other")
    (compiler-typecheck-ok?
      "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [_ 0]))")
    (compiler-typecheck-ok?
      "(defenum Shape (Circle i64) (Square i64) (Nothing))
(define (main) : i64
  (match (Nothing) [(Circle r) r] [(Square w) w] [(Nothing) 0]))")
    (compiler-typecheck-error-ok?
      "(defenum Shape (Circle i64) (Square i64) (Nothing))
(define (main) : i64
  (match (Nothing 1) [(Circle r) r] [(Square w) w] [(Nothing) 0]))"
      "typecheck: call arity mismatch: Nothing expected 0 arguments, got 1 argument")
    (compiler-typecheck-error-ok?
      "(defenum Shape (Nothing))
(defenum Other (OtherV))
(define (main [Nothing : Other]) : Other (Nothing))"
      "typecheck: call target is not a function")
    (compiler-typecheck-ok?
      "(defenum E (A i64) (B))
(define (main [e : E]) : i64 (match e [(A x) x] [(B) 0]))")
    (compiler-typecheck-ok?
      "(defenum Token (TIdent String) (TEnd))
(define (main [t : Token]) : i64
  (match t [(TIdent s) (__tl_string_length s)] [(TEnd) 0]))")
    (compiler-typecheck-error-ok?
      "(defenum Token (TIdent String) (TEnd))
(define (main [t : Token]) : i64
  (match t [(TIdent s) s] [(TEnd) 0]))"
      "typecheck: match arm result type mismatch: expected i64, found String")
    (compiler-typecheck-ok?
      "(defstruct Pos (line i64) (col i64))
(defenum Tok (TPos Pos) (TEnd))
(define (main [t : Tok]) : i64
  (match t [(TPos p) p.line] [(TEnd) -1]))")
    (compiler-typecheck-ok?
      "(defenum SexprAtom (SInt i64) (SSym String) (SNil))
(defenum Sexpr (SAtom SexprAtom) (SCons SexprAtom SexprAtom))
(define (main [s : Sexpr]) : i64
  (match s [(SCons (SSym op) rest) (__tl_string_length op)] [_ 0]))")
    (compiler-typecheck-ok?
      "(defenum Expr (Int i64) (Sym String) (Branch (Box Expr) (Box Expr)))
(define (depth [expr : Expr]) : i64
  (match expr
    [(Branch left right)
      (match (deref left)
        [(Sym op) (+ 1 (depth (deref right)))]
        [_ 0])]
    [_ 0]))")
    (compiler-typecheck-error-ok?
      "(defenum SexprAtom (SInt i64) (SSym String) (SNil))
(defenum Sexpr (SAtom SexprAtom) (SCons SexprAtom SexprAtom))
(define (main [s : Sexpr]) : i64
  (match s [(SCons (SInt n) rest) (__tl_string_length n)] [_ 0]))"
      "typecheck: call `__tl_string_length` argument 1 type mismatch: expected String, (& str), (& bytes), or (&mut bytes), found i64")
    (compiler-typecheck-error-ok?
      "(defenum Sexpr (SInt i64) (SNil))
(define (main [s : Sexpr]) : i64 (match s [(SInt (SNil)) 1] [_ 0]))"
      "typecheck: nested variant pattern requires enum field")
    (compiler-typecheck-ok?
      "(defenum SexprAtom (SInt i64) (SNil))
(defenum Sexpr (SAtom SexprAtom) (SCons SexprAtom SexprAtom))
(define (main [s : Sexpr]) : i64
  (match s [(SCons (SInt 0) rest) 1] [_ 0]))")
    (compiler-typecheck-error-ok?
      "(defenum SexprAtom (SInt i64) (SNil))
(defenum Sexpr (SAtom SexprAtom) (SCons SexprAtom SexprAtom))
(define (main [s : Sexpr]) : i64
  (match s [(SCons (SInt true) rest) 1] [_ 0]))"
      "typecheck: literal pattern type mismatch")
    (compiler-typecheck-error-ok?
      "(defenum Sexpr (SInt i64) (SSym String) (SNil) (SCons i64 i64))
(define (main [s : Sexpr]) : i64
  (match s [(SInt n) n] [(SSym x) 0] [(SNil) 0]))"
      "typecheck: match missing arm for variant SCons")
    (compiler-typecheck-error-ok?
      "(defenum Inner (Left i64) (Right i64))
(defenum Outer (Outer Inner))
(define (main [o : Outer]) : i64 (match o [(Outer (Left n)) n]))"
      "typecheck: non-exhaustive match")
    (compiler-typecheck-ok?
      "(defenum Inner (Left i64) (Right i64))
(defenum Outer (Outer Inner))
(define (main [o : Outer]) : i64
  (match o [(Outer (Left n)) n] [(Outer _) 0]))")
    (compiler-typecheck-ok?
      "(define (main [b : bool]) : i64 (match b [true 1] [false 0]))")
    (compiler-typecheck-ok? "(define (main) : i64 (match 1 [_ 0]))")
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : i64 (match n [0 100] [1 200] [_ 0]))")
    (compiler-typecheck-ok?
      "(define (main [s : String]) : i64
  (match s [\"if\" 10] [\"let\" 20] [_ 0]))")
    (compiler-typecheck-error-ok?
      "(define (main [s : String]) : i64 (match s [\"if\" 10]))"
      "typecheck: non-exhaustive match")
    (compiler-typecheck-error-ok?
      "(define (main [b : bool]) : i64 (match b [true 1]))"
      "typecheck: match missing arm for false")
    (compiler-typecheck-ok?
      "(define (main [b : bool]) : i64 (match b [true 1] [_ 0]))")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : i64 (match n [0 1] [1 2]))"
      "typecheck: non-exhaustive match")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : i64 (match n [true 1] [_ 0]))"
      "typecheck: literal pattern type mismatch")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : i64 (match n [0 1] [_ true]))"
      "typecheck: match arm result type mismatch: expected i64, found bool")
    (compiler-typecheck-ok?
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
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : i64 (match n [_ 0] [1 2]))"
      "typecheck: unreachable match arm after wildcard `_`")
    (compiler-typecheck-ok?
      "(define (main [n : u8]) : i64 (match n [0 1] [_ 0]))")
    (compiler-typecheck-error-ok?
      "(defenum Shape (Circle i64) (Square i64))
(define (main [s : Shape]) : i64 (match s [(Circle a b) 0] [_ 1]))"
      "typecheck: pattern arity mismatch: expected 1, found 2")
    (compiler-typecheck-error-ok?
      "(defenum LocalMaybe (NoneCount) (SomeCount i64))
(define (main [m : LocalMaybe]) : i64 (match m [(SomeCount v) v]))"
      "typecheck: match missing arm for variant NoneCount")
    (compiler-typecheck-error-ok?
      "(import stdlib.result)
(import (result.result i64 String) as result_i64_string)
(define (main [r : result_i64_string.Result]) : i64
  (match r [(result_i64_string.Ok v) v]))"
      "typecheck: match missing arm for variant Err")
    (compiler-typecheck-ok?
      "(defenum SequenceView (Empty) (Items (__tl_dyn-array i64)))
(define (main [view : SequenceView]) : i64
  (match view
    [(Items items) (if (= (array-length items) 0) 0 (array-ref items 0))]
    [(Empty) 0]))")
    (compiler-typecheck-ok?
      "(defenum Expr (ENum i64) (EAdd (Box Expr) (Box Expr)))
(define (eval [e : Expr]) : i64
  (match e [(ENum n) n] [(EAdd l r) (+ (eval (deref l)) (eval (deref r)))]))
(define (main [e : Expr]) : i64 (eval e))")
    (compiler-typecheck-error-ok?
      "(defenum Bad (V (Tuple Bad i64)) (Nil))
(define (main [b : Bad]) : i64 0)"
      "typecheck: inline aggregate layout cycle Bad -> Bad; insert (Box Bad) at the recursive edge")
    (compiler-typecheck-error-ok?
      "(defenum Bad (V (Array Bad 2)) (Nil))
(define (main [b : Bad]) : i64 0)"
      "typecheck: inline aggregate layout cycle Bad -> Bad; insert (Box Bad) at the recursive edge")
    (compiler-typecheck-ok? (compiler-typecheck-match-ok-never-arm-source))))

(define (compiler-typecheck-string-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (main) : i64 (__tl_string_length \"hi\"))")
    (compiler-typecheck-ok? "(define (f) : bool (__tl_string_eq \"a\" \"b\"))")
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (f [s : String]) : String
  (string.concat
    (string.append (string.substring s 0 1) (string.slice s 1 1))
    (string.int->string (__tl_string_to_int \"7\"))))"))
    (compiler-typecheck-ok?
      "(define (main [text : String] [other : String]) : i64
  (begin
    (+ (__tl_string_length (& text))
      (+ (cast (__tl_string_ref (& text) 0) : i64)
        (+ (if (__tl_string_eq (& text) (& other)) 1 0)
           (__tl_string_to_int (& text)))))))")
    (compiler-typecheck-error-ok?
      "(define (main) : String (string.int->string 1))"
      "typecheck: unknown qualified name string.int->string; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : String (string.append \"a\" \"b\"))"
      "typecheck: unknown qualified name string.append; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : String (string.substring \"abc\" 0 1))"
      "typecheck: unknown qualified name string.substring; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : String (string.slice \"abc\" 0 1))"
      "typecheck: unknown qualified name string.slice; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : String (string.concat \"a\" \"b\"))"
      "typecheck: unknown qualified name string.concat; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main [left : String] [right : String]) : String
  (let
    [joined : String (string.append (& left) (& right))]
    [slice : String (string.substring (& joined) 0 1)]
    (string.concat (& slice) (string.slice (& right) 0 1))))"
      "typecheck: unknown qualified name string.append; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (__tl_string_length 5))"
      "typecheck: call `__tl_string_length` argument 1 type mismatch: expected String, (& str), (& bytes), or (&mut bytes), found i32")
    (compiler-typecheck-error-ok?
      "(define (main [items : (__tl_dyn-array i64)]) : i64 (__tl_string_length items))"
      "typecheck: call `__tl_string_length` argument 1 type mismatch: expected String, (& str), (& bytes), or (&mut bytes), found (__tl_dyn-array i64)")))

;; Stdlib argv helper signature rules: `arg-count` returns i64
;; and `arg` accepts an i64 index and returns String. User declarations may
;; still define the same source-level names when no stdlib import brings them
;; into scope.
(define (compiler-typecheck-argv-builtin-ok-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64
  (+ (arg-count) (__tl_string_length (io.arg 0))))"))

(define (compiler-typecheck-argv-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-argv-builtin-ok-source))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source
        "(define (main) : String (io.arg \"0\"))")
      "typecheck: call `io.arg` argument 1 type mismatch: expected i64, found String")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source
        "(define (main) : String (io.arg 0 1))")
      "typecheck: call arity mismatch: io.arg expected 1 argument, got 2 arguments")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source "(define (main) : i64 (arg-count 0))")
      "typecheck: call arity mismatch: arg-count expected 0 arguments, got 1 argument")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (arg-count))"
      "typecheck: unbound name arg-count")
    (compiler-typecheck-error-ok?
      "(define (main) : String (io.arg 0))"
      "typecheck: unknown qualified name io.arg; import the module or use a visible dotted module alias")
    (compiler-typecheck-ok?
      "(define (arg-count) : i64 9)
(define (io.arg [n : i64]) : i64 n)
(define (main) : i64 (+ (arg-count) (io.arg 1)))")))

;; Closure capture typing (migrated from src/typechecker.rs): a lambda
;; that reads outer locals/params type-checks like its declared `(-> ...)` type.
;; Covers scalar, multi-scalar, String, struct capture, and aggregate-returning
;; lambdas - the capture shapes the selfhost typechecker accepts.
(define (compiler-typecheck-lambda-capture-scalar-source) : String
  "(define (main) : i64 (let [n : i64 7] (let [g : (-> i64) (lambda () : i64 n)] (g))))")

(define (compiler-typecheck-lambda-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main) : i64 (let [f : (-> i64 i64) (lambda ([x : i64]) : i64 x)] (f 5)))")
    (compiler-typecheck-ok?
      "(define (main) : i64 (let [g : (-> i64) (lambda () : i64 42)] (g)))")
    (compiler-typecheck-ok?
      "(define (main) : i64 (let [h : (-> i64 i64) (lambda ([x : i64]) (+ x 1))] (h 7)))")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (lambda ([x : i64]) : bool x) 0))"
      "typecheck: lambda return type mismatch: expected bool, found i64")
    (compiler-typecheck-ok? (compiler-typecheck-lambda-capture-scalar-source))
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let [a : i64 3] (let [b : i64 4]
    (let [g : (-> i64) (lambda () : i64 (+ a b))] (g)))))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let [s : String \"hi\"]
    (let [g : (-> i64) (lambda () : i64 (__tl_string_length s))] (g))))")
    (compiler-typecheck-ok?
      "(defstruct P (a i64))
(define (main) : i64
  (let [p : P (P 9)]
    (let
      [g : (-> P) (lambda () : P p)]
      [result : P (g)]
      result.a)))")
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    (begin
      (__tl_array-push! items 5)
      (let [g : (-> i64) (lambda () : i64 (array-length items))] (g)))))")
    (compiler-typecheck-ok?
      "(defenum Maybe (None) (Some i64))
(define (main [m : Maybe]) : i64
  (let
    [g : (-> i64) (lambda () : i64 (match m [(Some v) v] [None 0]))]
    (g)))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [t : (Tuple i64 bool) (tuple 7 true)]
    (let [g : (-> i64) (lambda () : i64 (tuple-ref t 0))] (g))))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [items : (Array i64 2) (array 4 5)]
    (let [g : (-> i64) (lambda () : i64 (array-ref items 1))] (g))))")
    (compiler-typecheck-error-ok?
      "(define (main) : i64
  (let
    [n : i64 0]
    (let
      [g : (-> unit) (lambda () : unit (set! n 1))]
      (begin (g) n))))"
      "typecheck: lambda cannot assign captured binding")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : i64
  (let
    [scratch : Arena (arena-make)]
    (let
      [n : i64 0]
      (let
        [g : (-> unit) (lambda () : unit (with-escape scratch (set! n 1)))]
        (begin (g) n)))))")
      "typecheck: lambda cannot assign captured binding")
    (compiler-typecheck-ok?
      "(defstruct Boxed (value i64))
(define (score [n : i64] [box : Boxed]) : i64
  (begin
    (set! n (+ n 1))
    (set! box (Boxed n))
    (+ n box.value)))
(define (main) : i64 (score 20 (Boxed 0)))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [g : (-> i64 i64)
      (lambda ([n : i64]) : i64 (begin (set! n (+ n 1)) n))]
    (g 1)))")
    (compiler-typecheck-ok?
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
    (compiler-typecheck-ok?
      "(defstruct P (a i64))
(define (main) : i64
  (let
    [mk : (-> P) (lambda () : P (P 5))]
    [result : P (mk)]
    result.a))")))

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

;; spmd-reduce operator/type rules (SPEC 5.15): `sum` accepts i32/i64/f32/f64,
;; `min`/`max` accept i32/i64, `all`/`any` accept bool. (The varying-value
;; purity/effect rules are a separate slice.)
(define (compiler-typecheck-spmd-reduce-op-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs i)))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array f32)] [n : i64]) : f32 (spmd-reduce sum ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))")
    (compiler-typecheck-ok?
      "(define (main [bs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce all ([i : i64 0 n]) true (array-ref bs i)))")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce all ([i : i64 0 n]) 0 (array-ref xs i)))"
      "typecheck: spmd-reduce all requires a bool type")
    (compiler-typecheck-error-ok?
      "(define (main [bs : (__tl_dyn-array bool)] [n : i64]) : bool (spmd-reduce sum ([i : i64 0 n]) true (array-ref bs i)))"
      "typecheck: spmd-reduce sum requires an i32, i64, f32, or f64 type")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array f32)] [n : i64]) : f32 (spmd-reduce min ([i : i64 0 n]) (cast 0.0 : f32) (array-ref xs i)))"
      "typecheck: spmd-reduce min requires an i32 or i64 type")))

;; spmd-reduce purity rules (SPEC.md 5.15): the per-lane value
;; expression accepts pure arithmetic over dynamic-array reads and the varying
;; index, but rejects writes (`array-set!`), function calls (also covers
;; output/`panic`/file I/O and varying-argument user calls), varying control
;; flow (`if`/`while`/`match`). Pure gather-only array reads are supported.
(define (compiler-typecheck-spmd-reduce-purity-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (+ (array-ref xs i) 1)))")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (set! (array-ref xs i) 1)))"
      "array element assignment is not allowed inside a spmd-reduce value expression; the value expression must be free of writes and other side effects (SPEC.md 5.15)")
    (compiler-typecheck-error-ok?
      "(define (helper [x : i64]) : i64 x) (define (main [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (helper i)))"
      "function calls are not allowed inside a spmd-reduce value expression; side-effecting builtins and user calls with varying arguments are deferred in the first slice (SPEC.md 5.15)")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (if (< (array-ref xs i) 0) 0 1)))"
      "varying control flow is not allowed inside a spmd-reduce value expression; the first slice has no varying if/while/match (SPEC.md 5.15)")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [ys : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs (array-ref ys i))))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [offsets : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref xs (+ i (array-ref offsets (program-index))))))")))

(define (compiler-typecheck-spmd-broadcast-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array u64)] [out : (__tl_dyn-array u64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array u32)] [out : (__tl_dyn-array u32)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-broadcast (array-ref xs i) 0))) 0))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (spmd-broadcast (array-ref xs i) 0)))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (array-ref xs i) (set! (array-ref out i) (spmd-broadcast prefix 0))))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-shuffle (array-ref xs i) i))) 0))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : i64 (spmd-reduce sum ([i : i64 0 n]) 0 (spmd-shuffle (array-ref xs i) i)))")
    (compiler-typecheck-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : unit (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (array-ref xs i) (set! (array-ref out i) (spmd-shuffle prefix 0))))")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : unit (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (spmd-broadcast (array-ref xs i) 0) unit))"
      "typecheck: spmd-broadcast is only valid inside a foreach body, spmd-reduce value expression, or spmd-scan body")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [n : i64]) : unit (spmd-scan sum ([i : i64 0 n] [prefix : i64 0]) (spmd-shuffle (array-ref xs i) 0) unit))"
      "typecheck: spmd-shuffle is only valid inside a foreach body, spmd-reduce value expression, or spmd-scan body")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-broadcast (array-ref xs i) i))) 0))"
      "typecheck: spmd-broadcast lane must be uniform")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-broadcast (array-ref xs i) true))) 0))"
      "typecheck: spmd-broadcast lane must have type i64: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main [xs : (__tl_dyn-array i64)] [out : (__tl_dyn-array i64)] [n : i64]) : i64 (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-shuffle (array-ref xs i) true))) 0))"
      "typecheck: spmd-shuffle lane must have type i64: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (main [bs : (__tl_dyn-array bool)] [out : (__tl_dyn-array bool)] [n : i64]) : bool (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-broadcast (array-ref bs i) 0))) true))"
      "typecheck: spmd-broadcast value must have type i32, u32, i64, u64, f32, or f64; bool broadcast remains deferred")
    (compiler-typecheck-error-ok?
      "(define (main [bs : (__tl_dyn-array bool)] [out : (__tl_dyn-array bool)] [n : i64]) : bool (begin (foreach ([i : i64 0 n]) (set! (array-ref out i) (spmd-shuffle (array-ref bs i) 0))) true))"
      "typecheck: spmd-shuffle value must have type i32, u32, i64, u64, f32, or f64; bool shuffle remains deferred")))

;; Private dynamic-buffer signature rules: __tl_make-array length, array-ref
;; array/index types, array-set! value-type agreement, and __tl_array-push!
;; restrictions, with valid accepts.
(define (compiler-typecheck-array-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (f [a : (__tl_dyn-array i64)]) : i64 (begin (set! (array-ref a 0) 5) (array-ref a 0)))")
    (compiler-typecheck-ok?
      "(define (f) : i64 (let [a : (__tl_dyn-array i64) (__tl_make-array i64 4)] (array-length a)))")
    (compiler-typecheck-ok?
      "(define (f) : i64
  (let
    [items : (__tl_dyn-array String) (__tl_make-array \"left\" \"right\")]
    (array-length items)))")
    (compiler-typecheck-ok?
      "(define (f) : i64
  (let
    [items : (__tl_dyn-array u8) (__tl_make-array 1 2)]
    (array-length items)))")
    (compiler-typecheck-ok?
      "(define (f) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array (init) 7)]
    (+ (array-ref items 0) (array-ref items 1))))")
    (compiler-typecheck-ok?
      "(define (f) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array)]
    (array-length items)))")
    (compiler-typecheck-ok?
      "(define (f) : i64
  (let
    [a : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (begin
      (__tl_array-push! a 5)
      (array-length a))))")
    (compiler-typecheck-error-ok?
      "(define (f [a : (__tl_dyn-array i64)]) : i64 (array-ref a true))"
      "typecheck: array index must be integer")
    (compiler-typecheck-error-ok?
      "(define (f) : i64 (__tl_make-array i64 true))"
      "typecheck: __tl_make-array length must be integer")
    (compiler-typecheck-error-ok?
      "(define (f) : i64 (array-length (__tl_make-array)))"
      "typecheck: cannot infer element type of empty dynamic array literal")
    (compiler-typecheck-error-ok?
      "(define (f) : i64
  (let
    [items : (__tl_dyn-array (-> i64)) (__tl_make-array (lambda () : i64 1))]
    (array-length items)))"
      "typecheck: dynamic array literal element type is not supported")
    (compiler-typecheck-error-ok?
      "(define (f [a : (__tl_dyn-array i64)]) : unit (set! (array-ref a 0) true))"
      "typecheck: array assignment value type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (f [a : (__tl_dyn-array i64)]) : unit (__tl_array-push! a true))"
      "typecheck: __tl_array-push! value type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      "(define (f [a : (Array i64 2)]) : unit (__tl_array-push! a 5))"
      "typecheck: __tl_array-push! requires dynamic array type")))

;; comptime typecheck rules: a `(comptime ...)` form is typed by its
;; inner expression and flows that type to the use site (so an `i64` body is an
;; `i64`, a `bool` comparison is a `bool`, and a `let`/`if` body keeps its type);
;; `comptime` cannot reference a runtime variable, and a comptime result that
;; disagrees with the surrounding type is rejected like any other mismatch.
;; Type-literal and comptime-parameter rules (migrated from
;; src/typechecker.rs): scalar `comptime` parameters type-check/specialize,
;; `(type ...)` literals are compile-time only, source-level `type` positions
;; stay rejected, and type-valued comptime parameters specialize through
;; reflection when called with a type literal.
(define (compiler-typecheck-unknown-type-policy-message [name : String]) : String
  (str_cat.str-cat
    "typecheck: unknown type "
    name
    "; TypeLisp has no source-level type parameters; use comptime-generated concrete declarations instead"))

(define (compiler-typecheck-type-literal-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (twice [comptime n : i64]) : i64 (* n 2))
(define (main) : i64 (twice 21))")
    (compiler-typecheck-ok?
      "(defstruct Point (x i64))
(define (field-count [comptime T : type]) : i64
  (comptime (struct-field-count (type T))))
(define (main) : i64 (field-count (type Point)))")
    (compiler-typecheck-ok?
      "(define (main) : bool (comptime (array-dynamic? (type (__tl_dyn-array i64)))))")
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
      "(defstruct Point (x i64))
(define (field-count [comptime T : type]) : i64
  (comptime (struct-field-count (type T))))
(define (main) : i64 (field-count 1))"
      "comptime argument 'T' for function 'field-count' must be a type value such as `(type i64)`")))

(define (compiler-typecheck-stdlib-comptime-surface-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      "(module stdlib.comptime)
(defenum Expr
  (Int i64))"
      "typecheck: stdlib well-known type mismatch for stdlib.comptime.Expr: expected variant Bool at index 0")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        "(module stdlib.comptime)\n"
        "(defenum Expr
  (Bool bool)
  (Int i64)
  (Var String)
  (Splice (Box Expr))
  (If (Box Expr) (Box Expr) (Box Expr))
  (Call (Box Expr) ExprList)
  (Begin ExprList)
  (Quote (Box Expr))
  (Quasiquote (Box Expr))
  (Unquote (Box Expr))
  (UnquoteSplicing (Box Expr)))"
        "\n(defenum ExprList
  (Unexpected))")
      "typecheck: stdlib well-known type mismatch for stdlib.comptime.ExprList: expected defstruct")))

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
      "(import stdlib.comptime)
(define (mk) : comptime.Expr
  (comptime
    (comptime.expr-if
      (comptime.expr-bool true)
      (comptime.expr-splice (comptime.expr-bool false))
      (comptime.expr-bool true))))")
    (compiler-typecheck-ok?
      "(import stdlib.comptime)
(define (mk) : bool
  (comptime
    (comptime.expr-if?
      (comptime.expr-if
        (comptime.expr-bool true)
        (comptime.expr-bool false)
        (comptime.expr-bool true)))))")
    (compiler-typecheck-error-ok?
      "(import stdlib.comptime)
(define (mk) : comptime.Expr
  (comptime
    (comptime.expr-if
      true
      (comptime.expr-bool true)
      (comptime.expr-bool false))))"
      "expr-if condition expects Expr")
    (compiler-typecheck-error-ok?
      "(define (f [x : i64]) : i64 (comptime x))"
      "compile-time evaluation cannot reference runtime variable 'x'")
    (compiler-typecheck-error-ok?
      "(define (main) : f64 (comptime (__tl_float_sqrt 4.0)))"
      "compile-time square root is not supported; use __tl_float_sqrt at runtime")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (comptime (< 1 2)))"
      "typecheck: return type mismatch: expected i64, found bool")
    (compiler-typecheck-stdlib-comptime-surface-tests-ok?)))

;; IO-builtin signature rules: whole-file helpers and file-handle status
;; primitives accept, plus wrong-argument, wrong-arity, and result-type-mismatch
;; rejections. Migrated from src/typechecker.rs read-file/write-file coverage.
(define (compiler-typecheck-io-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String]) : ByteBuf (io.read-file p))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String]) : ByteBuf (io.read-file p))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String] [c : (& c bytes)]) : unit (io.write-file p c))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String] [c : (& c bytes)]) : i64
  (begin
    (io.write-file p c)
    (unsafe (io.file-open-status p 0))))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String] [c : (& c bytes)]) : i64 (io.append-file-status p c))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String]) : bool (io.file-exists? p))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [from : String] [to : String]) : i64
  (rename-status from to))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String]) : i64 (file-size-status p))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String]) : i64 (file-size p))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [from : String] [to : String]) : i64
  (rename-status from to))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f) : i64 (current-dir-status))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source "(define (f) : String (current-dir))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String]) : i64 (unsafe (io.file-open-status p 0)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [h : i64]) : i64 (unsafe (io.file-close-status h)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [h : i64] [n : i64]) : i64
  (unsafe (io.file-read-chunk-status h n)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [h : i64] [c : (& c bytes)]) : i64
  (unsafe (io.file-write-status h c)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [h : i64]) : i64 (unsafe (io.file-flush-status h)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [h : i64]) : ByteBuf
  (unsafe (io.file-read-chunk-bytes h)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [h : i64]) : bool
  (unsafe (io.file-read-chunk-eof? h)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f) : ByteBuf (read-stdin-line))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f) : ByteBuf (io.read-stdin-bytes 3))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source "(define (f) : bool (stdin-eof?))"))
    (compiler-typecheck-ok?
      "(define (io.read-file [n : i64]) : i64 (+ n 1))
(define (f) : i64 (io.read-file 41))")
    (compiler-typecheck-ok?
      "(define (io.file-open-status [path : i64] [mode : i64]) : bool true)
(define (f) : bool (io.file-open-status 1 2))")
    (compiler-typecheck-ok?
      "(define (read-stdin-line [limit : i64]) : i64 limit)
(define (f) : i64 (read-stdin-line 7))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [c : (& c bytes)]) : unit (io.write-file 5 c))")
      "typecheck: call `io.write-file` argument 1 type mismatch: expected String, found i32")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String]) : unit (io.write-file p))")
      "typecheck: call arity mismatch: io.write-file expected 2 arguments, got 1 argument")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : i64]) : ByteBuf (io.read-file p))")
      "typecheck: call `io.read-file` argument 1 type mismatch: expected String, found i64")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String]) : i64
  (unsafe (io.file-open-status p \"r\")))")
      "typecheck: call `io.file-open-status` argument 2 type mismatch: expected i64, found String")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [from : String]) : i64 (rename-status from 5))")
      "typecheck: call `rename-status` argument 2 type mismatch: expected String, found i32")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [from : String]) : i64 (rename-status from))")
      "typecheck: call arity mismatch: rename-status expected 2 arguments, got 1 argument")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [path : String]) : i64 (current-dir-status path))")
      "typecheck: call arity mismatch: current-dir-status expected 0 arguments, got 1 argument")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f) : i64 (unsafe (io.file-close-status \"h\")))")
      "typecheck: call `io.file-close-status` argument 1 type mismatch: expected i64, found String")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [h : i64]) : i64 (unsafe (io.file-write-status h 5)))")
      "typecheck: borrow requires a local, parameter, or aggregate place")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f) : i64 (unsafe (io.file-flush-status)))")
      "typecheck: call arity mismatch: io.file-flush-status expected 1 argument, got 0 arguments")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-fs-source
        "(define (f [p : String] [c : (& c bytes)]) : i64 (io.write-file p c))")
      "typecheck: return type mismatch: expected i64, found unit")
    (compiler-typecheck-error-ok?
      "(define (f) : String (current-dir))"
      "typecheck: unbound name current-dir")
    (compiler-typecheck-error-ok?
      "(define (f) : String (read-stdin-line))"
      "typecheck: unbound name read-stdin-line")
    (compiler-typecheck-error-ok?
      "(define (f [p : String]) : String (io.read-file p))"
      "typecheck: unknown qualified name io.read-file; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (f [p : String]) : i64 (io.file-open-status p 0))"
      "typecheck: unknown qualified name io.file-open-status; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (f) : i64 (process-id))"
      "typecheck: unbound name process-id")
    (compiler-typecheck-error-ok?
      "(define (f) : unit (flush-stdout))"
      "typecheck: unbound name flush-stdout")))

;; Raw-pointer null construction / check.
(define (compiler-typecheck-ptr-null-ok-source) : String
  "(define (main) : i64 (if (ptr-null? (ptr-null : (Ptr i64))) 1 0))")

(define (compiler-typecheck-ptr-null-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-ptr-null-ok-source))
    (compiler-typecheck-ok?
      "(define (main) : i64 (if (ptr-null? (ptr-null : (MutPtr i64))) 1 0))")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (if (ptr-null? (ptr-null : i64)) 1 0))"
      "typecheck: ptr-null requires a pointer type, e.g. (ptr-null : (Ptr i64))")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (if (ptr-null? 5) 1 0))"
      "typecheck: ptr-null? requires a raw pointer operand")))

;; Unsafe blocks: parse + typecheck like `begin`; empty `(unsafe)`
;; rejects at parse.
(define (compiler-typecheck-unsafe-ok-source) : String
  "(define (main) : i64 (unsafe 1 2 42))")

(define (compiler-typecheck-unsafe-callable-value-source [body : String]) : String
  (str_cat.str-cat
    "(unsafe (define (danger [x : i64]) : i64 x))
(define (safe [x : i64]) : i64 x)
(define (consume [f : (-> i64 i64)]) : i64 (f 42))
(defstruct CallbackHolder (callback (-> i64 i64)))
"
    body))

(define (compiler-typecheck-unsafe-callable-value-error-ok? [body : String]) : bool
  (compiler-typecheck-error-ok?
    (compiler-typecheck-unsafe-callable-value-source body)
    "typecheck: danger is an unsafe callable and cannot be used as a plain function value; call it directly inside unsafe"))

(define (compiler-typecheck-tls-current-arena-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? "(define (main) : i64 (tls-current-arena))")
    (compiler-typecheck-error-ok?
      "(define (main [arena : i64]) : unit
  (tls-current-arena-set! arena))"
      "typecheck: tls-current-arena-set! requires unsafe context")
    (compiler-typecheck-ok?
      "(define (main [arena : i64]) : unit
  (unsafe (tls-current-arena-set! arena)))")
    (compiler-typecheck-ok?
      "(define (tls-current-arena) : i64 17)
(define (tls-current-arena-set! [arena : i64]) : unit unit)
(define (main) : i64
  (begin
    (tls-current-arena-set! 41)
    (tls-current-arena)))")))

(define (compiler-typecheck-float-sqrt-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (sqrt64 [value : f64]) : f64 (__tl_float_sqrt value))
(define (sqrt32 [value : f32]) : f32 (__tl_float_sqrt value))
(define (main) : i64
  (if (= (sqrt64 4.0) 2.0)
    (if (= (sqrt32 (cast 9.0 : f32)) (cast 3.0 : f32)) 0 1)
    1))")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (__tl_float_sqrt 4))"
      "typecheck: __tl_float_sqrt expects f64 or f32")
    (compiler-typecheck-error-ok?
      "(define (main) : f64 (__tl_float_sqrt 4.0 9.0))"
      "typecheck: __tl_float_sqrt expects exactly one argument")
    (compiler-typecheck-ok?
      "(define (__tl_float_sqrt [value : i64]) : i64 value)
(define (main) : i64 (__tl_float_sqrt 4))")))

(define (compiler-typecheck-float-bitcast-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (f64-bits [value : f64]) : u64 (__tl_float_to_bits value))
(define (f32-bits [value : f32]) : u32 (__tl_float_to_bits value))
(define (f64-from [bits : u64]) : f64 (__tl_float_from_bits bits))
(define (f32-from [bits : u32]) : f32 (__tl_float_from_bits bits))
(define (main) : i64
  (if (= (f64-bits (f64-from (cast 0x3ff0000000000000 : u64)))
         (cast 0x3ff0000000000000 : u64))
    (if (= (f32-bits (f32-from (cast 0x3f800000 : u32)))
           (cast 0x3f800000 : u32))
      0
      1)
    1))")
    (compiler-typecheck-error-ok?
      "(define (main) : u64 (__tl_float_to_bits (cast 4 : u64)))"
      "typecheck: __tl_float_to_bits expects f64 or f32")
    (compiler-typecheck-error-ok?
      "(define (main) : f64 (__tl_float_from_bits 4.0))"
      "typecheck: __tl_float_from_bits expects u64 or u32")
    (compiler-typecheck-error-ok?
      "(define (main) : u64 (__tl_float_to_bits 4.0 9.0))"
      "typecheck: float bitcast expects exactly one argument")
    (compiler-typecheck-ok?
      "(define (__tl_float_to_bits [value : i64]) : i64 value)
(define (main) : i64 (__tl_float_to_bits 4))")))

(define (compiler-typecheck-unsafe-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-unsafe-ok-source))
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (unsafe))"
      "parse: unsafe requires a non-empty body")))

(define (compiler-typecheck-unsafe-decl-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64 (danger 42))"
      "typecheck: danger requires unsafe context")
    (compiler-typecheck-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64 (unsafe (danger 42)))")
    (compiler-typecheck-error-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64
  (let [f : (-> i64 i64) danger]
    (f 42)))"
      "typecheck: danger requires unsafe context")
    (compiler-typecheck-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64
  (let [danger : (-> i64 i64) (lambda ([x : i64]) : i64 x)]
    (danger 42)))")
    (compiler-typecheck-error-ok?
      "(unsafe (extern (raw-call [arg0 : i64]) : i64))
(define (main) : i64 (raw-call 42))"
      "typecheck: raw-call requires unsafe context")
    (compiler-typecheck-ok?
      "(unsafe (extern (raw-call [arg0 : i64]) : i64))
(define (main) : i64 (unsafe (raw-call 42)))")
    (compiler-typecheck-error-ok?
      "(module foreign)
(unsafe (define (danger [x : i64]) : i64 x))
(module main)
(import foreign as f)
(define (main) : i64 (f.danger 42))"
      "typecheck: f/danger requires unsafe context")
    (compiler-typecheck-ok?
      "(module foreign)
(unsafe (define (danger [x : i64]) : i64 x))
(module main)
(import foreign as f)
(define (main) : i64 (unsafe (f.danger 42)))")
    (compiler-typecheck-error-ok?
      "(unsafe (define (read-it [p : (Ptr i64)]) : i64 (ptr-read p)))"
      "typecheck: ptr-read requires unsafe context")
    ;; A conservative v1 contract rejects every first-class flow at the
    ;; unsafe declaration reference itself, before the destination can erase
    ;; the checker-only call effect.
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64
  (let [f : (-> i64 i64) (unsafe danger)] (f 42)))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64
  (let [f (unsafe danger)] (f 42)))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main [flag : bool]) : i64
  (let [f : (-> i64 i64) (unsafe (if flag danger safe))] (f 42)))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64 (unsafe (consume danger)))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (leak) : (-> i64 i64) (unsafe danger))
(define (main) : i64 ((leak) 42))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define leaked : (-> i64 i64) (unsafe danger))
(define (main) : i64 (leaked 42))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64
  (let [f : (-> i64 i64) safe]
    (unsafe (begin (set! f danger) (f 42)))))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64
  (let [pair : (Tuple (-> i64 i64) (-> i64 i64))
    (unsafe (tuple danger safe))]
    42))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64
  (let [items : (Array (-> i64 i64) 2)
    (unsafe (array danger safe))]
    42))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64
  (let [holder : CallbackHolder (unsafe (CallbackHolder danger))]
    42))")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64
  (let [holder : (Box (-> i64 i64)) (unsafe (box danger))]
    42))")
    (compiler-typecheck-error-ok?
      "(unsafe (extern (raw-call [arg0 : i64]) : i64))
(define (main) : i64
  (let [f : (-> i64 i64) (unsafe raw-call)]
    (f 42)))"
      "typecheck: raw-call is an unsafe callable and cannot be used as a plain function value; call it directly inside unsafe")
    (compiler-typecheck-error-ok?
      "(module foreign)
(unsafe (define (danger [x : i64]) : i64 x))
(module main)
(import foreign as f)
(define (main) : i64
  (let [leaked : (-> i64 i64) (unsafe f.danger)]
    (leaked 42)))"
      "typecheck: f/danger is an unsafe callable and cannot be used as a plain function value; call it directly inside unsafe")
    (compiler-typecheck-error-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64
  (let [f : (-> i64 i64)
    (unsafe (lambda ([x : i64]) : i64 (danger x)))]
    (f 42)))"
      "typecheck: danger requires unsafe context")
    (compiler-typecheck-unsafe-callable-value-error-ok?
      "(define (main) : i64
  (let [factory : (-> (-> i64 i64))
    (lambda () : (-> i64 i64) (unsafe danger))]
    42))")
    (compiler-typecheck-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(define (main) : i64
  (let [f : (-> i64 i64)
    (lambda ([x : i64]) : i64 (unsafe (danger x)))]
    (f 42)))")
    (compiler-typecheck-error-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(defmacro (danger-value) : Expr `(unsafe danger))
(define (main) : i64
  (let [f : (-> i64 i64) (danger-value)]
    (f 42)))"
      "typecheck: danger is an unsafe callable and cannot be used as a plain function value; call it directly inside unsafe")
    (compiler-typecheck-error-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(defmacro (danger-value) : Expr (expr-var \"danger\"))
(define (main) : i64
  (let [f : (-> i64 i64) (unsafe (danger-value))]
    (f 42)))"
      "typecheck: danger is an unsafe callable and cannot be used as a plain function value; call it directly inside unsafe")))

(define (compiler-typecheck-arena-unsafe-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : i64
  (let
    [arena : Arena (arena-make)]
    [current : Arena (arena-current)]
    [mark : ArenaMark (arena-mark)]
    (+
      (arena-raw-handle arena)
      (+ (arena-raw-handle current) (arena-mark-raw-handle mark)))))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (main) : i64
  (with-arena r
    (let [s : String (string.int->string 41)]
      (__tl_string_length s))))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : unit
  (arena-set! (arena-current)))")
      "typecheck: arena-set! requires unsafe context")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : unit
  (arena-destroy (arena-current)))")
      "typecheck: arena-destroy requires unsafe context")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : unit
  (arena-rewind (arena-mark)))")
      "typecheck: arena-rewind requires unsafe context")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : unit
  (let
    [rewind : (-> ArenaMark unit) arena-rewind]
    (rewind (arena-mark))))")
      "typecheck: arena-rewind requires unsafe context")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (arena-make))"
      "typecheck: unbound name arena-make")
    (compiler-typecheck-ok?
      "(define (arena-rewind [mark : i64]) : unit unit)
(define (arena-set! [arena : i64]) : unit unit)
(define (arena-destroy [arena : i64]) : unit unit)
(define (main) : unit
  (begin
    (arena-rewind 1)
    (arena-set! 2)
    (arena-destroy 3)))")
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : unit
  (let
    [arena-rewind : (-> i64 unit) (lambda ([mark : i64]) : unit unit)]
    (arena-rewind 1)))"))
    (compiler-typecheck-ok?
      "(module fake.arena)
(defstruct Arena (value i64))
(define (make) : Arena (Arena 1))
(define (phase [value : i64]) : i64 value)
(define (rewind-safe! [value : i64]) : i64 value)
(define (destroy-safe! [value : i64]) : i64 value)
(module main)
(import fake.arena as arena)
(define (phase [value : i64]) : i64 value)
(define (rewind-safe! [value : i64]) : i64 value)
(define (destroy-safe! [value : i64]) : i64 value)
(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (+
      owner.value
      (+ (arena.phase 10)
        (+
          (arena.rewind-safe! 20)
          (+
            (arena.destroy-safe! 11)
            (+ (phase 1) (+ (rewind-safe! 2) (destroy-safe! 3)))))))))")
    (compiler-typecheck-error-ok?
      "(module fake.arena)
(defstruct Arena (value i64))
(define (make) : Arena (Arena 1))
(module main)
(import fake.arena as arena)
(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (in-arena owner 42)))"
      "typecheck: in-arena arena must be Arena")
    (compiler-typecheck-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : unit
  (let
    [arena : Arena (arena-current)]
    [mark : ArenaMark (arena-mark)]
    (unsafe
      (arena-rewind mark)
      (arena-set! arena)
      (arena-destroy arena))))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-arena-source
        "(define (main) : unit
  (let
    [mark : ArenaMark (arena-mark)]
    (unsafe
      (let
        [rewind : (-> ArenaMark unit) arena-rewind]
        (rewind mark)))))")
      "typecheck: arena-rewind is an unsafe callable and cannot be used as a plain function value; call it directly inside unsafe")))

;; CTFE layout queries: folded calls produce `i64`, runtime calls are
;; rejected, and `offset-of` is restricted to structs with known fields.
(define (compiler-typecheck-layout-query-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (f) : i64 (comptime (size-of (type i64))))")
    (compiler-typecheck-ok?
      "(define (f) : i64 (comptime (align-of (type bool))))")
    (compiler-typecheck-ok?
      "(defstruct Inner
  (x i32))
(defstruct Outer
  (tag u8)
  (inner Inner)
  (tail i64))
(define (f) : i64
  (comptime (+ (size-of (type Outer)) (offset-of (type Outer) tail))))")
    (compiler-typecheck-ok?
      "(defenum Choice
  (Empty)
  (Wide u8 i64))
(define (f) : i64
  (comptime (+ (size-of (type Choice)) (align-of (type Choice)))))")
    (compiler-typecheck-ok?
      "(defstruct Box (x i64))
(define (f) : i64 (comptime (offset-of (type Box) x)))")
    (compiler-typecheck-error-ok?
      "(define (f) : i64 (comptime (size-of (type i64) (type bool))))"
      "size-of expects exactly one type argument")
    (compiler-typecheck-error-ok?
      "(define (f) : i64 (size-of (type i64)))"
      "typecheck: size-of is compile-time only; wrap it in (comptime ...)")
    (compiler-typecheck-error-ok?
      "(defstruct Packet
  (tag u8)
  (count i64))
(define (f) : i64 (comptime (offset-of (type Packet) missing)))"
      "offset-of unknown field missing")
    ;; Imported nominal types resolve through the import like an annotation
    ;; (#8112): an alias and a module-name qualification, struct and enum
    ;; queries, and a same-named type of another module. Each answer sizes a
    ;; fixed array, so a wrong layout is a return type mismatch.
    (compiler-typecheck-ok? (compiler-typecheck-imported-layout-source))
    (compiler-typecheck-error-ok?
      "(module geom)
(defstruct Point (x i64))
(module main)
(import geom as g)
(define (f) : i64 (comptime (size-of (type g.Missing))))"
      "typecheck: unknown type g.Missing; TypeLisp has no source-level type parameters; use comptime-generated concrete declarations instead")
    (compiler-typecheck-error-ok?
      "(module geom)
(defstruct Packet
  (:repr c)
  (tag u8)
  (count i64))
(module main)
(import geom as g)
(define (f) : i64 (comptime (offset-of (type g.Packet) missing)))"
      "offset-of unknown field missing")
    (compiler-typecheck-error-ok?
      "(module geom)
(defstruct Point (x i64))
(module main)
(import geom as g)
(define (f) : i64 (size-of (type g.Point)))"
      "typecheck: size-of is compile-time only; wrap it in (comptime ...)")))

(define (compiler-typecheck-imported-layout-source) : String
  "(module geom)
(defstruct Point (x i64) (y i64))
(defstruct Packet
  (:repr c)
  (tag u8)
  (count i64))
(defenum Shape (Dot) (Box Point))
(module narrow)
(defstruct Point (x i8))
(module main)
(import geom as g)
(import narrow)
(define (aliased) : (Array i64 16)
  (make-array i64 (comptime (size-of (type g.Point)))))
(define (aligned) : (Array i64 8)
  (make-array i64 (comptime (align-of (type g.Point)))))
(define (offset) : (Array i64 8)
  (make-array i64 (comptime (offset-of (type g.Packet) count))))
(define (qualified) : (Array i64 1)
  (make-array i64 (comptime (size-of (type narrow.Point)))))
(define (shape) : (Array i64 24)
  (make-array i64 (comptime (size-of (type g.Shape)))))
(define (shape-align) : (Array i64 8)
  (make-array i64 (comptime (align-of (type g.Shape)))))")

;; Keep the public spelling here until #6133 teaches CTFE's captured type
;; expression bridge to recognize the private alias used as a macro operand.
(define (compiler-typecheck-reflection-array-length-dynamic-source) : String
  "(import stdlib.comptime)
(defmacro (fixed-length [T : type]) : i64
  (comptime.expr-int (array-length T)))
(define (main) : i64 (fixed-length (__tl_dyn-array i64)))")

(define (compiler-typecheck-reflection-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defstruct Point (x i64) (flag bool))
(defenum Maybe (None) (Some String))
(define (field-count-helper [comptime T : type]) : i64
  (comptime (struct-field-count (type T))))
(define (enum-payload-helper [comptime T : type]) : i64
  (comptime (enum-variant-payload-count (type T) 1)))
(define (main) : i64
  (+ (field-count-helper (type Point))
     (+ (enum-payload-helper (type Maybe))
        (+ (comptime (if (__tl_string_eq (type-kind (type Point)) \"struct\") 1 0))
           (+ (comptime (if (__tl_string_eq (type-nominal-name (type Point)) \"Point\") 1 0))
              (+ (comptime (if (= (struct-field-type (type Point) 0) (type i64)) 1 0))
                 (+ (comptime (if (= (enum-variant-payload-type (type Maybe) 1 0) (type String)) 1 0))
                    (+ (comptime (array-length (type (Array i64 4))))
                       (+ (comptime (if (__tl_string_eq (type-key (type (& r str))) \"ref_r_str\") 1 0))
                          (+ (comptime (function-param-count (type (-> i64 bool String))))
                             (+ (comptime (tuple-element-count (type (Tuple i64 bool String))))
                                (comptime (if (= (tuple-element-type (type (Tuple i64 bool)) 1) (type bool)) 1 0)))))))))))))")
    (compiler-typecheck-ok?
      "(defmacro (tuple-decls [T : type]) : Decls
  (let
    [score : i64
      (if (= (tuple-element-count T) 3)
        (if (__tl_string_eq (type-kind (tuple-element-type T 2)) \"string\")
          40
          0)
        0)]
    `(define (tuple-decl-score) : i64 ,(expr-int score))))
(defmacro (tuple-module [T : type]) : Module
  (let
    [score : i64
      (if (= (tuple-element-count T) 2)
        (if (__tl_string_eq
          (type-kind (tuple-element-type T 1))
          \"bool\")
          2
          0)
        0)]
    `(begin
      (module generated.tuple_reflection)
      (define (tuple-score) : i64 ,(expr-int score)))))
(tuple-decls (Tuple i64 bool String))
(import (tuple-module (Tuple i64 bool)) as reflected)
(define (main) : i64 (+ (tuple-decl-score) (reflected.tuple-score)))")
    (compiler-typecheck-ok?
      "(import stdlib.comptime)
(defmacro (fixed-length [T : type]) : i64
  (comptime.expr-int (array-length T)))
(define (main) : i64 (fixed-length (Array i64 3)))")
    (compiler-typecheck-ok?
      "(defmacro (kind-code [T : type (:kind i64 bool)]) : i64
  (if (__tl_string_eq (type-kind T) \"i64\")
    (expr-int 64)
    (expr-int 1)))
(define (main) : i64 (+ (kind-code i64) (kind-code bool)))")
    (compiler-typecheck-error-ok?
      "(module app)
(defmacro (kind-code [T : type (:kind i64 i32 bool)]) : i64
  (expr-int 0))
(define (main) : i64 (kind-code (Array i64 4)))"
      "typecheck: macro app.kind-code type operand T rejects (Array i64 4): expected one of :kind i64, i32, bool")
    (compiler-typecheck-error-location-ok?
      "(defmacro (emit-bad [T : type (:kind struct enum)]) : Decls
  (let
    [count : i64 (struct-field-count T)]
    `(define (generated-bad) : i64 ,(expr-int count))))
(define (main) : i64 0)"
      "typecheck: macro emit-bad constrained type operand T cannot use struct-field-count; requires struct"
      2
      3)
    (compiler-typecheck-ok?
      "(defstruct Point (x i64) (y bool))
(defenum Maybe (None) (Some i64))
(defmacro (emit-kind-count [T : type (:kind struct enum)]) : Decls
  (if (__tl_string_eq (type-kind T) \"struct\")
    `(define (generated-struct-count) : i64
      ,(expr-int (struct-field-count T)))
    `(define (generated-enum-count) : i64
      ,(expr-int (enum-variant-count T)))))
(emit-kind-count Point)
(emit-kind-count Maybe)
(define (main) : i64
  (+ (generated-struct-count) (generated-enum-count)))")
    (compiler-typecheck-error-ok?
      "(defmacro (emit-wrong-branch [T : type (:kind struct enum)]) : Decls
  (if (__tl_string_eq (type-kind T) \"struct\")
    `(define (generated-wrong) : i64
      ,(expr-int (enum-variant-count T)))
    `(define (generated-other) : i64 0)))
(define (main) : i64 0)"
      "typecheck: macro emit-wrong-branch constrained type operand T cannot use enum-variant-count; requires enum")
    (compiler-typecheck-error-ok?
      "(defmacro (emit-wrong-else [T : type (:kind struct i64 bool)]) : Decls
  (if (__tl_string_eq (type-kind T) \"i64\")
    `(define (generated-scalar) : i64 0)
    `(define (generated-not-i64) : i64
      ,(expr-int (struct-field-count T)))))
(define (main) : i64 0)"
      "typecheck: macro emit-wrong-else constrained type operand T cannot use struct-field-count; requires struct")
    (compiler-typecheck-error-ok?
      "(defmacro (emit-array-length [T : type (:kind array)]) : Decls
  `(define (generated-length) : i64 ,(expr-int (array-length T))))
(define (main) : i64 0)"
      "typecheck: macro emit-array-length constrained type operand T cannot use array-length; requires fixed array shape")
    (compiler-typecheck-ok?
      "(defmacro (cleanup-name-direct [T : type (:kind struct enum)]) : Expr
  (if (type-cleanup-owning? T)
    (expr-string (type-cleanup-function T))
    (expr-string \"\")))
(defmacro (cleanup-name-nested [T : type (:kind struct enum)]) : Expr
  (if (type-cleanup-owning? T)
    (if (type-cleanup-owning? T)
      (expr-string (type-cleanup-function T))
      (expr-string (type-cleanup-function T)))
    (expr-string \"\")))
(define (main) : i64 0)")
    (compiler-typecheck-error-ok?
      "(defmacro (cleanup-name-bad [T : type (:kind struct enum)]) : Expr
  (expr-string (type-cleanup-function T)))
(define (main) : i64 0)"
      "typecheck: macro cleanup-name-bad constrained type operand T cannot use type-cleanup-function; requires cleanup-owning type")
    (compiler-typecheck-error-ok?
      "(defmacro (cleanup-name-wrong-else [T : type (:kind struct enum)]) : Expr
  (if (type-cleanup-owning? T)
    (expr-string \"\")
    (expr-string (type-cleanup-function T))))
(define (main) : i64 0)"
      "typecheck: macro cleanup-name-wrong-else constrained type operand T cannot use type-cleanup-function; requires cleanup-owning type")
    (compiler-typecheck-ok?
      "(defmacro (emit-shadowed [T : type (:kind struct enum)]) : Decls
  (let
    [struct-field-count : (-> Expr i64)
      (lambda ([ignored : Expr]) : i64 0)]
    `(define (generated-shadowed) : i64
      ,(expr-int (struct-field-count T)))))
(define (main) : i64 0)")
    (compiler-typecheck-error-ok?
      "(defmacro (emit-alias-bad [T : type (:kind struct enum)]) : Decls
  (let
    [U T]
    `(define (generated-alias-bad) : i64
      ,(expr-int (struct-field-count U)))))
(define (main) : i64 0)"
      "typecheck: macro emit-alias-bad constrained type operand T cannot use struct-field-count; requires struct")
    (compiler-typecheck-error-ok?
      "(defmacro (emit-alias-chain-bad [T : type (:kind struct enum)]) : Decls
  (let
    [U T]
    [V U]
    `(define (generated-alias-chain-bad) : i64
      ,(expr-int (struct-field-count V)))))
(define (main) : i64 0)"
      "typecheck: macro emit-alias-chain-bad constrained type operand T cannot use struct-field-count; requires struct")
    (compiler-typecheck-ok?
      "(defmacro (emit-alias-shadow
  [T : type (:kind struct enum)]
  [V : type (:kind struct)]) : Decls
  (let
    [U T]
    (let
      [U V]
      `(define (generated-alias-shadow) : i64
        ,(expr-int (struct-field-count U))))))
(define (main) : i64 0)")
    (compiler-typecheck-ok?
      "(defstruct Point (x i64))
(defmacro (record-leaf [T : type (:kind struct enum)]) : Module
  `(begin
    (module generated.type_kind_leaf)
    (define reflected-kind : String ,(expr-string (type-kind T)))))
(defmacro (record-module [T : type (:kind struct enum)]) : Module
  `(begin
    (module generated.type_kind_record)
    (import (record-leaf T) as leaf)
    (define reflected-kind : String
      (unsafe (ptr-read (ptr-addr-of leaf.reflected-kind))))))
(import (record-module Point) as first)
(import (record-module Point) as second)
(define (main) : i64
  (if (__tl_string_eq first.reflected-kind second.reflected-kind) 0 1))")
    (compiler-typecheck-ok?
      "(define answer : i64 42)
(define (make [value : i64]) : bool (> value 0))
(defstruct Pair (value i64))
(defenum Maybe (None) (Some i64))
(defmacro (ignored [value : Expr]) : Expr value)
(import stdlib.comptime)
(define (main) : i64
  (comptime
    (if (comptime.module-value? \"\" \"answer\")
      (if (comptime.module-value? \"\" \"make\")
        (if (= (comptime.module-value-type \"\" \"answer\") (type i64))
          (if (= (comptime.module-value-type \"\" \"make\") (type (-> i64 bool)))
            (if (= (comptime.module-value-type \"\" \"Pair\") (type (-> i64 Pair)))
              (if (= (comptime.module-value-type \"\" \"Some\") (type (-> i64 Maybe)))
                (if (comptime.module-value? \"\" \"Maybe\")
                  0
                  (if (comptime.module-value? \"\" \"ignored\") 0 42))
                0)
              0)
            0)
          0)
        0)
      0)))")
    (compiler-typecheck-ok?
      "(import stdlib.comptime)
(defmacro (identity-reference [value : Expr]) : Expr
  (let
    [referent : Expr
      (comptime.reference-element-type (comptime.expr-type value))]
    value))
(define (shared-id [value : (& caller_shared i64)]) : (& caller_shared i64)
  (identity-reference value))
(define (mutable-id [value : (&mut caller_mutable i64)]) : (&mut caller_mutable i64)
  (identity-reference value))
(define (main) : i64 0)")
    (compiler-typecheck-error-ok?
      "(defmacro (record-module [T : type (:kind struct enum)]) : Module
  `(begin
    (module generated.type_kind_record)
    (define reflected-kind : String ,(expr-string (type-kind T)))))
(import (record-module (Array i64 4)) as rejected)
(define (main) : i64 0)"
      "typecheck: macro record-module type operand T rejects (Array i64 4): expected one of :kind struct, enum")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-reflection-array-length-dynamic-source)
      "array-length requires fixed array type")
    (compiler-typecheck-error-ok?
      "(define (main) : String (type-kind (type i64)))"
      "typecheck: type-kind is compile-time only; wrap it in (comptime ...)")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (tuple-element-count (type (Tuple i64 bool))))"
      "typecheck: tuple-element-count is compile-time only; wrap it in (comptime ...)")
    (compiler-typecheck-error-ok?
      "(define (main) : String (comptime (type-kind (type i64))))"
      "String value is compile-time only")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (comptime (struct-field-count (type i64))))"
      "struct-field-count requires struct type")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (comptime (tuple-element-count (type i64))))"
      "tuple-element-count requires tuple type")
    (compiler-typecheck-error-ok?
      "(define (main) : i64
  (comptime
    (if (= (tuple-element-type (type (Tuple i64)) 1) (type i64))
      1
      0)))"
      "tuple-element-type index out of range")
    (compiler-typecheck-error-ok?
      "(define answer : i64 42)
(import stdlib.comptime)
(define (main) : i64
  (comptime (if (= (comptime.module-value-type \"\" \"missing\") (type i64)) 1 0)))"
      "module-value-type: module  does not define value missing")
    (compiler-typecheck-error-ok?
      "(import stdlib.comptime)
(define (main) : i64
  (comptime
    (if (= (comptime.reference-element-type (type i64)) (type i64)) 1 0)))"
      "reference-element-type requires reference type")))

;; Kind-constrained and unconstrained Decls macros, inside and outside a named
;; module, generate declarations that pass the ordinary post-expansion check.
(define (compiler-typecheck-macro-generated-decl-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defstruct Point (x i64) (y bool))
(defenum Maybe (None) (Some i64))
(defmacro (emit-kind-count [T : type (:kind struct enum)]) : Decls
  (if (__tl_string_eq (type-kind T) \"struct\")
    `(define (generated-struct-count) : i64
      ,(expr-int (struct-field-count T)))
    `(define (generated-enum-count) : i64
      ,(expr-int (enum-variant-count T)))))
(emit-kind-count Point)
(define (main) : i64 (generated-struct-count))")
    (compiler-typecheck-ok?
      "(module app)
(defmacro (emit-one [T : type (:kind i64)]) : Decls
  `(define (generated-one) : i64 1))
(emit-one i64)
(define (main) : i64 (generated-one))")
    (compiler-typecheck-ok?
      "(defmacro (emit-two [v : Expr]) : Decls
  `(define (generated-two) : i64 2))
(emit-two 5)
(define (main) : i64 (generated-two))")
    ;; A signature naming a type that a later splice defines, or a module alias
    ;; a later import publishes, is unresolved when the walk starts. The splice
    ;; that adds the type or the alias re-resolves it, including one a
    ;; function-only splice generated earlier; function-only splices skip the
    ;; re-resolution. `expr-type` fails on a still-unresolved signature.
    (compiler-typecheck-ok?
      "(defmacro (gen-struct) : Decls `(defstruct Late (v i64)))
(defmacro (gen-fn [name : Expr]) : Decls `(define (,name) : i64 1))
(defmacro (gen-user [name : Expr]) : Decls `(define (,name [x : Late]) : Late x))
(defmacro (late-code [value : Expr]) : i64
  (let [T : Expr (expr-type value)]
    (if (__tl_string_eq (type-kind T) \"struct\")
      (if (__tl_string_eq (type-nominal-name T) \"Late\")
        (expr-int 1)
        (comptime-error (type-nominal-name T)))
      (comptime-error (type-kind T)))))
(define (early [x : Late]) : Late x)
(gen-fn a1)
(gen-user late-user)
(gen-fn a2)
(gen-struct)
(gen-fn a3)
(define (main) : i64
  (+ (late-code (early (Late 5)))
     (+ (late-code (late-user (Late 6))) (a3))))")
    (compiler-typecheck-ok?
      "(defmacro (gen-box) : Module
  `(begin
    (module gen.box)
    (defstruct Box (v i64))))
(defmacro (gen-fn [name : Expr]) : Decls `(define (,name) : i64 1))
(defmacro (box-code [value : Expr]) : i64
  (let [T : Expr (expr-type value)]
    (if (__tl_string_eq (type-kind T) \"struct\")
      (expr-int 1)
      (comptime-error (type-kind T)))))
(import (gen-box) as bx)
(gen-fn a1)
(import (gen-box) as by)
(gen-fn a2)
(define (early [x : bx.Box]) : bx.Box x)
(define (early2 [x : by.Box]) : by.Box x)
(gen-fn a3)
(define (main) : i64
  (+ (box-code (early (bx.Box 5)))
     (+ (box-code (early2 (by.Box 6))) (a3))))")))

(define (compiler-typecheck-quote-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (mk [e : Expr]) : Expr `(if ,e true false))
(define (body [xs : ExprList]) : Expr `(begin ,@xs))
(define (main) : i64 0)")
    (compiler-typecheck-error-ok?
      "(define (bad [x : i64]) : Expr `(if ,x true false))
(define (main) : i64 0)"
      "typecheck: unquote expects Expr: expected Expr, found i64")
    (compiler-typecheck-error-ok?
      "(define (bad [x : i64]) : Expr `(begin ,@x))
(define (main) : i64 0)"
      "typecheck: unquote-splicing expects ExprList: expected ExprList, found i64")))

;; The definition-time body probe binds a `Var` per ordinary operand and an
;; empty list per variadic, so it takes both error arms below. Only a call that
;; takes one may report it, with the macro author's message.
(define (compiler-typecheck-defmacro-probe-error-source
  [int-operand : String]
  [first-operands : String]) : String
  (str_cat.str-cat
    "(import stdlib.comptime)
(defmacro (int-only [x : comptime.Expr]) : comptime.Expr
  (match x
    [(comptime.Expr.Var _) (comptime.comptime-error \"int-only: identifier\")]
    [_ x]))
(defmacro (first-of [xs : i64 ...]) : i64
  (if (= (comptime.expr-list-length xs) 0)
    (comptime.comptime-error \"first-of: no operand\")
    (comptime.expr-list-nth xs 0)))
(define (main) : i64 (+ (int-only "
    int-operand
    ") (first-of"
    first-operands
    ")))"))

(define (compiler-typecheck-defmacro-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(defmacro (first [x : bool] [rest : bool ...]) : bool x)
(define (main) : i64 0)")
    (compiler-typecheck-ok?
      "(defmacro (answer-name) : i64
  (expr-var (if (__tl_string_eq \"ans\" \"ans\") \"answer\" \"bad\")))
(define answer : i64 42)
(define (main) : i64 (answer-name))")
    (compiler-typecheck-ok?
      "(defstruct Point (x i64) (y i64))
(defmacro (field-x [target : Expr]) : i64
  (comptime.expr-struct-get
    target
    (if (__tl_string_eq \"x\" \"x\") \"x\" \"y\")))
(define (main) : i64 (field-x (Point 42 7)))")
    (compiler-typecheck-ok?
      "(import stdlib.comptime)
(defmacro (all [args : bool ...]) : bool
  `(all-from (__all-args ,@args) 0))
(defmacro (all-from [carrier : comptime.Expr] [idx : comptime.Expr]) : bool
  (match idx
    [(comptime.Expr.Int i)
      (match carrier
        [(comptime.Expr.Call _ elems)
          (if (>= i (comptime.expr-list-length elems))
            (comptime.expr-bool true)
            `(if ,(comptime.expr-list-nth elems i)
               (all-from ,carrier ,(comptime.expr-int (+ i 1)))
               false))]
        [_ (comptime.expr-bool true)])]
    [_ (comptime.expr-bool true)]))
(defmacro (pick [arms : ExprClause ...]) : i64
  `(pick-from 0 ,@(comptime.expr-clause-list->expr-list arms)))
(defmacro (pick-from [idx : comptime.Expr] [arms : ExprClause ...]) : i64
  (match idx
    [(comptime.Expr.Int i)
      (if (>= i (comptime.expr-clause-list-length arms))
        (comptime.expr-int 0)
        (let
          [arm : ExprClause (comptime.expr-clause-list-nth arms i)]
          `(if ,(comptime.expr-clause-first arm)
             ,(comptime.expr-clause-second arm)
             (pick-from
               ,(comptime.expr-int (+ i 1))
               ,@(comptime.expr-clause-list->expr-list arms)))))]
    [_ (comptime.expr-int 0)]))
(define (main) : i64
  (if (all true true)
    (pick [false 1] [true 42])
    0))")
    (compiler-typecheck-ok?
      "(import stdlib.comptime)
(defmacro (pick-if [value : bool]) : i64
  (let [expr : Expr (expr-if value (expr-int 7) (expr-int 9))]
    (match expr
      [(Expr.If _ _ _)
        (if (comptime.expr-if? expr)
          (if (comptime.expr-bool? (comptime.expr-if-cond expr))
            (if (comptime.expr-bool-value (comptime.expr-if-cond expr))
              (comptime.expr-if-then expr)
              (comptime.expr-if-else expr))
            (expr-int 0))
          (expr-int 0))]
      [_ (expr-int 0)])))
(defmacro (pick-clause [arm : ExprClause] [take-first : bool]) : i64
  (match arm
    [(ExprClause _ _)
      (if (comptime.expr-bool-value take-first)
        (comptime.expr-clause-first arm)
        (comptime.expr-clause-second arm))]))
(define (main) : i64
  (+ (pick-if true)
     (+ (pick-if false)
        (+ (pick-clause [1 25] true)
           (pick-clause [99 25] false)))))")
    (compiler-typecheck-error-ok?
      "(import stdlib.comptime)
(defenum Other
  (Var String))
(defmacro (bad [value : comptime.Expr]) : bool
  (match value
    [(Other.Var _) true]
    [_ false]))
(define (main) : i64 0)"
      "typecheck: unknown Expr variant Other.Var")
    (compiler-typecheck-error-ok?
      "(defmacro (bad) : i64 (expr-bool true))
(define (main) : i64 0)"
      "typecheck: macro body produced type does not match declaration")
    (compiler-typecheck-error-ok?
      "(defmacro (bad [x : bool]) : bool (expr-bool? x))
(define (main) : i64 0)"
      "typecheck: macro body must return Expr: expected Expr, found bool")
    (compiler-typecheck-ok?
      (compiler-typecheck-defmacro-probe-error-source "1" " 2 3"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defmacro-probe-error-source "main" " 2 3")
      "int-only: identifier")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-defmacro-probe-error-source "1" "")
      "first-of: no operand")
    (compiler-typecheck-error-ok?
      "(defmacro (bad) : bool (unsafe (expr-bool true)))
(define (main) : i64 0)"
      "typecheck: comptime purity rejects unsafe block; reference path: bad -> unsafe")
    (compiler-typecheck-error-ok?
      "(extern (io.read-file [path : String]) : String)
(defmacro (bad) : Expr (io.read-file \"input.txt\"))
(define (main) : i64 0)"
      "typecheck: comptime purity rejects extern reference io.read-file; reference path: bad -> io.read-file")
    (compiler-typecheck-error-ok?
      "(extern (raw-read) : String)
(define (helper) : String (raw-read))
(defmacro (bad) : Expr (helper))
(define (main) : i64 0)"
      "typecheck: comptime purity rejects extern reference raw-read; reference path: bad -> helper -> raw-read")))

;; --- macro expansion phase --------------------------------------------------
;; A macro call in an evaluated position is expanded before typechecking; the
;; spliced form must then typecheck. Arity and typed operands are checked at the
;; call site before the transformer runs; Expr operands are syntax captures.
(define (compiler-typecheck-macro-expand-source) : String
  "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (main) : i64
  (let [flag : bool true]
    (if (and2 flag true) 1 0)))")

;; A syntax (`Expr`) parameter disables the content-addressed memo shortcut, so
;; every import of the same generated identity re-expands the macro and replays
;; the fresh body against the materialized one. Hygienic locals must rename to
;; the same ids across those expansions, or the replay reports a payload
;; conflict for what is one module.
(define (compiler-typecheck-module-macro-import-syntax-param-repeat-source) : String
  "(defmacro (gen [T : type] [capabilities : Expr ...]) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64
      (let
        [cap : i64 42]
        cap))))
(import (gen i64 core) as first)
(import (gen i64 core) as second)
(define (main) : i64 (+ (first.answer) (second.answer)))")

(define (compiler-typecheck-macro-prelude-module-source) : String
  "(module stdlib.core_macros)
(defmacro (and [args : bool ...]) : bool
  `(and-from (__and-args ,@args) 0))
(defmacro (and-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool true)
            `(if ,(expr-list-nth elems i)
               (and-from ,carrier ,(expr-int (+ i 1)))
               false))]
        [_ (expr-bool true)])]
    [_ (expr-bool true)]))
(defmacro (or [args : bool ...]) : bool
  `(or-from (__or-args ,@args) 0))
(defmacro (or-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool false)
            `(if ,(expr-list-nth elems i)
               true
               (or-from ,carrier ,(expr-int (+ i 1)))))]
        [_ (expr-bool false)])]
    [_ (expr-bool false)]))
(defmacro (for [forms : Expr ...]) : unit
  (expr-var \"unit\"))
(module main)
")

(define (compiler-typecheck-string-prefix-at?
  [text : (& text str)]
  [prefix : (& prefix str)]
  [start : i64]) : bool
  (let
    [text-len : i64 (string.string-length text)]
    [prefix-len : i64 (string.string-length prefix)]
    (if (< start 0)
      false
      (if (> (+ start prefix-len) text-len)
        false
        (let
          [index : i64 0]
          [ok : bool true]
          (while ok
            (if (< index prefix-len)
              (if (=
                (string.string-ref text (+ start index))
                (string.string-ref prefix index))
                (+= index 1)
                (set! ok false))
              (set! ok false)))
          (= index prefix-len))))))

(define (compiler-typecheck-string-find-from
  [text : (& text str)]
  [needle : (& needle str)]
  [start : i64]) : i64
  (let
    [text-len : i64 (string.string-length text)]
    [needle-len : i64 (string.string-length needle)]
    [index : i64 start]
    [found : i64 -1]
    [done : bool (= needle-len 0)]
    (if done
      (set! found start)
      unit)
    (while (not done)
      (if (<= (+ index needle-len) text-len)
        (if (compiler-typecheck-string-prefix-at? text needle index)
          (begin
            (set! found index)
            (set! done true))
          (+= index 1))
        (set! done true)))
    found))

(define (compiler-typecheck-macro-prelude-for-core-source) : String
  (match (load.compiler-load-embedded-stdlib-source "core_macros.tl")
    [(CompilerEmbeddedStdlibSomeSource source)
      ;; The `for` macro runs to the next top-level form, which starts a line,
      ;; or to the end of the source. The embedded copy carries no inline tests
      ;; (#8713), so nothing need follow it.
      (let
        [start-marker : String
          "(defmacro (for [bindings : ExprBindingClause ...]"]
        [start : i64
          (compiler-typecheck-string-find-from source start-marker 0)]
        [next-form : i64
          (compiler-typecheck-string-find-from source "\n(" (+ start 1))]
        [end : i64
          (if (< next-form 0)
            (string.string-length source)
            next-form)]
        (if (and (>= start 0) (> end start))
          (str_cat.str-cat
            "(module fixture.core_for)\n(import stdlib.comptime)\n"
            (string.substring source start (- end start)))
          (io.panic "typecheck: embedded scalar for macro source missing")))]
    [(CompilerEmbeddedStdlibNoSource)
      (io.panic "typecheck: embedded core macro source missing")]))

(define (compiler-typecheck-macro-prelude-for-source) : String
  (str_cat.str-cat
    (compiler-typecheck-macro-prelude-for-core-source)
    "(defstruct Bag (value i64))
(defstruct Iter (:lifetimes source) (value (& source i64)) (done bool))
(defenum IterNext (:lifetimes source) (Done) (Item (& source i64)))
(defstruct IterMut (:lifetimes source) (value (&mut source i64)) (done bool))
(defenum IterMutNext (:lifetimes source) (Done) (Item (&mut source i64)))
(defstruct IntoIter
  (:cleanup cleanup-into-iter)
  (value i64)
  (done bool))
(defenum IntoNext (Done) (Item i64))
(define (iterator [items : (& source Bag)]) : (Iter source)
  (Iter (& items.value) false))
(define (next [state : (&mut state (Iter source))]) : (IterNext source)
  (if state.done
    (IterNext.Done)
    (begin
      (set! state.done true)
      (IterNext.Item state.value))))
(define (iterator-mut [items : (&mut source Bag)]) : (IterMut source)
  (IterMut (&mut items.value) false))
(define (next-mut [state : (&mut state (IterMut source))]) : (IterMutNext
    source)
  (if state.done
    (IterMutNext.Done)
    (begin
      (set! state.done true)
      (IterMutNext.Item state.value))))
(define (into-iterator [items : Bag]) : IntoIter
  (IntoIter items.value false))
(define (into-next [state : (&mut state IntoIter)]) : IntoNext
  (if state.done
    (IntoNext.Done)
    (begin
      (set! state.done true)
      (IntoNext.Item state.value))))
(define (main) : i64
  (let
    [sum : i64 0]
    (begin
      (for
        [left : i64 (Bag 20)]
        [right (Bag 22)]
        (set! sum (+ sum (+ left right))))
      sum)))"))

;; A transformer-owned node can still form a DAG when the same freshly quoted
;; Expr is unquoted into two scopes. Hygiene must copy that shared node per
;; occurrence instead of committing the first scope's rename in place.
(define (compiler-typecheck-macro-hygiene-shared-produced-node-source) : String
  "(define tmp : i64 22)
(defmacro (shared-fresh-node) : i64
  (let [shared : Expr `tmp]
    `(+ (let [tmp : i64 20] ,shared)
        ,shared)))
(define (main) : i64 (shared-fresh-node))")

(define (compiler-typecheck-hygiene-name-is?
  [value : tc_core.MacroMaybeHygieneName]
  [expected : i64]) : bool
  (match value
    [(No) false]
    [(Some actual) (= actual expected)]))

(define (compiler-typecheck-hygiene-name-missing?
  [value : tc_core.MacroMaybeHygieneName]) : bool
  (match value
    [(No) true]
    [(Some _) false]))

(define (compiler-typecheck-macro-hygiene-env-extend
  [env : tc_core.MacroHygieneEnv]
  [index : i64]
  [limit : i64]) : tc_core.MacroHygieneEnv
  (if (>= index limit)
    env
    (compiler-typecheck-macro-hygiene-env-extend
      (tc_core.macro-hygiene-env-bind-raw env (+ 100 index) (+ 1000 index))
      (+ index 1)
      limit)))

(define (compiler-typecheck-macro-hygiene-env-snapshots-ok?) : bool
  (let
    [macro-state : tc_core.TcMacroState
      (tc_core.tc-job-state-macro-state (tc_core.tc-serial-job-state))]
    [pools : ast.AstNodePoolContext (ast.ast-node-pool-context-capture-active)]
    (tc_core.macro-hygiene-env-reset! macro-state)
    (let
      [empty : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-empty macro-state pools)]
      [parent : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-bind-raw empty 7 70)]
      [left : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-bind-raw parent 8 80)]
      [right : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-bind-raw parent 9 90)]
      [shadow-one : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-bind-raw parent 7 71)]
      [shadow-two : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-bind-raw shadow-one 7 72)]
      [pattern : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-bind-pattern-name-raw empty 10 100)]
      [pattern-with-bind : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-bind-raw pattern 10 101)]
      [pattern-shadow : tc_core.MacroHygieneEnv
        (tc_core.macro-hygiene-env-bind-pattern-name-raw
          pattern-with-bind
          10
          102)]
      ;; Force two capacity growths while retaining earlier sibling heads.
      [deep : tc_core.MacroHygieneEnv
        (compiler-typecheck-macro-hygiene-env-extend parent 0 80)]
      (and
        (compiler-typecheck-hygiene-name-missing?
          (tc_core.macro-hygiene-env-lookup empty 7))
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup parent 7)
          70)
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup left 8)
          80)
        (compiler-typecheck-hygiene-name-missing?
          (tc_core.macro-hygiene-env-lookup left 9))
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup right 9)
          90)
        (compiler-typecheck-hygiene-name-missing?
          (tc_core.macro-hygiene-env-lookup right 8))
        (compiler-typecheck-hygiene-name-missing?
          (tc_core.macro-hygiene-env-lookup parent 8))
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup shadow-two 7)
          72)
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup pattern-with-bind 10)
          101)
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup-pattern-name pattern-with-bind 10)
          100)
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup-pattern-name pattern-shadow 10)
          102)
        (compiler-typecheck-hygiene-name-missing?
          (tc_core.macro-hygiene-env-lookup-pattern-name left 8))
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup parent 7)
          70)
        (compiler-typecheck-hygiene-name-is?
          (tc_core.macro-hygiene-env-lookup deep 179)
          1079)))))

(define (compiler-typecheck-macro-ownership-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defmacro (when [condition : i64] [body : unit]) : unit body)
(define (main) : unit (when 1 unit))")
    (compiler-typecheck-ok?
      "(defmacro (unless [condition : i64] [body : unit]) : unit body)
(define (main) : unit (unless 1 unit))")
    (compiler-typecheck-ok?
      "(defmacro (cond [arm : ExprClause]) : i64
  (expr-clause-second arm))
(define (main) : i64 (cond [true 42]))")
    (compiler-typecheck-ok?
      "(defmacro (and [args : bool ...]) : bool
  `(and-from (__and-args ,@args) 0))
(defmacro (and-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool true)
            `(if ,(expr-list-nth elems i)
               (and-from ,carrier ,(expr-int (+ i 1)))
               false))]
        [_ (expr-bool true)])]
    [_ (expr-bool true)]))
(define (main [x : bool] [y : bool] [z : bool]) : i64
  (if (and)
    (if (and x)
      (if (and x y z) 42 0)
      0)
    0))")
    (compiler-typecheck-ok?
      "(defmacro (or [args : bool ...]) : bool
  `(or-from (__or-args ,@args) 0))
(defmacro (or-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool false)
            `(if ,(expr-list-nth elems i)
               true
               (or-from ,carrier ,(expr-int (+ i 1)))))]
        [_ (expr-bool false)])]
    [_ (expr-bool false)]))
(define (main [x : bool] [y : bool] [z : bool]) : i64
  (if (or)
    0
    (if (or x)
      42
      (if (or x y z) 42 0))))")
    (compiler-typecheck-ok?
      (str_cat.str-cat
        (compiler-typecheck-macro-prelude-module-source)
        "(define (main) : i64 (and 1 41))
(defmacro (and [lhs : i64] [rhs : i64]) : i64
  `(+ ,lhs ,rhs))"))
    (compiler-typecheck-ok?
      (str_cat.str-cat
        (compiler-typecheck-macro-prelude-module-source)
        "(define (main [x : bool] [y : bool]) : i64
  (if (and x y)
    42
    (if (or x y) 7 0)))"))
    (compiler-typecheck-ok? (compiler-typecheck-macro-prelude-for-source))
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-macro-prelude-for-source)
        "
(define (bad-for-annotation) : unit
  (for [item : bool (Bag 1)] unit))")
      "typecheck: pattern binding type mismatch: expected bool, found i64")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-macro-prelude-for-core-source)
        "(define (main) : unit (for unit))")
      "typecheck: for expects at least one leading binding clause [name source] or [name : Type source]")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-macro-prelude-for-core-source)
        "(defstruct NotIterable (value i64))
(define (main) : unit (for [item (NotIterable 1)]))")
      "typecheck: for expects at least one body expression after its binding clauses")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-macro-prelude-module-source)
        "(define (main [a : bool]) : bool (and a 1))")
      "typecheck: macro operand type mismatch: expected bool, got i32")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-macro-prelude-module-source)
        "(define (main [a : bool]) : bool (or 1 a))")
      "typecheck: macro operand type mismatch: expected bool, got i32")
    (compiler-typecheck-ok?
      "(define (main) : unit
  (begin
    (when true unit)
    (when true unit unit)
    (unless false unit)
    (unless false unit unit)))")
    (compiler-typecheck-comptime-type-operand-tests-ok?)))

;; A typed macro operand is checked before specialization rewrites its
;; `[comptime T : type]` calls, so the check binds `T` from each `(type X)`.
(define (compiler-typecheck-comptime-type-operand-source [main-body : String]) : String
  (str_cat.str-cat
    "(defmacro (ident [x : i64]) : i64 x)
(defmacro (truthy [x : bool]) : bool x)
(define (pick [comptime T : type] [x : T]) : T x)
(define (first [comptime T : type] [xs : (& (Slice T))]) : T
  (array-ref xs 0))
(define (pair [comptime A : type] [comptime B : type] [a : A] [b : B]) : B b)
(define (main) : i64
"
    main-body
    ")"))

(define (compiler-typecheck-comptime-type-operand-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-comptime-type-operand-source
        "(ident (pick (type i64) 42))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-comptime-type-operand-source
        "(ident (ident (pair (type bool) (type i64) true 42)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-comptime-type-operand-source
        "(let [items : (Array i64 3) (array 1 2 3)]
    (if (truthy (= (first (type i64) (slice-view items 0 3)) 1)) 42 0))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-comptime-type-operand-source
        "(ident (pick (type bool) true))")
      "typecheck: macro operand type mismatch: expected i64, got bool")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-comptime-type-operand-source
        "(ident (pick (type i64) true))")
      "typecheck: call `pick` argument 2 (parameter `x`) type mismatch: expected i64, found bool")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-comptime-type-operand-source
        "(let [items : (Array bool 1) (array true)]
    (ident (first (type i64) (slice-view items 0 1))))")
      "typecheck: call `first` argument 2 (parameter `xs`) type mismatch: expected (& (Slice i64)), found (& items (Slice bool))")))

(define (compiler-typecheck-macro-export-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(module bool)
(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(module main)
(import bool as b)
(define (main) : i64
  (if (b.and2 true true) 42 0))")
    (compiler-typecheck-ok?
      "(module main)
(import bool as b)
(define (main) : i64
  (if (b.and-later true true) 42 0))
(module bool)
(defmacro (and-later [lhs : bool] [rhs : bool]) : bool
  `(if ,lhs ,rhs false))")
    (compiler-typecheck-ok?
      "(define eager : bool (late true))
(defmacro (late [value : bool]) : bool value)
(define (main) : i64 (if eager 42 0))")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (if (outer true) 42 0))
(defmacro (outer [value : bool]) : bool
  `(inner ,value))
(defmacro (inner [value : bool]) : bool value)")
    (compiler-typecheck-ok?
      "(import stdlib.comptime)
(define (main) : i64 (outer 42))
(defmacro (outer [value : i64]) : i64
  (comptime.expr-call
    (comptime.expr-var \"inner\")
    (comptime.expr-list-cons value (comptime.expr-list-empty))))
(defmacro (inner [value : i64]) : i64 value)")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (macro-a))
(defmacro (macro-a) : Expr `(macro-b))
(defmacro (macro-b) : Expr `(macro-a))"
      "macro expansion exceeded depth limit")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)))
(import (gen))
(define (main) : i64 (answer))")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)))
(import (gen) as generated)
(define (main) : i64 (generated.answer))")
    (compiler-typecheck-ok?
      "(module local.helper
  (import stdlib.string)
  (defstruct Pair (value i64))
  (defenum Choice (Choice i64))
  (defmacro (twice [value : i64]) : i64 `(+ ,value ,value))
  (define value : i64 (twice 21))
  (define (pair-value [p : Pair]) : i64 p.value))
(import local.helper as helper)
(define value : i64 5)
(define (main) : i64
  (+ helper.value (+ value (helper.pair-value (helper.Pair 3)))))")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Module
  `(module generated.module
    (define (answer) : i64 42)))
(import (gen) as generated)
(define (main) : i64 (generated.answer))")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)))
(import (gen))
(import (gen))
(define (main) : i64 (answer))")
    ;; Two generated module identities sharing the `generated.module` target and
    ;; declaring incompatible `answer` payloads are rejected during materialize.
    (compiler-typecheck-error-ok?
      "(defmacro (gen-a) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 42)))
(defmacro (gen-b) : Module
  `(begin
    (module generated.module)
    (define (answer) : i64 99)))
(import (gen-a))
(import (gen-b))
(define (main) : i64 (answer))"
      "typecheck: Module macro output for generated identity :gen-b() has incompatible payload")
    ;; The same identity re-expanded through a syntax parameter dedupes instead:
    ;; hygienic locals rename identically, so the replay finds one payload.
    (compiler-typecheck-ok?
      (compiler-typecheck-module-macro-import-syntax-param-repeat-source))
    (compiler-typecheck-error-ok?
      "(defmacro (gen-a) : Module
  `(begin
    (module generated.a)
    (define (answer) : i64 42)))
(defmacro (gen-b) : Module
  `(begin
    (module generated.b)
    (define (answer) : i64 99)))
(import (gen-a))
(import (gen-b))
(define (main) : i64 (answer))"
      "typecheck: ambiguous unqualified import for value answer between modules generated.a and generated.b; use an explicit alias or qualified access")
    (compiler-typecheck-error-ok?
      "(defmacro (gen) : Module
  `(define (answer) : i64 42))
(import (gen))
(define (main) : i64 0)"
      "typecheck: Module macro output must include a module declaration")
    (compiler-typecheck-error-ok?
      "(defmacro (gen) : Module (expr-var \"unused\"))
(define (main) : i64 (gen))"
      "typecheck: Module macro can only be used in import position")
    (compiler-typecheck-error-ok?
      "(defmacro (gen) : Decls (expr-var \"unused\"))
(import (gen))
(define (main) : i64 0)"
      "typecheck: Decls macro cannot be used in import position")
    (compiler-typecheck-error-ok?
      "(defmacro (gen) : Decls (expr-var \"unused\"))
(define (main) : i64 (gen))"
      "typecheck: Decls macro can only be used at module scope")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Decls
  `(define (answer) : i64 42))
(gen)
(define (main) : i64 (answer))")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Decls
  `(begin
    (define (left) : i64 20)
    (define (right) : i64 22)))
(gen)
(define (main) : i64 (+ (left) (right)))")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Decls
  `(define (generated-read [p : (Ptr i64)]) : i64
     (unsafe (ptr-read p))))
(gen)
(define (main) : i64 0)")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Decls
  `(unsafe (define (danger [x : i64]) : i64 x)))
(gen)
(define (main) : i64 (unsafe (danger 42)))")
    (compiler-typecheck-ok?
      "(unsafe (define (read-helper [p : (Ptr i64)]) : i64
  (unsafe (ptr-read p))))
(defmacro (gen) : Decls
  `(define (generated-read [p : (Ptr i64)]) : i64
     (unsafe (read-helper p))))
(gen)
(define (main) : i64 0)")
    (compiler-typecheck-ok?
      "(defmacro (gen) : Decls
  `(define (generated-copy [text : String] [items : (__tl_dyn-array u8)]) : String
     (unsafe
       (let
         [text-ptr : (Ptr u8) (string-data text)]
         [text-len : i64 (__tl_string_length text)]
         [copied : String (string-from-bytes text-ptr text-len)]
         [items-ptr : (MutPtr u8) (__tl_array-data items)]
         [items-ro : (Ptr u8) (ptr-cast items-ptr : (Ptr u8))]
         [addr : u64 (ptr->int items-ro)]
         [roundtrip : (Ptr u8) (int->ptr addr : (Ptr u8))]
         [first : u8 (ptr-read (ptr-offset roundtrip 0))]
         [grown : (__tl_dyn-array u8) (__tl_make-array u8 0)]
         (begin
           (__tl_array-push! grown first)
           (ptr-write! (ptr-offset items-ptr 0) first)
           copied)))))
(gen)
(define (main) : i64 0)")
    (compiler-typecheck-error-ok?
      "(defmacro (gen) : Decls
  `(define (generated-read [p : (Ptr i64)]) : i64 (ptr-read p)))
(gen)
(define (main) : i64 0)"
      "typecheck: ptr-read requires unsafe context")
    (compiler-typecheck-ok?
      "(module generated)
(define (answer) : i64 42)
(module main)
(defmacro (gen) : Decls
  `(import generated))
(gen)
(define (main) : i64 (generated.answer))")
    (compiler-typecheck-error-ok?
      "(defmacro (gen) : Decls
  `(define (answer) : i64 42))
(define (answer) : i64 1)
(gen)
(define (main) : i64 (answer))"
      "symbols: duplicate value declaration answer")
    (compiler-typecheck-error-ok?
      "(defmacro (gen) : Expr (expr-var \"unused\"))
(gen)
(define (main) : i64 0)"
      "typecheck: expression macro cannot be used at module scope")
    (compiler-typecheck-ok?
      "(define (runtime-touch [text : String]) : unit
  (if true
    (unsafe
      (let [ptr : (Ptr u8) (string-data text)] unit))
    unit))
(module stdlib.core_macros)
(defmacro (and [args : bool ...]) : bool
  `(and-from (__and-args ,@args) 0))
(defmacro (and-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool true)
            `(if ,(expr-list-nth elems i)
               (and-from ,carrier ,(expr-int (+ i 1)))
               false))]
        [_ (expr-bool true)])]
    [_ (expr-bool true)]))
(defmacro (or [args : bool ...]) : bool
  `(or-from (__or-args ,@args) 0))
(defmacro (or-from [carrier : Expr] [idx : Expr]) : bool
  (match idx
    [(Expr.Int i)
      (match carrier
        [(Expr.Call _ elems)
          (if (>= i (expr-list-length elems))
            (expr-bool false)
            `(if ,(expr-list-nth elems i)
               true
               (or-from ,carrier ,(expr-int (+ i 1)))))]
        [_ (expr-bool false)])]
    [_ (expr-bool false)]))
(defmacro (when [condition : bool] [body : unit]) : unit
  `(if ,condition ,body unit))
(defmacro (unless [condition : bool] [body : unit]) : unit
  `(if ,condition unit ,body))
(module main)
(define (main) : i64
      (let [value : i64 0]
    (begin
      (when true (set! value 21))
      (unless false (set! value (+ value 21)))
      (if (and (= value 42) (or false true)) value 0))))")))

;; Returns true when a macro call expands and the result typechecks, and when
;; arity plus operand-type errors are rejected during expansion at the call site.
(define (compiler-typecheck-macro-expand-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-macro-expand-source))
    (compiler-typecheck-error-ok?
      "(defmacro (and2 [lhs : bool] [rhs : bool]) : bool
  (expr-if lhs rhs (expr-bool false)))
(define (main) : i64 (if (and2 true) 1 0))"
      "macro call has too few arguments")
    (compiler-typecheck-error-ok?
      "(defmacro (ignore-bool [value : bool]) : bool
  (expr-bool true))
(define (main) : i64 (if (ignore-bool 1) 1 0))"
      "typecheck: macro operand type mismatch: expected bool, got i32")
    (compiler-typecheck-error-ok?
      "(defmacro (first [head : bool] [rest : bool ...]) : bool head)
(define (main) : i64 (if (first true 1) 1 0))"
      "typecheck: macro operand type mismatch: expected bool, got i32")
    (compiler-typecheck-ok?
      "(defmacro (choose [condition : bool] [then-expr : Expr] [else-expr : Expr]) : Expr
  `(if ,condition ,then-expr ,else-expr))
(define (int-value [x : i64]) : i64
  (choose true (+ x 1) 0))
(define (bool-value [x : bool]) : bool
  (choose x true false))
(define (main) : i64 (int-value 10))")
    (compiler-typecheck-ok?
      "(defmacro (choose [condition : bool] [then-expr : Expr] [else-expr : Expr]) : Expr
  `(if ,condition ,then-expr ,else-expr))
(defenum Expr
  (EUserExpr i64))
(define (main) : i64
  (choose true 42 0))")
    (compiler-typecheck-error-ok?
      "(defmacro (choose [condition : bool] [then-expr : Expr] [else-expr : Expr]) : Expr
  `(if ,condition ,then-expr ,else-expr))
(define (main) : i64 (choose true 1 false))"
      "typecheck: if branches must match")
    (compiler-typecheck-ok?
      "(defmacro (second [args : Expr ...]) : Expr
  (if (< (expr-list-length args) 2)
    (expr-var \"missing\")
    (expr-list-nth args 1)))
(define (main) : bool (second 42 true))")
    (compiler-typecheck-ok?
      "(defmacro (binding-init [binding : ExprBindingClause]) : Expr
  (if (__tl_string_eq (expr-binding-clause-name binding) \"answer\")
    (if (expr-binding-clause-has-type? binding)
      (expr-binding-clause-init binding)
      (expr-binding-clause-init binding))
    (expr-int 0)))
(define (typed) : i64 (binding-init [answer : i64 40]))
(define (inferred) : i64 (binding-init [answer 2]))
(define (main) : i64 (+ (typed) (inferred)))")
    (compiler-typecheck-ok?
      "(defmacro (sum-bindings [bindings : ExprBindingClause ...]) : i64
  (if (= (expr-binding-clause-list-length bindings) 0)
    (expr-int 0)
    (if (= (expr-binding-clause-list-length bindings) 2)
      (let
        [first : ExprBindingClause (expr-binding-clause-list-nth bindings 0)]
        [second : ExprBindingClause (expr-binding-clause-list-nth bindings 1)]
        (if (__tl_string_eq (expr-binding-clause-name first) \"a\")
          (if (__tl_string_eq (expr-binding-clause-name second) \"b\")
            (if (expr-binding-clause-has-type? first)
              (if (expr-binding-clause-has-type? second)
                (expr-int 0)
                `(+ ,(expr-binding-clause-init first) ,(expr-binding-clause-init second)))
              (expr-int 0))
            (expr-int 0))
          (expr-int 0)))
      (expr-int 0))))
(defmacro (forward-bindings [bindings : ExprBindingClause ...]) : i64
  `(sum-bindings ,@(expr-binding-clause-list->expr-list bindings)))
(define (main) : i64 (forward-bindings [a : i64 20] [b 22]))")
    (compiler-typecheck-ok?
      "(defmacro (binding-do
  [bindings : ExprBindingClause ...]
  [body : Expr ...]) : i64
  (if (= (expr-list-length body) 0)
    (expr-int 0)
    (if (= (expr-binding-clause-list-length bindings) 0)
      (expr-list-nth body 0)
      (if (= (expr-binding-clause-list-length bindings) 1)
        (let
          [first : ExprBindingClause
            (expr-binding-clause-list-nth bindings 0)]
          (if (__tl_string_eq (expr-binding-clause-name first) \"item\")
            (if (expr-binding-clause-has-type? first)
              (expr-int 0)
              `(+ ,(expr-binding-clause-init first) ,(expr-list-nth body 0)))
            (expr-int 0)))
        (if (= (expr-binding-clause-list-length bindings) 2)
          (let
            [first : ExprBindingClause
              (expr-binding-clause-list-nth bindings 0)]
            [second : ExprBindingClause
              (expr-binding-clause-list-nth bindings 1)]
            (if (__tl_string_eq (expr-binding-clause-name first) \"item\")
              (if (__tl_string_eq (expr-binding-clause-name second) \"other\")
                (if (expr-binding-clause-has-type? first)
                  (if (expr-binding-clause-has-type? second)
                    (expr-int 0)
                    `(+ ,(expr-binding-clause-init first)
                      (+ ,(expr-binding-clause-init second)
                        ,(expr-list-nth body 0))))
                  (expr-int 0))
                (expr-int 0))
              (expr-int 0)))
          (expr-int 0))))))
(defmacro (nested-binding-do [body : Expr]) : i64
  `(binding-do [item 0] ,body))
(defmacro (binding-units
  [bindings : ExprBindingClause ...]
  [body : unit ...]) : unit
  (if (= (expr-list-length body) 0)
    `unit
    (expr-list-nth body (- (expr-list-length body) 1))))
(define (empty-prefix) : i64
  (binding-do 20 22))
(define (one-binding) : i64
  (binding-do [item 1] 41))
(define (many-bindings) : i64
  (binding-do
    [item : i64 1]
    [other 2]
    39))
(define (typed-body-rest) : unit
  (binding-units [item 0] unit unit))
(define (nested-hygiene) : i64
  (let [tmp : i64 42]
    (nested-binding-do tmp)))
(define (main) : i64
  (begin
    (typed-body-rest)
    (+
      (empty-prefix)
      (+
        (one-binding)
        (+
          (many-bindings)
          (nested-hygiene))))))")
    (compiler-typecheck-error-ok?
      "(defmacro (binding-do
  [bindings : ExprBindingClause ...]
  [body : Expr ...]) : Expr
  (expr-list-nth body 0))
(define (main) : i64
  (binding-do [item : i64] 42))"
      "typecheck: ExprBindingClause macro operand expects bracket clause [name expr] or [name : Type expr]")
    (compiler-typecheck-error-ok?
      "(defmacro (binding-one
  [bindings : ExprBindingClause ...]
  [body : i64]) : i64
  body)
(define (main) : i64
  (binding-one [item 42]))"
      "macro call has too few arguments")
    (compiler-typecheck-error-ok?
      "(defmacro (binding-one
  [bindings : ExprBindingClause ...]
  [body : i64]) : i64
  body)
(define (main) : i64
  (binding-one [item 42] true))"
      "typecheck: macro operand type mismatch: expected i64, got bool")
    (compiler-typecheck-ok?
      "(defmacro (binding-box
  [bindings : ExprBindingClause ...]
  [T : type]) : Module
  `(begin
    (module generated.binding_box)
    (define (id [value : ,T]) : ,T value)))
(import (binding-box [item 0] i64) as box)
(define (main) : i64
  (box.id 42))")
    (compiler-typecheck-error-ok?
      "(defmacro (take-binding [binding : ExprBindingClause]) : i64 (expr-int 0))
(define (main) : i64 (take-binding 1))"
      "typecheck: ExprBindingClause macro operand expects bracket syntax")
    (compiler-typecheck-error-ok?
      "(defmacro (take-binding [binding : ExprBindingClause]) : i64 (expr-int 0))
(define (main) : i64 (take-binding [x]))"
      "typecheck: ExprBindingClause macro operand expects bracket clause [name expr] or [name : Type expr]")
    (compiler-typecheck-error-ok?
      "(defmacro (take-binding [binding : ExprBindingClause]) : i64 (expr-int 0))
(define (main) : i64 (take-binding [x : i64]))"
      "typecheck: ExprBindingClause macro operand expects bracket clause [name expr] or [name : Type expr]")
    (compiler-typecheck-error-ok?
      "(defmacro (take-binding [binding : ExprBindingClause]) : i64 (expr-int 0))
(define (main) : i64 (take-binding [x : i64 1 2]))"
      "typecheck: ExprBindingClause macro operand expects bracket clause [name expr] or [name : Type expr]")
    (compiler-typecheck-error-ok?
      "(defmacro (binding-type [binding : ExprBindingClause]) : Expr
  (if (expr-binding-clause-has-type? binding)
    (expr-binding-clause-type binding)
    (expr-int 0)))
(define (main) : i64 (binding-type [x : i64 1]))"
      "typecheck: unbound name i64")
    (compiler-typecheck-error-ok?
      "(defmacro (take-clause [arm : ExprClause]) : i64 (expr-clause-second arm))
(define (main) : i64 (take-clause [x : i64 1]))"
      "typecheck: ExprClause macro operand expects bracket clause [expr expr ...]")
    (compiler-typecheck-ok?
      "(defstruct Point (x i64))
(defmacro (kind-code [value : Expr]) : i64
  (let [T : Expr (expr-type value)]
    (if (__tl_string_eq (type-kind T) \"i64\")
      (expr-int 1)
      (if (__tl_string_eq (type-kind T) \"bool\")
        (expr-int 2)
        (if (__tl_string_eq (type-kind T) \"struct\")
          (if (__tl_string_eq (type-nominal-name T) \"Point\")
            (expr-int 3)
            (expr-int 0))
          (if (__tl_string_eq (type-kind T) \"array\")
            (if (__tl_string_eq (type-kind (array-element-type T)) \"i64\")
              (expr-int 4)
              (expr-int 0))
            (if (__tl_string_eq (type-kind T) \"function\")
              (if (__tl_string_eq (type-kind (function-return-type T)) \"i64\")
                (expr-int 5)
                (expr-int 0))
              (expr-int 0))))))))
(define (main [flag : bool] [items : (Array i64 4)] [f : (-> i64 i64)]) : i64
  (+ (kind-code (ann 1 : i64))
     (+ (kind-code flag)
        (+ (kind-code (Point 1))
           (+ (kind-code items)
              (kind-code f))))))")
    (compiler-typecheck-ok?
      "(defmacro (kind-code [value : Expr]) : i64
  (if (__tl_string_eq (type-kind (comptime.expr-type value)) \"i64\")
    (expr-int 1)
    (expr-int 0)))
(define (main) : i64 (kind-code 42))")
    (compiler-typecheck-error-ok?
      "(defmacro (needs-type [value : Expr]) : i64
  (if (__tl_string_eq (type-kind (expr-type value)) \"i64\")
    (expr-int 1)
    (expr-int 0)))
(define (main) : i64 (needs-type missing))"
      "expr-type requires a typechecked Expr")
    (compiler-typecheck-ok?
      "(defenum MaybeI64 (Some i64) (None))
(defmacro (make-some [value : i64]) : MaybeI64 `(Some ,value))
(defmacro (identity-expr [value : Expr]) : Expr value)
(define (main) : i64
  (+
    (match (make-some 20)
      [(Some value) value]
      [(None) 0])
    (match (make-some 22)
      [(Some value) (identity-expr value)]
      [(None) 0])))")
    (compiler-typecheck-error-ok?
      "(defmacro (again) : Expr `(again))
(define (main) : i64 (again))"
      "macro expansion exceeded depth limit")
    (compiler-typecheck-macro-export-tests-ok?)
    (compiler-typecheck-ok?
      "(defmacro (with-temp-bool [body : bool]) : bool
  `(let [tmp : i64 1]
     ,body))
(define (main) : bool
  (let [tmp : bool true]
    (with-temp-bool tmp)))")
    (compiler-typecheck-ok?
      "(define (main) : bool
  (let [tmp : bool true]
    (with-late-temp tmp)))
(defmacro (with-late-temp [body : bool]) : bool
  `(let [tmp : i64 1]
     ,body))")
    (compiler-typecheck-ok?
      "(define (macro-helper [x : bool]) : bool (not x))
(defmacro (unless2 [condition : bool] [body : unit]) : unit
  `(if (macro-helper ,condition)
     ,body
     unit))
(define (main) : unit
  (let [macro-helper : bool true]
    (unless2 false unit)))")
    (compiler-typecheck-ok?
      "(module macros)
(define (macro-helper [x : bool]) : bool (not x))
(defmacro (choose-helper [condition : bool] [body : Expr]) : Expr
  `(if (macro-helper ,condition)
     ,body
     0))
(module main)
(import macros as m)
(define (macro-helper [x : bool]) : i64 7)
(define (main) : i64
  (m.choose-helper false (macro-helper true)))")
    (compiler-typecheck-ok?
      "(module pkg.macros)
(define (macro-helper [x : bool]) : bool (not x))
(defmacro (choose-helper [condition : bool] [body : Expr]) : Expr
  `(if (macro-helper ,condition)
     ,body
     0))
(module main)
(import pkg.macros)
(define (macro-helper [x : bool]) : i64 7)
(define (main) : i64
  (macros.choose-helper false (macro-helper true)))")
    (compiler-typecheck-ok?
      "(module pkg.data)
(define (get) : i64 41)
(module main)
(import pkg.data)
(defmacro (call-get) : i64 `(data.get))
(define (main) : i64 (+ (call-get) 1))")
    (compiler-typecheck-ok?
      "(module pkg.data)
(define (get) : i64 41)
(module main)
(import pkg.data)
(defmacro (call-get) : i64 `(pkg.data.get))
(define (main) : i64 (+ (call-get) 1))")
    (compiler-typecheck-ok?
      "(module pkg.macros)
(define (helper) : i64 41)
(defmacro (call-helper) : i64 `(pkg.macros.helper))
(module main)
(import pkg.macros)
(define (main) : i64 (+ (macros.call-helper) 1))")
    (compiler-typecheck-ok?
      "(module pkg.macros)
(defmacro (helper [x : i64]) : i64 `(+ ,x 1))
(defmacro (call-helper [x : i64]) : i64 `(pkg.macros.helper ,x))
(module main)
(import pkg.macros)
(define (main) : i64 (macros.call-helper 41))")
    (compiler-typecheck-ok?
      "(module pkg.data)
(define (get) : i64 41)
(module pkg.macros)
(import pkg.data)
(defmacro (call-data) : i64 `(data.get))
(module main)
(import pkg.data)
(import pkg.macros)
(define (main) : i64 (+ (macros.call-data) 1))")
    (compiler-typecheck-ok?
      "(module macros)
(defmacro (dyn-len [items : Expr]) : i64
  `(array-length ,items))
(module main)
(import macros as m)
(define (main [items : (__tl_dyn-array i64)]) : i64
  (m.dyn-len items))")
    (compiler-typecheck-ok?
      "(defmacro (with-temp-bool [body : bool]) : bool
  `(let [tmp : i64 1]
     ,body))
(defmacro (wrap-temp [body : bool]) : bool
  `(with-temp-bool ,body))
(define (main) : bool
  (let [tmp : bool true]
    (wrap-temp tmp)))")
    (compiler-typecheck-ok?
      "(module m)
(defmacro (id-expr [body : Expr]) : i64 body)
(defmacro (with-temp [value : i64]) : i64
  `(let [tmp : i64 ,value]
     (id-expr tmp)))
(module main)
(import m)
(define (main) : i64 (m.with-temp 42))")
    (compiler-typecheck-ok?
      "(defmacro (with-temp-do [steps : unit ...]) : unit
  `(let [tmp : i64 1]
     (begin ,@steps)))
(define (main) : unit
  (let [tmp : unit unit]
    (with-temp-do tmp)))")
    (compiler-typecheck-ok?
      (compiler-typecheck-macro-hygiene-shared-produced-node-source))
    (compiler-typecheck-ok?
      "(defenum HygieneSnapshotChoice
  (Left i64)
  (Right i64))
(defmacro (nested-snapshot [value : i64]) : i64
  `(let [shadow : i64 ,value]
     ((lambda ([shadow : i64]) : i64
        (match (HygieneSnapshotChoice.Left shadow)
          [(HygieneSnapshotChoice.Left shadow) shadow]
          [(HygieneSnapshotChoice.Right shadow) shadow]))
      shadow)))
(define (main) : i64
  (let [shadow : bool true]
    (if shadow (nested-snapshot 42) 0)))")
    (compiler-typecheck-ok?
      "(defmacro (emit-ref-box) : Decls
  `(defstruct GeneratedRefBox
     (:lifetimes owner)
     (value (& owner i64))))
(emit-ref-box)
(define (observe [box : (GeneratedRefBox owner)]) : i64 1)
(define (main) : i64 0)")
    (compiler-typecheck-error-ok?
      "(unsafe (define (danger [x : i64]) : i64 x))
(defmacro (call-danger [x : i64]) : i64
  `(danger ,x))
(define (main) : i64 (call-danger 1))"
      "typecheck: danger requires unsafe context")
    (compiler-typecheck-macro-ownership-tests-ok?)))

(define (compiler-typecheck-body-fact-tests-ok?) : bool
  (compiler-typecheck-ok?
    "(define (take-i8 [x : i8]) : i64 (cast x : i64))
(define (take-array [items : (Array i8 2)]) : i64
  (cast (array-ref items 0) : i64))
(define (take-tuple [items : (Tuple i8 i8)]) : i64
  (cast (tuple-ref items 1) : i64))
(define (main) : i64
  (+ (take-i8 1)
    (+ (take-array (array 2 3))
      (take-tuple (tuple 4 5)))))"))

(define (compiler-typecheck-self-test-basics) : unit
  (if (intern_tests.intern-id-space-capacity-tests-ok?)
    unit
    (io.panic
      "typecheck: intern id space layout exceeds the intern capacity budget"))
  (if (intern_tests.intern-syntax-id-tests-ok?)
    unit
    (io.panic "typecheck: typed syntax identity boundary tests failed"))
  (if (intern_tests.intern-qualified-metadata-tests-ok?)
    unit
    (io.panic "typecheck: intern qualified metadata tests failed"))
  (cbi.compiler-builtin-initialize-for-parse!)
  (if (core_tests.tc-type-env-segmented-snapshot-smoke?)
    unit
    (io.panic "typecheck: segmented type env snapshot smoke mismatch"))
  (if (core_tests.tc-type-env-local-cache-smoke?)
    unit
    (io.panic "typecheck: local type env cache smoke mismatch"))
  (if (core_tests.tc-spmd-env-box-smoke?)
    unit
    (io.panic "typecheck: boxed spmd env smoke mismatch"))
  (if (compiler-typecheck-macro-hygiene-env-snapshots-ok?)
    unit
    (io.panic "typecheck: macro hygiene environment snapshot mismatch"))
  (if (compiler-typecheck-ptr-null-tests-ok?)
    unit
    (io.panic "typecheck: ptr-null construction/check tests failed"))
  (if (compiler-typecheck-unsafe-tests-ok?)
    unit
    (io.panic "typecheck: unsafe block tests failed"))
  (if (compiler-typecheck-unsafe-decl-tests-ok?)
    unit
    (io.panic "typecheck: unsafe declaration tests failed"))
  (if (compiler-typecheck-tls-current-arena-tests-ok?)
    unit
    (io.panic "typecheck: tls current arena tests failed"))
  (if (compiler-typecheck-float-sqrt-tests-ok?)
    unit
    (io.panic "typecheck: float sqrt intrinsic tests failed"))
  (if (compiler-typecheck-float-bitcast-tests-ok?)
    unit
    (io.panic "typecheck: float bitcast intrinsic tests failed"))
  (if (compiler-typecheck-arena-unsafe-tests-ok?)
    unit
    (io.panic "typecheck: arena unsafe primitive tests failed"))
  (if (compiler-typecheck-raw-pointer-op-tests-ok?)
    unit
    (io.panic "typecheck: raw pointer unsafe operation tests failed"))
  (if (compiler-typecheck-statement-tests-ok?)
    unit
    (io.panic "typecheck: statement/control-flow tests failed"))
  (if (compiler-typecheck-operator-tests-ok?)
    unit
    (io.panic "typecheck: operator/arity tests failed"))
  (if (compiler-typecheck-scalar-parity-tests-ok?)
    unit
    (io.panic "typecheck: scalar bool/float/cast parity tests failed"))
  (if (compiler-typecheck-body-fact-tests-ok?)
    unit
    (io.panic "typecheck: body-local type fact tests failed"))
  (if (compiler-typecheck-match-tests-ok?)
    unit
    (io.panic "typecheck: match/pattern tests failed"))
  (if (compiler-typecheck-multiform-arm-tests-ok?)
    unit
    (io.panic "typecheck: multi-form match/cond arm tests failed"))
  (if (compiler-typecheck-bare-variant-tests-ok?)
    unit
    (io.panic "typecheck: bare variant resolution tests failed"))
  (if (compiler-typecheck-spmd-reduce-op-tests-ok?)
    unit
    (io.panic "typecheck: spmd-reduce operator/type tests failed"))
  (if (compiler-typecheck-spmd-reduce-purity-tests-ok?)
    unit
    (io.panic "typecheck: spmd-reduce purity tests failed"))
  (if (compiler-typecheck-spmd-broadcast-tests-ok?)
    unit
    (io.panic "typecheck: spmd-broadcast tests failed"))
  (if (compiler-typecheck-array-builtin-tests-ok?)
    unit
    (io.panic "typecheck: array-builtin signature tests failed"))
  (match (tc_api.typecheck-compiler-source
    "(extern (print-i64 [arg0 : i64]) : unit)
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main [flag : bool]) : i64
  (let
    [x : i64 (inc answer)]
    (begin
      (set! x (+ x 1))
      (if flag x 0))))")
    [(Ok summary)
      (if (= (tc_api.compiler-typecheck-summary-score summary) 121)
        unit
        (io.panic "typecheck: smoke score mismatch"))]
    [(Err diag)
      (let
        [first : cdiag.CompilerDiagnostic
          (cdiag.compiler-diagnostic-list-first (deref diag))]
        (io.panic (cdiag.compiler-diagnostic-message first)))])
  unit)

;; --- move checker fixtures ----------------------------------------------------
;; `String` is move-only; binding it into a fresh local with `let` moves it, so a
;; later read of the source is a use-after-move. Copyable scalars are never moved.
(define (compiler-typecheck-move-use-after-move-source) : String
  "(define (use-after-move [s : String]) : String
  (let [t : String s] s))")

;; Formerly special-cased inspectors follow their reference parameter types.
;; The same borrowed signature behaves identically when called directly,
;; through a function value or lambda, and from a generated declaration. The
;; compiler-private intrinsic also exposes that signature to ownership passes.
(define (compiler-typecheck-move-type-driven-inspection-parity-source) : String
  "(define (inspect-text [text : (& text str)]) : i64 0)
(defmacro (emit-generated-inspector) : Decls
  `(begin
    (define (generated-inspect-text [text : (& text str)]) : i64 0)))
(emit-generated-inspector)
(define (inspect-direct [value : String]) : String
  (begin (inspect-text value) value))
(define (inspect-then-assign [value : String]) : String
  (begin (inspect-text value) (set! value \"after\") value))
(define (inspect-indirect [text : String]) : String
  (let [inspect : (-> (& text str) i64) inspect-text]
    (begin (inspect text) text)))
(define (inspect-lambda [value : String]) : String
  (begin
    ((lambda ([text : (& text str)]) : i64 0) value)
    value))
(define (inspect-generated [value : String]) : String
  (begin (generated-inspect-text value) value))
(define (inspect-compiler-builtin [value : String]) : String
  (begin (__tl_string_length value) value))
(define (inspect-compiler-eq [value : String] [other : String]) : String
  (begin (__tl_string_eq value other) (set! value \"after\") value))")

;; Structural Copy fixtures exercise ordinary by-value parameters directly.
(define (compiler-typecheck-move-structural-copy-source) : String
  "(defstruct ScalarPacket (value i64))
(defenum ScalarChoice (None) (Some i64))
(defstruct RefPair (:lifetimes a) (ref (& a i64)) (value i64))
(defstruct NestedRefPair (:lifetimes a) (pair (RefPair a)) (value i64))
(define (take-array [value : (Array i64 4)]) : unit unit)
(define (take-tuple [value : (Tuple i64 bool)]) : unit unit)
(define (take-struct [value : ScalarPacket]) : unit unit)
(define (take-enum [value : ScalarChoice]) : unit unit)
(define (take-ref-pair [owner : i64] [value : (RefPair owner)]) : unit unit)
(define (take-nested-ref-pair [owner : i64] [value : (NestedRefPair owner)]) : unit unit)
(define (copy-array-reuse [value : (Array i64 4)]) : unit
  (let [copy : (Array i64 4) value]
    (begin (take-array value) (take-array copy))))
(define (copy-tuple-reuse [value : (Tuple i64 bool)]) : unit
  (begin (take-tuple value) (take-tuple value)))
(define (copy-struct-reuse [value : ScalarPacket]) : unit
  (begin (take-struct value) (take-struct value)))
(define (copy-enum-reuse [value : ScalarChoice]) : unit
  (begin (take-enum value) (take-enum value)))
(define (copy-nested-ref-reuse [owner : i64] [value : (NestedRefPair owner)]) : unit
  (begin
    (take-nested-ref-pair owner value)
    (take-nested-ref-pair owner value)))
(define (copy-lifetime-ref-reuse [owner : i64] [value : (RefPair owner)]) : unit
  (begin (take-ref-pair owner value) (take-ref-pair owner value)))")

(define (compiler-typecheck-move-cleanup-enum-payload-prefix) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (close-code [code : i64]) : unit unit)
(defenum MaybeHandle
  (:cleanup cleanup-maybe-handle)
  (Some FileHandle (:owned))
  (Code i64 (:cleanup close-code))
  (None))
(define (take-handle [h : FileHandle]) : unit unit)
")

(define (compiler-typecheck-move-owner-projection-deep-mixed-repeat-source) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Leaf
  (:cleanup cleanup-leaf)
  (handle FileHandle (:owned))
  (tag i64))
(defstruct Holder
  (:cleanup cleanup-holder)
  (mixed (Tuple (Array (Tuple Leaf i64) 2) i64)))
(define (take-leaf [leaf : Leaf]) : unit unit)
(define (bad-owner-projection-deep-mixed-repeat [p : Holder]) : unit
  (begin
    (take-leaf
      (tuple-ref
        (array-ref
          (tuple-ref p.mixed 0)
          1)
        0))
    (take-leaf
      (tuple-ref
        (array-ref
          (tuple-ref p.mixed 0)
          1)
        0))))")

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
    (take-handle p.inner.handle)
    (take-handle p.inner.handle)))")

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
    (take-handle p.inner.handle)
    (take-inner p.inner)))")

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
    (take-inner p.inner)
    (take-handle p.inner.handle)))")

(define (compiler-typecheck-move-while-loop-carried-param-source) : String
  "(define (bad-while-loop-carried-param [flag : bool] [s : String]) : String
  (begin (while flag (let [t : String s] unit)) s))")

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
      (take-handle h.handle)
      0)))")

(define (compiler-typecheck-live-borrow-owner-prefix) : String
  "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (read-handle-ref [h : (& h FileHandle)]) : unit unit)
")

(define (compiler-typecheck-live-borrow-holder-prefix) : String
  (str_cat.str-cat
    (compiler-typecheck-live-borrow-owner-prefix)
    "(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (take-holder [h : Holder]) : unit unit)
(define (read-holder-ref [h : (& h Holder)]) : unit unit)
"))

(define (compiler-typecheck-live-borrow-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : i64
  (begin
    (let [r1 : (& n i64) (& n)]
      (let [r2 : (& n i64) (& n)] n))
    (set! n 7)
    n))")
    (compiler-typecheck-ok?
      (str_cat.str-cat
        (compiler-typecheck-live-borrow-owner-prefix)
        "(define (main [h : FileHandle]) : unit
  (begin
    (let [r : (& h FileHandle) (& h)] unit)
    (take-handle h)))"))
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [n : i64 1]
      (begin
        (set! n 2)
        n))))")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-live-borrow-owner-prefix)
        "(define (bad [h : FileHandle]) : unit
  (let [r : (& h FileHandle) (& h)]
    (begin
      (take-handle h)
      (read-handle-ref r))))")
      "typecheck: cannot move borrowed place `h`")
    (compiler-typecheck-error-ok?
      "(define (read-i64-ref [r : (& n i64)]) : i64 1)
(define (bad [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (begin
      (set! n 2)
      (read-i64-ref r))))"
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-live-borrow-holder-prefix)
        "(define (bad [p : Holder]) : unit
  (let [r : (& p FileHandle) (& p.handle)]
    (begin
      (take-holder p)
      (read-handle-ref r))))")
      "typecheck: cannot move borrowed place `p`")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-live-borrow-holder-prefix)
        "(define (bad [p : Holder]) : unit
  (let [r : (& p Holder) (& p)]
    (begin
      (take-handle p.handle)
      (read-holder-ref r))))")
      "typecheck: cannot move borrowed place `p.handle`")
    (compiler-typecheck-error-ok?
      "(define (read-i64-ref [r : (& n i64)]) : i64 1)
(define (bad [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (let [m : i64 1]
      (begin
        (set! n m)
        (read-i64-ref r)))))"
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-error-ok?
      "(define (read-i64-ref [r : (& n i64)]) : i64 1)
(define (bad [n : i64]) : i64
  (let [r : (& n i64) (& n)]
    (begin
      (set! n 2)
      (read-i64-ref r))))"
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-error-ok?
      "(define (read-i64-ref [r : (& n i64)]) : i64 1)
(defenum Flag (On) (Off))
(define (bad [flag : Flag] [n : i64]) : i64
  (match flag
    [On (let [r : (& n i64) (& n)] (begin (set! n 2) (read-i64-ref r)))]
    [Off n]))"
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-ok?
      "(define (main [n : i64]) : i64
  (begin
    (with-arena r
      (let [borrowed : (& n i64) (& n)] unit))
    (set! n 3)
    n))")
    (compiler-typecheck-error-ok?
      "(define (read-i64-ref [r : (& n i64)]) : i64 1)
(define (bad [n : i64]) : i64
  (with-arena r
    (let [borrowed : (& n i64) (& n)]
      (begin
        (set! n 3)
        (read-i64-ref borrowed)))))"
      "typecheck: cannot assign to borrowed place `n`")
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-live-borrow-holder-prefix)
        "(define (bad [fd : i64]) : i64
  (with ([h (Holder (FileHandle fd) 1) cleanup-holder])
    (let [borrowed : (& h Holder) (& h)]
      (begin
        (set! h.size 2)
        (read-holder-ref borrowed)
        0))))")
      "typecheck: cannot assign to borrowed place `h.size`")
    (compiler-typecheck-error-ok?
      "(define (read-i64-ref [r : (& items i64)]) : unit unit)
(define (bad [items : (__tl_dyn-array i64)]) : unit
  (let [borrowed : (& items i64) (& (array-ref items 0))]
    (begin
      (set! (array-ref items 0) 7)
      (read-i64-ref borrowed))))"
      "typecheck: cannot assign to borrowed place `items[0]`")
    (compiler-typecheck-error-ok?
      "(define (main [n : i64]) : i64
  (begin
    (let [r : (&mut n i64) (&mut n)] unit)
    (let [s : (&mut n i64) (&mut n)] unit)
    n))"
      "typecheck: mutable borrow of by-value place is only supported as an immediate call argument")
    (compiler-typecheck-ok?
      "(define (main [items : (__tl_dyn-array i64)]) : unit
  (begin
    (let [r : (&mut items i64) (&mut (array-ref items 0))] unit)
    (let [s : (&mut items i64) (&mut (array-ref items 0))] unit)))")
    (compiler-typecheck-error-ok?
      "(defstruct Pair (x i64) (y i64))
(define (bad) : unit
  (let
    [p : Pair (Pair 1 2)]
    (let [r : (&mut p Pair) (&mut p)] unit)))"
      "typecheck: mutable borrow of by-value place is only supported as an immediate call argument")
    (compiler-typecheck-ok?
      "(define (take [r : (&mut n i64)]) : unit unit)
(define (main [n : i64]) : unit
  (begin
    (take (&mut n))
    (set! n 3)))")
    (compiler-typecheck-error-ok?
      "(define (bad [items : (__tl_dyn-array i64)]) : unit
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    (let [s : (&mut items i64) (&mut (array-ref items 0))] unit)))"
      "typecheck: cannot read mutably borrowed place `items[0]`")
    (compiler-typecheck-error-ok?
      "(define (bad [items : (__tl_dyn-array i64)]) : unit
  (let [r : (& items i64) (& (array-ref items 0))]
    (let [s : (&mut items i64) (&mut (array-ref items 0))] unit)))"
      "typecheck: cannot mutably borrow borrowed place `items[0]`")
    (compiler-typecheck-error-ok?
      "(define (bad [items : (__tl_dyn-array i64)]) : unit
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    (let [s : (& items i64) (& (array-ref items 0))] unit)))"
      "typecheck: cannot read mutably borrowed place `items[0]`")
    (compiler-typecheck-error-ok?
      "(define (take2 [a : (&mut n i64)] [b : (&mut n i64)]) : unit unit)
(define (bad [n : i64]) : unit
  (take2 (&mut n) (&mut n)))"
      "typecheck: cannot mutably borrow borrowed place `n`")
    (compiler-typecheck-error-ok?
      "(define (bad [items : (__tl_dyn-array i64)]) : unit
  (let [r : (&mut items i64) (&mut (array-ref items 0))]
    (set! (array-ref items 0) 2)))"
      "typecheck: cannot assign to borrowed place `items[0]`")
    (compiler-typecheck-error-ok?
      "(define (bad [items : (__tl_dyn-array i64)]) : unit
  (let [borrowed : (&mut items i64) (&mut (array-ref items 0))]
    (set! (array-ref items 0) 7)))"
      "typecheck: cannot assign to borrowed place `items[0]`")))

(define (compiler-typecheck-param-storage-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      "(defstruct Big (a i64) (b i64) (c i64))
(define (bad [value : Big]) : unit
  (set! value.a 7))")
    (compiler-typecheck-ok?
      "(define (bad [items : (Array i64 3)]) : unit
  (set! (array-ref items 0) 7))")
    (compiler-typecheck-ok?
      "(define (bad [items : (Tuple (Array i64 1) i64)]) : unit
  (set! (array-ref (tuple-ref items 0) 0) 7))")
    (compiler-typecheck-ok?
      "(defstruct BigTuple
  (items (Tuple (Array i64 1) i64))
  (pad0 i64)
  (pad1 i64))
(define (bad [value : BigTuple]) : unit
  (set! (array-ref (tuple-ref value.items 0) 0) 7))")
    (compiler-typecheck-ok?
      "(defstruct Big (a i64) (b i64) (c i64))
(define (bad [value : Big]) : unit
  (let [alias : Big value]
    (set! alias.a 7)))")
    (compiler-typecheck-ok?
      "(defstruct Big (a i64) (b i64) (c i64))
(defenum Carrier (Some Big) (None))
(define (bad [value : Carrier]) : unit
  (match value
    [(Some payload) (set! payload.a 7)]
    [None unit]))")
    (compiler-typecheck-ok?
      "(defstruct Big (a i64) (b i64) (c i64))
(define (touch [value : (&mut value Big)]) : unit unit)
(define (bad [value : Big]) : unit
  (touch (&mut value)))")
    (compiler-typecheck-ok?
      "(defstruct Big (a i64) (b i64) (c i64))
(define (touch [value : (&mut value i64)]) : unit unit)
(define (bad [value : Big]) : unit
  (touch (&mut value.a)))")
    (compiler-typecheck-ok?
      "(defstruct Pair (a i64) (b i64))
(define (change [value : Pair]) : i64
  (begin
    (set! value.a 7)
    value.a))")
    (compiler-typecheck-ok?
      "(defstruct Big (a i64) (b i64) (c i64))
(define (reset [value : Big]) : i64
  (begin
    (set! value (Big 7 8 9))
    value.a))")
    (compiler-typecheck-ok?
      "(defstruct Big (a i64) (b i64) (c i64))
(define (change [value : (&mut value Big)]) : unit
  (set! value.a 7))
(define (main) : i64
  (let [value : Big (Big 1 2 3)]
    (begin
      (change (&mut value))
      value.a)))")
    (compiler-typecheck-ok?
      "(defstruct Bag
  (items (__tl_dyn-array i64))
  (pad0 i64)
  (pad1 i64))
(define (change [value : Bag]) : unit
  (set! (array-ref value.items 0) 7))")
    (compiler-typecheck-ok?
      "(defstruct Big (a i64) (b i64) (c i64))
(define (change [value : Big]) : unit
  (set! value.a 7))")))

(define (compiler-typecheck-moved-set-growth
  [set : tc_core.TcMovedSet]
  [root-id : i64]
  [start : i64]
  [count : i64]
  [origin : ast.AstExpr]) : tc_core.TcMovedSet
  (let
    [out : tc_core.TcMovedSet set]
    [end : i64 (+ start count)]
    (for [index (iterator.range start end)]
      (set!
        out
        (tc_core.tc-moved-add-path-fact
          out
          (tc_core.TcMovePath
            root-id
            (tc_core.tc-move-path-segments-append-array
              (tc_core.tc-move-path-segments-empty)
              index))
          (BorrowShared)
          (ast.ast-node-push (ast.ast-global-shared-view origin)))))
    out))

(define (compiler-typecheck-moved-facts-same-dense-snapshot?
  [a : tc_core.TcMovedPathFacts]
  [b : tc_core.TcMovedPathFacts]) : bool
  (match a
    [(Dense store tail len)
      (match b
        [(Dense other-store other-tail other-len)
          (and
            (unsafe
              (=
                (ptr->int
                  (__tl_array-data
                    (__tl-project-field (__tl-box-place store) nodes)))
                (ptr->int
                  (__tl_array-data
                    (__tl-project-field (__tl-box-place other-store) nodes)))))
            (= tail other-tail)
            (= len other-len))]
        [_ false])]
    [_ false]))

(define (compiler-typecheck-moved-facts-same-dense-store?
  [a : tc_core.TcMovedPathFacts]
  [b : tc_core.TcMovedPathFacts]) : bool
  (match a
    [(Dense store _ _)
      (match b
        [(Dense other-store _ _)
          (unsafe
            (=
              (ptr->int
                (__tl_array-data
                  (__tl-project-field (__tl-box-place store) nodes)))
              (ptr->int
                (__tl_array-data
                  (__tl-project-field (__tl-box-place other-store) nodes)))))]
        [_ false])]
    [_ false]))

(define (compiler-typecheck-moved-set-metrics-ok?) : bool
  (let
    [alpha-id : i64 (ci.intern "alpha")]
    [beta-id : i64 (ci.intern "beta")]
    [origin-root-id : i64 (ci.intern "origin-root")]
    [items-id : i64 (ci.intern "items")]
    [shadowed-id : i64 (ci.intern "shadowed")]
    [shared-id : i64 (ci.intern "shared")]
    [growth-id : i64 (ci.intern "growth")]
    [items0 : tc_core.TcMovePath
      (tc_core.TcMovePath
        items-id
        (tc_core.tc-move-path-segments-append-array
          (tc_core.tc-move-path-segments-empty)
          0))]
    [items1 : tc_core.TcMovePath
      (tc_core.TcMovePath
        items-id
        (tc_core.tc-move-path-segments-append-array
          (tc_core.tc-move-path-segments-empty)
          1))]
    [items-root : tc_core.TcMovePath
      (tc_core.TcMovePath items-id (tc_core.tc-move-path-segments-empty))]
    [shadowed-root : tc_core.TcMovePath
      (tc_core.TcMovePath shadowed-id (tc_core.tc-move-path-segments-empty))]
    [growth0 : tc_core.TcMovePath
      (tc_core.TcMovePath
        growth-id
        (tc_core.tc-move-path-segments-append-array
          (tc_core.tc-move-path-segments-empty)
          0))]
    [growth1 : tc_core.TcMovePath
      (tc_core.TcMovePath
        growth-id
        (tc_core.tc-move-path-segments-append-array
          (tc_core.tc-move-path-segments-empty)
          1))]
    [growth63 : tc_core.TcMovePath
      (tc_core.TcMovePath
        growth-id
        (tc_core.tc-move-path-segments-append-array
          (tc_core.tc-move-path-segments-empty)
          63))]
    [origin-a : ast.AstExpr (Var (ci.intern "origin-a"))]
    [origin-b : ast.AstExpr (Var (ci.intern "origin-b"))]
    [empty : tc_core.TcMovedSet (tc_core.tc-moved-empty)]
    [one : tc_core.TcMovedSet (tc_core.tc-moved-add empty alpha-id)]
    [dupe : tc_core.TcMovedSet
      (tc_core.tc-moved-add (tc_core.tc-moved-clone one) alpha-id)]
    [two : tc_core.TcMovedSet
      (tc_core.tc-moved-add (tc_core.tc-moved-clone dupe) beta-id)]
    [removed : tc_core.TcMovedSet
      (tc_core.tc-moved-remove (tc_core.tc-moved-clone two) alpha-id)]
    [origin-whole : tc_core.TcMovedSet
      (tc_core.tc-moved-add-origin
        (tc_core.tc-moved-empty)
        origin-root-id
        (ast.ast-global-shared-view origin-a))]
    [origin-whole-id : i64
      (match (tc_core.tc-moved-conflict
        (tc_core.tc-global-shared-view origin-whole)
        origin-root-id)
        [(Some key origin-id)
          (if (string.eq key "origin-root")
            origin-id
            (tc_core.tc-moved-no-origin-id))]
        [No (tc_core.tc-moved-no-origin-id)])]
    [origin-whole-ok : bool
      (not (= origin-whole-id (tc_core.tc-moved-no-origin-id)))]
    [origin-clone-ok : bool
      (match (tc_core.tc-moved-conflict
        (tc_core.tc-moved-clone origin-whole)
        origin-root-id)
        [(Some _ origin-id) (= origin-id origin-whole-id)]
        [No false])]
    [partial : tc_core.TcMovedSet
      (tc_core.tc-moved-add-projection-path
        (tc_core.tc-moved-add-projection-path
          (tc_core.tc-moved-empty)
          items-id
          items0
          (ast.ast-global-shared-view origin-a))
        items-id
        items1
        (ast.ast-global-shared-view origin-b))]
    [partial-exact-conflict : bool
      (match (tc_core.tc-moved-path-conflict
        (tc_core.tc-global-shared-view partial)
        items0)
        [(Some key origin-id)
          (and
            (string.eq key "items[0]")
            (not (= origin-id (tc_core.tc-moved-no-origin-id))))]
        [No false])]
    [partial-parent-conflict : bool
      (match (tc_core.tc-moved-path-conflict
        (tc_core.tc-global-shared-view partial)
        items-root)
        [(Some _ origin-id) (not (= origin-id (tc_core.tc-moved-no-origin-id)))]
        [No false])]
    [partial-root-conflict : bool
      (match (tc_core.tc-moved-root-conflict
        (tc_core.tc-global-shared-view partial)
        items-id)
        [(Some _ origin-id) (not (= origin-id (tc_core.tc-moved-no-origin-id)))]
        [No false])]
    [partial-one : tc_core.TcMovedSet
      (tc_core.tc-moved-remove-exact-path
        (tc_core.tc-moved-clone partial)
        items-id
        items0)]
    [partial-clear : tc_core.TcMovedSet
      (tc_core.tc-moved-remove-exact-path
        (tc_core.tc-moved-clone partial-one)
        items-id
        items1)]
    [partial-keeps-sibling : bool
      (match (tc_core.tc-moved-path-exact-conflict
        (tc_core.tc-global-shared-view partial-one)
        items1)
        [(Some _ _) true]
        [No false])]
    [partial-keeps-marker : bool
      (tc_core.tc-moved-partial? partial-one items-id)]
    [partial-clears-sibling : bool
      (not
        (match (tc_core.tc-moved-path-exact-conflict
          (tc_core.tc-global-shared-view partial-clear)
          items1)
          [(Some _ _) true]
          [No false]))]
    [partial-clears-marker : bool
      (not (tc_core.tc-moved-partial? partial-clear items-id))]
    [root-path : tc_core.TcMovedSet
      (tc_core.tc-moved-add-path-fact
        (tc_core.tc-moved-empty)
        shadowed-root
        (Move)
        (tc_core.tc-moved-no-origin-id))]
    [root-path-clear : tc_core.TcMovedSet
      (tc_core.tc-moved-remove-root-state root-path shadowed-id)]
    [root-path-clears : bool
      (match (tc_core.tc-moved-path-exact-conflict
        root-path-clear
        shadowed-root)
        [(Some _ _) false]
        [No true])]
    [retained-parent : tc_core.TcMovedSet
      (compiler-typecheck-moved-set-growth
        (tc_core.tc-moved-empty)
        items-id
        0
        2
        (ast.ast-global-shared-view origin-a))]
    [sibling-successor : tc_core.TcMovedSet
      (tc_core.tc-moved-add-path-fact
        (tc_core.tc-global-shared-view retained-parent)
        shadowed-root
        (BorrowShared)
        (ast.ast-node-push (ast.ast-global-shared-view origin-b)))]
    [growth-successor : tc_core.TcMovedSet
      (compiler-typecheck-moved-set-growth
        (tc_core.tc-global-shared-view retained-parent)
        growth-id
        0
        64
        origin-a)]
    [retained-parent-isolated : bool
      (and
        (match (tc_core.tc-moved-path-exact-conflict-kind
          retained-parent
          items0
          (BorrowShared))
          [(Some _ _) true]
          [No false])
        (match (tc_core.tc-moved-path-exact-conflict-kind
          retained-parent
          shadowed-root
          (BorrowShared))
          [(Some _ _) false]
          [No true])
        (match (tc_core.tc-moved-path-exact-conflict-kind
          retained-parent
          growth63
          (BorrowShared))
          [(Some _ _) false]
          [No true]))]
    [successors-isolated : bool
      (and
        (match (tc_core.tc-moved-path-exact-conflict-kind
          growth-successor
          items0
          (BorrowShared))
          [(Some _ origin-id)
            (not (= origin-id (tc_core.tc-moved-no-origin-id)))]
          [No false])
        (match (tc_core.tc-moved-path-exact-conflict-kind
          growth-successor
          growth63
          (BorrowShared))
          [(Some _ _) true]
          [No false])
        (match (tc_core.tc-moved-path-exact-conflict-kind
          growth-successor
          shadowed-root
          (BorrowShared))
          [(Some _ _) false]
          [No true])
        (match (tc_core.tc-moved-path-exact-conflict-kind
          sibling-successor
          items0
          (BorrowShared))
          [(Some _ _) true]
          [No false])
        (match (tc_core.tc-moved-path-exact-conflict-kind
          sibling-successor
          shadowed-root
          (BorrowShared))
          [(Some _ _) true]
          [No false])
        (match (tc_core.tc-moved-path-exact-conflict-kind
          sibling-successor
          growth63
          (BorrowShared))
          [(Some _ _) false]
          [No true]))]
    [query-agrees-with-facts : bool
      (and
        (tc_core.tc-moved-path-facts-contains-exact-kind?
          (tc_core.tc-moved-paths
            (tc_core.tc-global-shared-view growth-successor))
          items0
          (BorrowShared))
        (not
          (tc_core.tc-moved-path-facts-contains-exact-kind?
            (tc_core.tc-moved-paths growth-successor)
            shadowed-root
            (BorrowShared))))]
    [separate-store : tc_core.TcMovedSet
      (compiler-typecheck-moved-set-growth
        (tc_core.tc-moved-empty)
        growth-id
        0
        2
        origin-b)]
    [cross-store-union : tc_core.TcMovedSet
      (tc_core.tc-moved-union retained-parent separate-store)]
    [cross-store-facts : tc_core.TcMovedPathFacts
      (tc_core.tc-moved-paths (tc_core.tc-global-shared-view cross-store-union))]
    [cross-store-destination-ok : bool
      (compiler-typecheck-moved-facts-same-dense-store?
        (tc_core.tc-moved-paths (tc_core.tc-global-shared-view retained-parent))
        (tc_core.tc-global-shared-view cross-store-facts))]
    [cross-store-order-ok : bool
      (tc_core.tc-move-path-eq?
        (core_tests.tc-moved-path-fact-path
          (tc_core.tc-moved-path-facts-head cross-store-facts))
        growth0)]
    [cross-store-removed : tc_core.TcMovedSet
      (tc_core.tc-moved-remove-path-kind
        (tc_core.tc-global-shared-view cross-store-union)
        growth1
        (BorrowShared))]
    [cross-store-remove-ok : bool
      (and
        (=
          (tc_core.tc-moved-path-facts-len
            (tc_core.tc-moved-paths
              (tc_core.tc-global-shared-view cross-store-removed)))
          3)
        (tc_core.tc-moved-path-facts-contains-exact-kind?
          (tc_core.tc-moved-paths
            (tc_core.tc-global-shared-view cross-store-removed))
          growth0
          (BorrowShared))
        (not
          (tc_core.tc-moved-path-facts-contains-exact-kind?
            (tc_core.tc-moved-paths cross-store-removed)
            growth1
            (BorrowShared))))]
    [missing-removal : tc_core.TcMovedSet
      (tc_core.tc-moved-remove-path-kind
        (tc_core.tc-global-shared-view cross-store-union)
        shadowed-root
        (Move))]
    [missing-removal-preserves-snapshot : bool
      (compiler-typecheck-moved-facts-same-dense-snapshot?
        (tc_core.tc-moved-paths
          (tc_core.tc-global-shared-view cross-store-union))
        (tc_core.tc-moved-paths missing-removal))]
    [missing-filter : tc_core.TcMovedSet
      (tc_core.tc-moved-remove-root-state
        (tc_core.tc-global-shared-view cross-store-union)
        shadowed-id)]
    [missing-filter-preserves-snapshot : bool
      (compiler-typecheck-moved-facts-same-dense-snapshot?
        (tc_core.tc-moved-paths
          (tc_core.tc-global-shared-view cross-store-union))
        (tc_core.tc-moved-paths missing-filter))]
    [filtered-growth : tc_core.TcMovedSet
      (tc_core.tc-moved-remove-root-state cross-store-union growth-id)]
    [changed-filter-reuses-tail : bool
      (compiler-typecheck-moved-facts-same-dense-snapshot?
        (tc_core.tc-moved-paths retained-parent)
        (tc_core.tc-moved-paths filtered-growth))]
    [union-left : tc_core.TcMovedSet
      (tc_core.tc-moved-add-value (tc_core.tc-moved-empty) shared-id 101)]
    [union-right : tc_core.TcMovedSet
      (tc_core.tc-moved-add-value (tc_core.tc-moved-empty) shared-id 202)]
    [union-origin-left : bool
      (match (tc_core.tc-moved-conflict
        (tc_core.tc-moved-union union-left union-right)
        shared-id)
        [(Some _ origin-id) (= origin-id 101)]
        [No false])]
    (and
      (=
        (let
          [set (tc_core.tc-moved-empty)]
          (tc_core.tc-moved-len set))
        0)
      (= (tc_core.tc-moved-len dupe) 1)
      (= (tc_core.tc-moved-len two) 2)
      (>= (core_tests.tc-moved-capacity two) 8)
      (not (tc_core.tc-moved-contains? removed alpha-id))
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
      retained-parent-isolated
      successors-isolated
      query-agrees-with-facts
      cross-store-destination-ok
      cross-store-order-ok
      cross-store-remove-ok
      missing-removal-preserves-snapshot
      missing-filter-preserves-snapshot
      changed-filter-reuses-tail
      union-origin-left)))

;; Returns true when use-after-move is rejected (straight-line and after a
;; branch that moves on every arm), while a single move, copyable reuse, ordinary
;; aggregate/projection sharing, one-shot owner transfers, branch isolation,
;; and conservative repeated-loop owner moves pass. Creating a closure moves
;; each move-only capture even though execution of its body remains deferred.
;; --- ordinary `let` cleanup obligations (#6947) ----------------------------
(define (compiler-typecheck-let-obligation-source [src : String]) : String
  (str_cat.str-cat
    "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Pair
  (:cleanup cleanup-pair)
  (a FileHandle (:owned))
  (b i64))
(define (open [fd : i64]) : FileHandle (FileHandle fd))
(define (peek [h : (& h FileHandle)]) : i64 h.fd)
(define (take [h : FileHandle]) : unit unit)
(define (same-shape [h : FileHandle]) : unit unit)
(defenum Outcome (Ok i64) (Err i64))
(define (fail) : Outcome (Outcome.Err 1))
"
    src))

(define (compiler-typecheck-scope-owner-state-isolation-ok?) : bool
  (let
    [installed : ci.InternCompatState (ci.intern-compat-state-capture-active)]
    [owner : ci.InternCompatState (ci.intern-compat-state-new)]
    [decoy : ci.InternCompatState (ci.intern-compat-state-new)]
    [name : i64 (ci.intern-compat-state-intern (&mut owner) "handle")]
    (ci.intern-compat-state-intern (&mut decoy) "other-0")
    (ci.intern-compat-state-intern (&mut decoy) "other-1")
    (ci.intern-compat-state-intern (&mut decoy) "other-2")
    (ci.intern-compat-state-intern (&mut decoy) "other-3")
    (ci.intern-compat-state-install! (& owner))
    (let
      [locals : tc_core.TcMovedSet
        (tc_core.tc-move-enter-loop-body
          (tc_core.tc-move-bind-let-obligation (tc_core.tc-moved-empty) name 42))]
      (ci.intern-compat-state-capture-from-globals! (&mut owner))
      (ci.intern-compat-state-install! (& decoy))
      (let
        [foreign : tc_core.TcMovedSet
          (tc_core.tc-move-bind-let-obligation (tc_core.tc-moved-empty) name 43)]
        [ok : bool
          (and
            (tc_core.tc-move-owners-in-scope?
              (tc_core.tc-global-shared-view locals))
            (=
              (tc_core.tc-move-loop-depth
                (tc_core.tc-global-shared-view locals))
              1)
            (tc_core.tc-move-let-obligated?
              (tc_core.tc-global-shared-view locals)
              name)
            (tc_core.tc-move-owners-in-scope?
              (tc_core.tc-global-shared-view foreign))
            (= (tc_core.tc-move-loop-depth foreign) 0))]
        (ci.intern-compat-state-install! (& installed))
        (unsafe
          (ci.tl_arena_destroy
            (ci.intern-compat-state-persistent-arena (& owner)))
          (ci.tl_arena_destroy
            (ci.intern-compat-state-persistent-arena (& decoy))))
        ok))))

(define (compiler-typecheck-deep-owner-source [body : String]) : String
  (let
    [nested : String body]
    (for [depth (iterator.range 0 63)]
      (set! nested (str_cat.str-cat "(while true (begin " nested " (break)))")))
    (compiler-typecheck-let-obligation-source
      (str_cat.str-cat
        "(define (f) : unit (with ([root (open 1) cleanup-file-handle]) "
        nested
        "))"))))

(define (compiler-typecheck-let-obligation-tests-ok?) : bool
  (and
    (compiler-typecheck-scope-owner-state-isolation-ok?)
    (compiler-typecheck-ok?
      (compiler-typecheck-deep-owner-source
        "(let [h : FileHandle (open 2)] (begin (while true (break)) (cleanup-file-handle h)))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-deep-owner-source
        "(let [h : FileHandle (open 2)] (break))")
      "typecheck: cleanup obligation of `h` is not discharged before this break leaves its loop")
    ;; Discharged by the declared cleanup function, on every path.
    (compiler-typecheck-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f [bad : bool]) : i64
  (let [h : FileHandle (open 1)]
    (begin
      (if bad (begin (cleanup-file-handle h) (return -1)) unit)
      (let [fd : i64 (peek (& h))]
        (begin (cleanup-file-handle h) fd)))))"))
    ;; Transferred to another `let`, a cleanup-owning aggregate, a `with`
    ;; owner, or the function result.
    (compiler-typecheck-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f) : i64
  (let [h : FileHandle (open 1)]
    (let [g : FileHandle h]
      (let [p : Pair (Pair g 2)]
        (with ([w p cleanup-pair]) w.b)))))
(define (g) : FileHandle
  (let [h : FileHandle (open 1)]
    (begin (peek (& h)) h)))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f) : i64
  (let [h : FileHandle (open 1)]
    (peek (& h))))")
      "typecheck: cleanup obligation of `h` is not discharged at the end of its let scope")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f [bad : bool]) : i64
  (let [h : FileHandle (open 1)]
    (begin
      (if bad (return -1) unit)
      (cleanup-file-handle h)
      0)))")
      "typecheck: cleanup obligation of `h` is not discharged before this return")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f [c : bool]) : i64
  (let [h : FileHandle (open 1)]
    (begin
      (if c (cleanup-file-handle h) unit)
      0)))")
      "typecheck: cleanup obligation of `h` is discharged on only some paths through this branch")
    ;; A same-shaped function is not the declared disposer.
    (compiler-typecheck-error-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f) : i64
  (let [h : FileHandle (open 1)]
    (begin (same-shape h) 0)))")
      "typecheck: cleanup obligation of `h` is lost where it is moved without being discharged")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f [n : i64]) : i64
  (begin
    (while (< n 3)
      (let [h : FileHandle (open n)]
        (break)))
    0))")
      "typecheck: cleanup obligation of `h` is not discharged before this break leaves its loop")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f) : Outcome
  (let [h : FileHandle (open 1)]
    (let [v : i64 (try (fail))]
      (begin (cleanup-file-handle h) (Outcome.Ok v)))))")
      "typecheck: cleanup obligation of `h` is not discharged before this try can propagate an error")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-let-obligation-source
        "(define (f) : i64
  (let [p : Pair (Pair (open 1) 2)]
    (begin (cleanup-file-handle p.a) 0)))")
      "typecheck: cleanup obligation of `p` is only partly discharged at the end of its let scope")))

(define (compiler-typecheck-move-tests-ok?) : bool
  (and
    (compiler-typecheck-moved-set-metrics-ok?)
    (compiler-typecheck-error-ok?
      (compiler-typecheck-move-use-after-move-source)
      "typecheck: use of moved value `s`")
    (compiler-typecheck-ok?
      "(define (single-move [s : String]) : String
  (let [t : String s] t))")
    (compiler-typecheck-ok?
      "(define (copy-reuse [n : i64]) : i64
  (let [t : i64 n] (+ n t)))")
    (compiler-typecheck-ok?
      (compiler-typecheck-move-type-driven-inspection-parity-source))
    (compiler-typecheck-ok?
      "(module inspection_provider)
(define (inspect-text [text : (& text str)]) : i64 0)
(module inspection_user)
(import inspection_provider as provider)
(define (inspect-qualified [value : String]) : String
  (begin (provider.inspect-text value) value))")
    (compiler-typecheck-ok? (compiler-typecheck-move-structural-copy-source))
    (compiler-typecheck-error-ok?
      "(defstruct TextPacket (text String))
(define (take-text [value : TextPacket]) : unit unit)
(define (bad-text-reuse [value : TextPacket]) : unit
  (begin (take-text value) (take-text value)))"
      "typecheck: use of moved value `value`")
    (compiler-typecheck-error-ok?
      "(defstruct TextPacket (text String))
(defstruct NestedTextPacket (packet TextPacket))
(define (take-nested-text [value : NestedTextPacket]) : unit unit)
(define (bad-nested-text-reuse [value : NestedTextPacket]) : unit
  (begin (take-nested-text value) (take-nested-text value)))"
      "typecheck: use of moved value `value`")
    (compiler-typecheck-ok?
      "(defmacro (generate-copyable) : Decls
  `(begin (defstruct GeneratedScalar (value i64))))
(generate-copyable)
(define (take-generated [value : GeneratedScalar]) : unit unit)
(define (reuse-generated [value : GeneratedScalar]) : unit
  (begin (take-generated value) (take-generated value)))")
    (compiler-typecheck-ok?
      "(module owner)
(defstruct Scalar (value i64))
(defstruct Wrapper (value Scalar))
(module use)
(defstruct Scalar (text String))
(import owner as o)
(define (take-wrapper [value : o.Wrapper]) : unit unit)
(define (reuse-wrapper [value : o.Wrapper]) : unit
  (begin (take-wrapper value) (take-wrapper value)))")
    (compiler-typecheck-error-ok?
      "(define (branch-move [flag : bool] [s : String]) : String
  (begin (if flag (let [t : String s] t) (let [u : String s] u)) s))"
      "typecheck: use of moved value `s`")
    (compiler-typecheck-ok?
      "(defstruct OrdinaryPacket
  (name String)
  (count i64))
(defstruct OrdinaryWrapper
  (packet OrdinaryPacket))
(defenum MaybeCount (SomeCount i64) (NoCount))
(define (inspect-packet [p : (& p OrdinaryPacket)]) : i64 p.count)
(define (ordinary-sharing [p : OrdinaryPacket] [m : MaybeCount]) : i64
  (begin
    (inspect-packet (& p))
    (let [w : OrdinaryWrapper (OrdinaryWrapper (clone p))]
      (begin
        (match m [(SomeCount v) v] [NoCount 0])
        (+ p.count w.packet.count)))))")
    (compiler-typecheck-ok?
      "(defenum Flag (On) (Off))
(define (ordinary-enum-match-reuse [flag : Flag]) : i64
  (begin
    (match flag [(On) 1] [(Off) 0])
    (match flag [(On) 2] [(Off) 3])))")
    (compiler-typecheck-ok?
      "(defenum Ticket
  (:cleanup cleanup-ticket)
  (Open i64)
  (Closed))
(define (cleanup-enum-match [ticket : Ticket]) : i64
  (match ticket [(Open code) code] [(Closed) 0]))")
    (compiler-typecheck-error-ok?
      "(defenum Ticket
  (:cleanup cleanup-ticket)
  (Open i64)
  (Closed))
(define (take-ticket [ticket : Ticket]) : unit unit)
(define (bad-cleanup-enum-match-param-reuse [ticket : Ticket]) : unit
  (begin
    (match ticket [(Open code) unit] [(Closed) unit])
    (take-ticket ticket)))"
      "typecheck: use of moved value `ticket`")
    (compiler-typecheck-error-ok?
      "(defenum Ticket
  (:cleanup cleanup-ticket)
  (Open i64)
  (Closed))
(define (take-ticket [ticket : Ticket]) : unit unit)
(define (bad-cleanup-enum-match-local-reuse [n : i64]) : unit
  (with ([ticket (Open n) cleanup-ticket])
    (begin
      (match ticket [(Open code) unit] [(Closed) unit])
      (take-ticket ticket))))"
      "typecheck: use of moved value `ticket`")
    (compiler-typecheck-ok?
      (str_cat.str-cat
        (compiler-typecheck-move-cleanup-enum-payload-prefix)
        "(define (cleanup-enum-owner-payload-one-shot [m : MaybeHandle]) : unit
  (match m
    [(Some h) (take-handle h)]
    [(Code code) unit]
    [(None) unit]))"))
    (compiler-typecheck-error-ok?
      (str_cat.str-cat
        (compiler-typecheck-move-cleanup-enum-payload-prefix)
        "(define (bad-cleanup-enum-owner-payload-repeat [m : MaybeHandle]) : unit
  (match m
    [(Some h) (begin (take-handle h) (take-handle h))]
    [(Code code) unit]
    [(None) unit]))")
      "typecheck: use of moved value `h`")
    (compiler-typecheck-ok?
      (str_cat.str-cat
        (compiler-typecheck-move-cleanup-enum-payload-prefix)
        "(define (cleanup-enum-payload-copyable [m : MaybeHandle]) : i64
  (match m
    [(Some h) 0]
    [(Code code) (+ code code)]
    [(None) 0]))"))
    (compiler-typecheck-ok?
      (str_cat.str-cat
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
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (valid-owner-call [h : FileHandle]) : unit (take-handle h))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-call [h : FileHandle]) : i64
  (begin (take-handle h) h.fd))"
      "typecheck: use of moved value `h`")
    (compiler-typecheck-error-ok?
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
    h.fd))"
      "typecheck: use of moved value `h`")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-return [h : FileHandle]) : FileHandle
  (begin (return h) h))"
      "typecheck: use of moved value `h`")
    (compiler-typecheck-ok?
      "(defstruct Counter
  (value i64))
(defstruct CounterHolder
  (counter Counter)
  (tag i64))
(define (inspect-counter [c : Counter]) : i64 c.value)
(define (ordinary-projection [p : CounterHolder]) : i64
  (begin
    (inspect-counter p.counter)
    p.tag))")
    (compiler-typecheck-ok?
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
    (take-handle p.handle)
    p.size))")
    (compiler-typecheck-ok?
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
  (take-handle p.handle))")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))
(define (owner-projection-bind-other-field [p : Holder]) : i64
  (with ([h p.handle cleanup-file-handle])
    p.size))")
    (compiler-typecheck-ok?
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
  (take-handle p.inner.handle))")
    (compiler-typecheck-ok?
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
    (take-handle p.inner.handle)
    (take-handle p.inner.backup)))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-move-owner-projection-nested-repeat-source)
      "typecheck: use of moved value `p.inner.handle`")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-move-owner-projection-deep-mixed-repeat-source)
      "typecheck: use of moved value `p.mixed.0[1].0`")
    (compiler-typecheck-error-ok?
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
    (take-handle p.inner.handle)
    (take-holder p)))"
      "typecheck: use of moved value `p`")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-move-owner-projection-nested-parent-after-child-source)
      "typecheck: use of moved value `p.inner`")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-move-owner-projection-nested-child-after-parent-source)
      "typecheck: use of moved value `p.inner`")
    (compiler-typecheck-ok?
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
(define (owner-projection-nested-set-reset) : unit
  (with ([p (Holder (Inner (FileHandle 1) 2) 3) cleanup-holder])
    (begin
      (take-handle p.inner.handle)
      (set! p.inner.handle (FileHandle 10))
      (take-handle p.inner.handle)
      (set! p.inner.handle (FileHandle 20)))))")
    (compiler-typecheck-ok?
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
      q.inner.handle.fd
      (with ([q (Holder (Inner (FileHandle 20) 21) 22) cleanup-holder])
        (begin
          q.inner.handle.fd
          unit)))))")
    (compiler-typecheck-error-ok?
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
    (take-handle p.handle)
    (take-handle p.handle)))"
      "typecheck: use of moved value `p.handle`")
    (compiler-typecheck-error-ok?
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
    (take-handle p.handle)
    (take-holder p)))"
      "typecheck: use of moved value `p`")
    (compiler-typecheck-ok?
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
  [p.handle.shadow : i64]
  [p.__tl_partial : i64]) : i64
  (begin
    (take-handle p.handle)
    (+ p.size (+ p.handle.shadow p.__tl_partial))))")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-tuple-ref-other-element [p : (Tuple FileHandle i64)]) : i64
  (begin
    (take-handle (tuple-ref p 0))
    (tuple-ref p 1)))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-tuple-ref-repeat [p : (Tuple FileHandle i64)]) : unit
  (begin
    (take-handle (tuple-ref p 0))
    (take-handle (tuple-ref p 0))))"
      "typecheck: use of moved value `p.0`")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-tuple-ref-nested [p : (Tuple (Tuple FileHandle i64) i64)]) : unit
  (take-handle (tuple-ref (tuple-ref p 0) 0)))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-tuple-ref-nested-repeat [p : (Tuple (Tuple FileHandle i64) i64)]) : unit
  (begin
    (take-handle (tuple-ref (tuple-ref p 0) 0))
    (take-handle (tuple-ref (tuple-ref p 0) 0))))"
      "typecheck: use of moved value `p.0.0`")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-tuple-ref-nested-sibling [p : (Tuple (Tuple FileHandle FileHandle) i64)]) : unit
  (begin
    (take-handle (tuple-ref (tuple-ref p 0) 0))
    (take-handle (tuple-ref (tuple-ref p 0) 1))))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-tuple-ref-overwrite [p : (Tuple FileHandle i64)]) : unit
  (set! (tuple-ref p 0) (FileHandle 2)))"
      "typecheck: cannot overwrite initialized cleanup-owning place; move or clean up the old value first")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-tuple-ref-reinit [p : (Tuple FileHandle i64)]) : unit
  (begin
    (take-handle (tuple-ref p 0))
    (set! (tuple-ref p 0) (FileHandle 2))))")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (handle-fd [h : (& h FileHandle)]) : i64 h.fd)
(define (owner-array-ref-other-element [items : (Array FileHandle 2)]) : i64
  (begin
    (take-handle (array-ref items 0))
    (handle-fd (& (array-ref items 1)))))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-repeat [items : (Array FileHandle 1)]) : unit
  (begin
    (take-handle (array-ref items 0))
    (take-handle (array-ref items 0))))"
      "typecheck: use of moved value `items[0]`")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-reinit [items : (Array FileHandle 1)]) : unit
  (begin
    (take-handle (array-ref items 0))
    (set! (array-ref items 0) (FileHandle 7))
    (take-handle (array-ref items 0))))")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-reinit-root [items : (Array FileHandle 1)]) : unit
  (begin
    (take-handle (array-ref items 0))
    (set! (array-ref items 0) (FileHandle 7))
    (let [next : (Array FileHandle 1) items] unit)))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-reinit-sibling [items : (Array FileHandle 2)]) : unit
  (begin
    (take-handle (array-ref items 0))
    (take-handle (array-ref items 1))
    (set! (array-ref items 1) (FileHandle 7))
    (take-handle (array-ref items 0))))"
      "typecheck: use of moved value `items[0]`")
    (compiler-typecheck-error-ok?
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
    (set! (array-ref items index) (FileHandle 7))
    (take-handle (array-ref items 0))))"
      "typecheck: cannot overwrite initialized cleanup-owning place; move or clean up the old value first")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-nested [items : (Array (Array FileHandle 2) 2)]) : unit
  (take-handle (array-ref (array-ref items 0) 1)))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-nested-repeat [items : (Array (Array FileHandle 2) 2)]) : unit
  (begin
    (take-handle (array-ref (array-ref items 0) 1))
    (take-handle (array-ref (array-ref items 0) 1))))"
      "typecheck: use of moved value `items[0][1]`")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (owner-array-ref-nested-sibling [items : (Array (Array FileHandle 2) 2)]) : unit
  (begin
    (take-handle (array-ref (array-ref items 0) 1))
    (take-handle (array-ref (array-ref items 0) 0))))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-array-ref-nonliteral
  [items : (Array FileHandle 2)]
  [index : i64]) : unit
  (take-handle (array-ref items index)))"
      "typecheck: cannot move owner-consuming value out of aggregate path")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-dyn-array-ref-call [items : (__tl_dyn-array FileHandle)] [i : i64]) : unit
  (take-handle (array-ref items i)))"
      "typecheck: cannot move owner-consuming value out of dynamic array element")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-dyn-array-ref-bind [items : (__tl_dyn-array FileHandle)] [i : i64]) : i64
  (let [h : FileHandle (array-ref items i)]
    h.fd))"
      "typecheck: cannot move owner-consuming value out of dynamic array element")
    (compiler-typecheck-ok?
      "(define (main) : i64
  (let
    [cell : (Box i64) (box 7)]
    (deref cell)))")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : unit unit)
(define (bad-owner-box-get-call [cell : (Box FileHandle)]) : unit
  (take-handle (deref cell)))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-box-get-bind [cell : (Box FileHandle)]) : i64
  (let [h : FileHandle (deref cell)]
    h.fd))"
      "typecheck: cleanup obligation of `h` is not discharged at the end of its let scope")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-box-get-return [cell : (Box FileHandle)]) : FileHandle
  (return (deref cell)))")
    (compiler-typecheck-error-ok?
      "(define (bad-box-take-reuse [cell : (Box String)]) : i64
  (let
    [value : String (deref cell)]
    (+ (__tl_string_length value) (__tl_string_length (deref cell)))))"
      "typecheck: use of moved value `cell`")
    (compiler-typecheck-ok?
      "(defstruct Holder (value String))
(define (main) : i64
  (let [holder : Holder (Holder \"old\")]
    (begin
      (set! holder.value \"replacement\")
      (__tl_string_length holder.value))))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [_fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (main) : i64
  (with ([handle (FileHandle 1) cleanup-file-handle])
    (begin
      (set! handle (FileHandle 2))
      handle.fd)))"
      "typecheck: cannot overwrite initialized cleanup-owning place; move or clean up the old value first")
    (compiler-typecheck-ok?
      "(define (close-fd [_fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (consume-handle [_handle : FileHandle]) : unit unit)
(define (main) : i64
  (with ([handle (FileHandle 1) cleanup-file-handle])
    (begin
      (consume-handle handle)
      (set! handle (FileHandle 2))
      handle.fd)))")
    (compiler-typecheck-ok?
      "(define (branch-arm-isolated [flag : bool] [s : String]) : String
  (if flag (let [t : String s] t) s))")
    (compiler-typecheck-error-ok?
      "(define (lambda-body-discard [s : String]) : String
  (begin (lambda () : unit (let [t : String s] unit)) s))"
      "typecheck: closure capability would be erased by escaping the direct local binding")
    (compiler-typecheck-error-ok?
      "(define (owner-lambda-capture-box-ok [cell : (Box i64)]) : (-> i64)
  (lambda () : i64 (deref cell)))"
      "typecheck: non-Copy closure ownership would be erased by escaping the direct local binding")
    (compiler-typecheck-error-ok?
      "(define (bad-owner-lambda-capture-box-reuse [cell : (Box i64)]) : i64
  (begin (lambda () : i64 (deref cell)) (deref cell)))"
      "typecheck: use of moved value `cell`")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (bad-owner-lambda-capture-cleanup-reuse [h : FileHandle]) : i64
  (begin (lambda () : i64 h.fd) h.fd))"
      "typecheck: use of moved value `h`")
    (compiler-typecheck-error-ok?
      "(define (take-cell [cell : (Box i64)]) : unit unit)
(define (bad-owner-lambda-body-reuse [cell : (Box i64)]) : (-> i64)
  (lambda () : i64 (begin (take-cell cell) (deref cell))))"
      "typecheck: closure capability would be erased by escaping the direct local binding")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-move-while-loop-carried-param-source)
      "typecheck: cannot move loop-carried owner value `s`")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (bad-while-loop-carried-local [flag : bool]) : unit
  (let
    [s : String (string.int->string 1)]
    (while flag (let [t : String s] unit))))")
      "typecheck: cannot move loop-carried owner value `s`")
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (identity [s : String]) : String s)
(define (while-reinitialize [n : i64]) : String
  (let
    [s : String (string.int->string 1)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! s (identity s))
          (set! i (+ i 1))))
      s)))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (while-body-local-owner [flag : bool]) : unit
  (while flag
    (let
      [s : String (string.int->string 1)]
      (let [t : String s] unit))))"))
    (compiler-typecheck-ok?
      "(define (while-copyable [flag : bool] [n : i64]) : i64
  (begin (while flag (let [m : i64 n] unit)) n))")
    (compiler-typecheck-error-ok?
      "(define (bad-foreach-loop-carried-param [n : i64] [s : String]) : unit
  (foreach ([i : i64 0 n]) (let [t : String s] unit)))"
      "typecheck: cannot move loop-carried owner value `s`")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (bad-foreach-loop-carried-local [n : i64]) : unit
  (let
    [s : String (string.int->string 1)]
    (foreach ([i : i64 0 n]) (let [t : String s] unit))))")
      "typecheck: cannot move loop-carried owner value `s`")
    (compiler-typecheck-ok?
      (compiler-typecheck-with-alloc-string-helper-source
        "(define (foreach-body-local-owner [n : i64]) : unit
  (foreach ([i : i64 0 n])
    (let
      [s : String (string.int->string 1)]
      (let [t : String s] unit))))"))
    (compiler-typecheck-ok?
      "(define (foreach-copyable [n : i64] [x : i64]) : i64
  (begin (foreach ([i : i64 0 n]) (let [y : i64 x] unit)) x))")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (with-cleanup-owner-read [fd : i64]) : i64
  (with ([h (FileHandle fd) cleanup-file-handle])
    h.fd))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-move-with-cleanup-owner-whole-source)
      "typecheck: cleanup owner `h` moved before with scope exit")
    ;; A consumed `if` / `begin` value moves the cleanup-obligated places at
    ;; its tails (#8268).
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : i64 (begin (cleanup-file-handle h) 0))
(define (bad-if-tail-reuse [c : bool] [x : FileHandle] [z : FileHandle]) : i64
  (+ (take-handle (if c x z)) (take-handle x)))"
      "typecheck: use of moved value `x`")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : i64 (begin (cleanup-file-handle h) 0))
(define (bad-with-owner-begin-tail) : i64
  (with ([h (FileHandle 3) cleanup-file-handle])
    (begin
      (take-handle (begin 0 h))
      7)))"
      "typecheck: cleanup owner `h` moved before with scope exit")
    (compiler-typecheck-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : i64 (begin (cleanup-file-handle h) 0))
(define (diverging-tail [c : bool] [x : FileHandle]) : i64
  (begin
    (if c (return (take-handle (begin 0 x))) unit)
    (take-handle x)))")
    ;; A diverging arm leaves the join; the edge it leaves through checks the
    ;; enclosing with scope's owner.
    (compiler-typecheck-ok?
      "(defstruct Token (id i64) (name String))
(defenum Mode (Fast) (Slow))
(define (consume [t : Token]) : i64 t.id)
(define (pick [mode : Mode]) : i64
  (let
    [t : Token (Token 41 \"t\")]
    (begin
      (match mode
        [(Mode.Fast) (return (consume t))]
        [(Mode.Slow) unit])
      (+ (consume t) 1))))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : i64 0)
(define (bad-with-cleanup-owner-returning-arm [flag : bool]) : i64
  (with ([h (FileHandle 3) cleanup-file-handle])
    (begin
      (if flag (return (take-handle h)) unit)
      7)))"
      "typecheck: cleanup owner `h` moved before with scope exit")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(defenum Mode (Fast) (Slow))
(define (take-handle [h : FileHandle]) : i64 0)
(define (bad-with-cleanup-owner-returning-match [mode : Mode]) : i64
  (with ([h (FileHandle 3) cleanup-file-handle])
    (begin
      (match mode
        [(Mode.Fast) (return (take-handle h))]
        [(Mode.Slow) unit])
      7)))"
      "typecheck: cleanup owner `h` moved before with scope exit")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-move-with-cleanup-owner-field-source)
      "typecheck: cleanup owner `h` moved before with scope exit")
    ;; A shadowing binding gives the outer local its move state back where its
    ;; scope ends (#8266).
    (compiler-typecheck-error-ok?
      "(defstruct Token (id i64) (name String))
(define (consume [t : Token]) : i64 t.id)
(define (bad-shadow-let-reuse [t : Token]) : i64
  (let
    [first : i64 (consume t)]
    (begin
      (let [t : i64 1] t)
      (+ first (consume t)))))"
      "typecheck: use of moved value `t`")
    (compiler-typecheck-ok?
      "(defstruct Token (id i64) (name String))
(define (consume [t : Token]) : i64 t.id)
(define (shadow-inner-move [t : Token] [other : Token]) : i64
  (let
    [first : i64 (let [t : Token other] (consume t))]
    (+ first (consume t))))")
    (compiler-typecheck-error-ok?
      "(define (close-fd [fd : i64]) : unit unit)
(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))
(define (take-handle [h : FileHandle]) : i64 0)
(define (bad-with-cleanup-owner-moved-then-shadowed) : i64
  (with ([h (FileHandle 3) cleanup-file-handle])
    (begin
      (take-handle h)
      (let [h : i64 1] h)
      7)))"
      "typecheck: cleanup owner `h` moved before with scope exit")
    (compiler-typecheck-move-operand-loop-edge-tests-ok?)))

;; #8575: a `break` or `continue` nested in an operand of a form the loop walker
;; has no arm for takes its loop edge with the moves made up to it.
(define (compiler-typecheck-move-operand-loop-source [body : String]) : String
  (str_cat.str-cat
    "(defstruct Token (id i64) (name String))
(defstruct Pair (a i64) (b i64))
(define (consume [t : Token]) : i64 t.id)
(define (consume2 [t : Token] [n : i64]) : i64 (+ t.id n))
(define (id [x : i64]) : i64 x)
(define (keep [x : i64]) : unit unit)
"
    body))

(define (compiler-typecheck-move-operand-loop-error-ok?
  [body : String]
  [message : String]) : bool
  (compiler-typecheck-error-ok?
    (compiler-typecheck-move-operand-loop-source body)
    message))

(define (compiler-typecheck-move-operand-loop-edge-tests-ok?) : bool
  (and
    ;; The break edge of each operand position reaches the use after the loop.
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (call-arg [t : Token] [flag : bool]) : i64
  (begin
    (while true
      (keep (id (if flag (begin (consume t) (break)) 1)))
      (break))
    (consume t)))"
      "typecheck: use of moved value `t`")
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (binary-operand [t : Token] [flag : bool]) : i64
  (let [acc : i64 0]
    (while true
      (set! acc (+ (if flag (begin (consume t) (break)) 1) acc))
      (break))
    (+ acc (consume t))))"
      "typecheck: use of moved value `t`")
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (set-value [t : Token] [flag : bool]) : i64
  (let [acc : i64 0]
    (while true
      (set! acc (if flag (begin (consume t) (break)) 1))
      (break))
    (+ acc (consume t))))"
      "typecheck: use of moved value `t`")
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (constructor-arg [t : Token] [flag : bool]) : i64
  (let [acc : i64 0]
    (while true
      (let [p (Pair (if flag (begin (consume t) (break)) 1) 2)] (set! acc p.a))
      (break))
    (+ acc (consume t))))"
      "typecheck: use of moved value `t`")
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (return-operand [t : Token] [flag : bool]) : i64
  (begin
    (while true
      (return (if flag (begin (consume t) (break)) 1)))
    (consume t)))"
      "typecheck: use of moved value `t`")
    ;; An inner loop's header runs in the outer loop, so its break leaves that.
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (inner-while-condition [t : Token] [flag : bool]) : i64
  (let [acc : i64 0]
    (while true
      (while (if flag (begin (consume t) (break)) false) (set! acc 1))
      (break))
    (+ acc (consume t))))"
      "typecheck: use of moved value `t`")
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (inner-foreach-bound [t : Token] [flag : bool] [out : (&mut (Array i64 3))]) : i64
  (let [acc : i64 0]
    (while true
      (foreach ([i : i64 (if flag (begin (consume t) (break)) 0) 3])
        (set! (array-ref out i) i))
      (break))
    (+ acc (consume t))))"
      "typecheck: use of moved value `t`")
    ;; An argument evaluated before the break has already moved its place.
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (earlier-arg [t : Token] [flag : bool]) : i64
  (begin
    (while true
      (keep (consume2 t (if flag (break) 1)))
      (return 0))
    (consume t)))"
      "typecheck: use of moved value `t`")
    ;; A continue nested in an operand reaches the backedge, from its own
    ;; statement and from an earlier one.
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (continue-operand [t : Token] [flag : bool]) : i64
  (let [acc : i64 0]
    (while (< acc 3)
      (set! acc (+ acc 1))
      (keep (id (if flag (begin (consume t) (continue)) 1)))
      (break))
    acc))"
      "typecheck: cannot move loop-carried owner value `t`")
    (compiler-typecheck-move-operand-loop-error-ok?
      "(define (later-continue-operand [t : Token] [flag : bool]) : i64
  (let [acc : i64 0]
    (while (< acc 3)
      (set! acc (+ acc (consume t)))
      (keep (id (if flag (continue) 1)))
      (break))
    acc))"
      "typecheck: cannot move loop-carried owner value `t`")
    ;; Accepted: no use after the loop, a reinitialized place, a break that
    ;; leaves only an inner loop, Copy values, and a continue with no move.
    (compiler-typecheck-ok?
      (compiler-typecheck-move-operand-loop-source
        "(define (no-later-use [t : Token] [flag : bool]) : i64
  (let [acc : i64 0]
    (while true
      (keep (id (if flag (begin (set! acc (consume t)) (break)) 1)))
      (break))
    acc))
(define (reinitialized [t : Token] [flag : bool]) : i64
  (let [acc : i64 0] [u : Token t]
    (while true
      (set! acc (+ (if flag (begin (set! acc (consume u)) (break)) 1) acc))
      (break))
    (set! u (Token 2 \"u\"))
    (+ acc (consume u))))
(define (inner-loop-break [flag : bool]) : i64
  (let [acc : i64 0] [n : i64 0]
    (while (< n 3)
      (let [t : Token (Token n \"t\")]
        (while true
          (keep (id (if flag (begin (set! acc (+ acc (consume t))) (break)) 1)))
          (break)))
      (set! n (+ n 1)))
    acc))
(define (copy-only [x : i64] [flag : bool]) : i64
  (let [acc : i64 0]
    (while true
      (keep (id (if flag (begin (set! acc x) (break)) 1)))
      (break))
    (+ acc x)))
(define (continue-without-move [flag : bool]) : i64
  (let [acc : i64 0]
    (while (< acc 5)
      (set! acc (+ acc 1))
      (keep (id (if flag (continue) 1))))
    acc))"))))

;; --- defdispatch frontend model ---------------------------------------------
(define (compiler-typecheck-defdispatch-full-source) : String
  "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : i64]) : i64 (+ x 1))
(define (dot-avx512 [x : i64]) : i64 (+ x 2))
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx512 dot-avx512))
(define (main [x : i64]) : i64 (dot x))")

(define (compiler-typecheck-defdispatch-tests-ok?) : bool
  (and
    (compiler-typecheck-ok? (compiler-typecheck-defdispatch-full-source))
    (compiler-typecheck-ok?
      "(define (id-scalar [x : i64]) : i64 x)
(defdispatch id (scalar id-scalar))
(define (main [x : i64]) : i64 (id x))")
    (compiler-typecheck-ok?
      "(module kernels)
(define (dot-scalar [x : i64]) : i64 x)
(defdispatch dot (scalar dot-scalar))
(module app)
(import kernels as k)
(define (main [x : i64]) : i64 (k.dot x))")
    (compiler-typecheck-error-location-ok?
      "(define (dot-avx2 [x : i64]) : i64 x)
(defdispatch dot (avx2 dot-avx2))
(define (main [x : i64]) : i64 (dot x))"
      "typecheck: defdispatch requires exactly one scalar variant"
      2
      1)
    (compiler-typecheck-error-location-ok?
      "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : i64]) : i64 x)
(define (dot-avx2b [x : i64]) : i64 x)
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2) (avx2 dot-avx2b))
(define (main [x : i64]) : i64 (dot x))"
      "typecheck: duplicate defdispatch ISA variant"
      4
      1)
    (compiler-typecheck-error-ok?
      "(define (dot-scalar [x : i64]) : i64 x)
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2))
(define (main [x : i64]) : i64 (dot x))"
      "typecheck: unknown defdispatch variant dot-avx2")
    (compiler-typecheck-error-ok?
      "(define value : i64 1)
(defdispatch dot (scalar value))
(define (main [x : i64]) : i64 (dot x))"
      "typecheck: defdispatch variant is not a function value")
    (compiler-typecheck-error-ok?
      "(define (dot-scalar [x : i64]) : i64 x)
(define (dot-avx2 [x : bool]) : i64 0)
(defdispatch dot (scalar dot-scalar) (avx2 dot-avx2))
(define (main [x : i64]) : i64 (dot x))"
      "typecheck: defdispatch variant signatures must match")
    (compiler-typecheck-error-ok?
      "(defdispatch dot (scalar dot))
(define (main [x : i64]) : i64 (dot x))"
      "typecheck: defdispatch cannot use itself as a variant")
    (compiler-typecheck-error-ok?
      "(define (dot-scalar [x : i64]) : i64 x)
(defdispatch dot (scalar dot-scalar))
(defdispatch other (scalar dot))
(define (main [x : i64]) : i64 (other x))"
      "typecheck: defdispatch variant cannot be another dispatch")))

;; --- declaration namespace / duplicate diagnostics ---------------------------
;; Migrated from src/typechecker.rs namespace coverage. These flow through
;; build-compiler-symbols / build-compiler-registries during typechecking, so the
;; CI typecheck smoke exercises them. Builtin shadowing remains accepted to
;; match the Rust reference behavior.
(define (compiler-typecheck-dup-function-source) : String
  "(define (foo [x : i64]) : i64 x)
(define (foo [y : i64]) : i64 y)
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

(define (compiler-typecheck-dup-extern-paths) : ast.AstDeclPathList
  (ast.ast-decl-root-path-cons
    "src/main.tl"
    (ast.ast-decl-root-path-cons
      "src/assets.tl"
      (ast.ast-decl-root-path-cons "src/main.tl" (ast.ast-decl-path-list-new)))))

(define (compiler-typecheck-dup-extern-paths-ok?) : bool
  (match (parser.parse-ast-source (compiler-typecheck-dup-extern-source))
    [(Ok program)
      (match (tc_api.typecheck-compiler-program-with-paths
        program
        (compiler-typecheck-dup-extern-paths))
        [(Err diag)
          (let
            [value : cdiag.CompilerDiagnostic
              (cdiag.compiler-diagnostic-list-first (deref diag))]
            [message : String (cdiag.compiler-diagnostic-message value)]
            [duplicate-needle : String "symbols: duplicate value declaration f"]
            [main-path : String "src/main.tl"]
            [assets-path : String "src/assets.tl"]
            (and
              (string.contains (& message) (& duplicate-needle))
              (string.contains (& message) (& main-path))
              (string.contains (& message) (& assets-path))))]
        [(Ok _) false])]
    [(Err _) false]))

(define (compiler-typecheck-dup-function-paths-ok?) : bool
  (match (parser.parse-ast-source (compiler-typecheck-dup-function-source))
    [(Ok program)
      (match (tc_api.typecheck-compiler-program-with-paths
        program
        (compiler-typecheck-dup-extern-paths))
        [(Err diag)
          (let
            [value : cdiag.CompilerDiagnostic
              (cdiag.compiler-diagnostic-list-first (deref diag))]
            (and
              (string.contains
                (cdiag.compiler-diagnostic-message value)
                "symbols: duplicate value declaration foo")
              (string.eq (cdiag.compiler-diagnostic-path value) "src/assets.tl")
              (= (cdiag.compiler-diagnostic-line value) 2)
              (= (cdiag.compiler-diagnostic-col value) 31)))]
        [(Ok _) false])]
    [(Err _) false]))

(define (compiler-typecheck-dup-type-path-ok? [source : String] [name : String]) : bool
  (match (parser.parse-ast-source source)
    [(Ok program)
      (match (tc_api.typecheck-compiler-program-with-paths
        program
        (compiler-typecheck-dup-extern-paths))
        [(Err diag)
          (let
            [value : cdiag.CompilerDiagnostic
              (cdiag.compiler-diagnostic-list-first (deref diag))]
            (and
              (string.contains
                (cdiag.compiler-diagnostic-message value)
                (str_cat.str-cat "symbols: duplicate type declaration " name))
              (string.eq (cdiag.compiler-diagnostic-path value) "src/assets.tl")
              (= (cdiag.compiler-diagnostic-line value) 2)
              (= (cdiag.compiler-diagnostic-col value) 1)))]
        [(Ok _) false])]
    [(Err _) false]))

(define (compiler-typecheck-dup-type-paths-ok?) : bool
  (and
    (compiler-typecheck-dup-type-path-ok?
      (compiler-typecheck-dup-struct-type-source)
      "Point")
    (compiler-typecheck-dup-type-path-ok?
      (compiler-typecheck-dup-enum-type-source)
      "E")))

(define (compiler-typecheck-cleanup-repr-c-origin-ok?) : bool
  ;; Source syntax rejects this metadata combination earlier, so retain a real
  ;; parsed declaration origin and then construct the invalid semantic AST.
  (match (parser.parse-ast-source-diagnostic
    ""
    "
(defstruct Bad (:cleanup cleanup-bad) (fd i64))")
    [(Ok program)
      (match (ast.ast-global-shared-view program)
        [(Program decls-box)
          (let
            [decls : ast.AstDeclList
              (ast.ast-decl-list-box-shared-view decls-box)]
            [decl : ast.AstDecl
              (ast.ast-decl-list-get (& decls) 0 (ast.ast-decl-fallback))]
            (match decl
              [(DefStruct decl-meta name _ cleanup fields)
                (set!
                  (array-ref decls.slots decls.offset)
                  (ast.AstDecl.DefStruct
                    (ast.ast-decl-meta-runtime-shared-view)
                    name
                    (ast.ast-struct-repr-c)
                    cleanup
                    fields))
                (match (tc_api.typecheck-compiler-program program)
                  [(Err diag)
                    (let
                      [value : cdiag.CompilerDiagnostic
                        (cdiag.compiler-diagnostic-list-first (deref diag))]
                      (and
                        (string.eq
                          (cdiag.compiler-diagnostic-message value)
                          "typecheck: cleanup-owning struct Bad cannot use repr c")
                        (= (cdiag.compiler-diagnostic-line value) 2)
                        (= (cdiag.compiler-diagnostic-col value) 1)))]
                  [(Ok _) false])]
              [_ false]))])]
    [(Err _) false]))

(define (compiler-typecheck-imported-decl-origin-ok?) : bool
  (compiler-typecheck-write-text
    "target/tc_decl_origin_dep.tl"
    "(module tc_decl_origin_dep)
(extern (bad [arg0 : (Tuple i64 i64)]) : i64 (:abi c))")
  (compiler-typecheck-write-text
    "target/tc_decl_origin_entry.tl"
    "(module tc.decl_origin_entry)
(import tc_decl_origin_dep as dep)
(define (main) : i64 0)")
  (match (load_tests.compiler-load-file-with-paths
    "target/tc_decl_origin_entry.tl"
    (sym_i64_env.sym-i64-empty))
    [(Ok decls paths _ _)
      (match (tc_api.typecheck-compiler-program-with-paths
        (ast.ast-program decls)
        paths)
        [(Err diag)
          (let
            [value : cdiag.CompilerDiagnostic
              (cdiag.compiler-diagnostic-list-first (deref diag))]
            (and
              (string.eq
                (cdiag.compiler-diagnostic-message value)
                "typecheck: extern ABI c does not support parameter type (Tuple i64 i64)")
              (string.eq
                (cdiag.compiler-diagnostic-path value)
                "target/tc_decl_origin_dep.tl")
              (= (cdiag.compiler-diagnostic-line value) 2)
              (= (cdiag.compiler-diagnostic-col value) 1)))]
        [(Ok _) false])]
    [(Err _) false]))

(define (compiler-typecheck-semantic-diagnostic-spans-ok?) : bool
  (and
    (compiler-typecheck-error-location-ok?
      "(define (main [value : Missing]) : i64 0)"
      "typecheck: unknown type Missing; TypeLisp has no source-level type parameters; use comptime-generated concrete declarations instead"
      1
      1)
    (compiler-typecheck-error-location-ok?
      (compiler-typecheck-unknown-field-source)
      "typecheck: unknown struct field Point.z; available fields: x, y"
      3
      3)
    (compiler-typecheck-error-location-ok?
      (compiler-typecheck-unknown-variant-source)
      "typecheck: unknown variant Other"
      3
      13)
    (compiler-typecheck-error-location-ok?
      "(module main)
(unsafe (extern (bad [arg0 : (Tuple i64 i64)]) : i64 (:abi c)))"
      "typecheck: extern ABI c does not support parameter type (Tuple i64 i64)"
      2
      9)
    (compiler-typecheck-error-location-ok?
      "(defstruct RefBox (:lifetimes a a) (value (& a i64)))"
      "typecheck: duplicate lifetime parameter"
      1
      1)
    (compiler-typecheck-error-location-ok?
      "(module nested
  (defdispatch dot (avx2 dot-avx2)))"
      "typecheck: defdispatch requires exactly one scalar variant"
      2
      3)
    (compiler-typecheck-cleanup-repr-c-origin-ok?)
    (compiler-typecheck-imported-decl-origin-ok?)))

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
      "(define foo : i64 1)
(define (foo [x : i64]) : i64 x)
(define (main) : i64 0)"
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
    (compiler-typecheck-dup-function-paths-ok?)
    (compiler-typecheck-dup-type-paths-ok?)
    (compiler-typecheck-semantic-diagnostic-spans-ok?)
    (compiler-typecheck-error-ok?
      "(defenum A (Foo))
(define (Foo [x : i64]) : i64 x)"
      "symbols: duplicate value declaration Foo")
    (compiler-typecheck-error-ok?
      "(defenum A (Foo))
(define Foo : i64 42)"
      "symbols: duplicate value declaration Foo")
    (compiler-typecheck-error-ok?
      "(defenum A (Foo))
(extern (Foo [arg0 : i64]) : i64)"
      "symbols: duplicate value declaration Foo")
    (compiler-typecheck-error-ok?
      "(defenum A (Foo))
(defstruct Foo (x i64))"
      "symbols: duplicate value declaration Foo")
    (compiler-typecheck-error-ok?
      "(defstruct Point (x i64))
(define (Point [x : i64]) : i64 x)"
      "symbols: duplicate value declaration Point")
    (compiler-typecheck-error-ok?
      "(defstruct Point (x i64))
(define Point : i64 42)"
      "symbols: duplicate value declaration Point")
    (compiler-typecheck-error-ok?
      "(defstruct Point (x i64))
(extern (Point [arg0 : i64]) : i64)"
      "symbols: duplicate value declaration Point")
    (compiler-typecheck-ok?
      "(define (string.string-length [n : i64]) : i64 n)
(define (main) : i64 (string.string-length 7))")
    (compiler-typecheck-error-ok?
      "(module left)
(define (helper [x : i64]) : i64 x)
(module main)
(import left)
(define (main) : i64 (left.helper true))"
      "typecheck: call `left.helper` argument 1 type mismatch: expected i64, found bool")))

(define (compiler-typecheck-self-test-diagnostics) : unit
  (if (compiler-typecheck-namespace-tests-ok?)
    unit
    (io.panic "typecheck: declaration namespace tests failed"))
  (if (compiler-typecheck-defdispatch-tests-ok?)
    unit
    (io.panic "typecheck: defdispatch tests failed"))
  (if (compiler-typecheck-move-tests-ok?)
    unit
    (io.panic "typecheck: move checker tests failed"))
  (if (compiler-typecheck-let-obligation-tests-ok?)
    unit
    (io.panic "typecheck: let cleanup obligation tests failed"))
  (if (compiler-typecheck-live-borrow-tests-ok?)
    unit
    (io.panic "typecheck: live borrow checker tests failed"))
  (if (compiler-typecheck-param-storage-tests-ok?)
    unit
    (io.panic "typecheck: by-value parameter storage tests failed"))
  (if (compiler-typecheck-diagnostic-code-tests-ok?)
    unit
    (io.panic "typecheck: diagnostic code tests failed"))
  (if (compiler-typecheck-mismatch-detail-tests-ok?)
    unit
    (io.panic "typecheck: mismatch detail tests failed"))
  (if (compiler-typecheck-unop-diagnostic-tests-ok?)
    unit
    (io.panic "typecheck: unop diagnostic tests failed"))
  (if (compiler-typecheck-escape-diagnostic-tests-ok?)
    unit
    (io.panic "typecheck: escape diagnostic tests failed"))
  (if (compiler-typecheck-nested-expression-diagnostic-span-ok?)
    unit
    (io.panic "typecheck: nested expression diagnostic span test failed"))
  (if (compiler-typecheck-pool-exhaustion-diagnostic-ok?)
    unit
    (io.panic "typecheck: pool exhaustion diagnostic test failed"))
  (if (compiler-typecheck-prefix-cache-smoke-ok?)
    unit
    (io.panic "typecheck: prefix snapshot cache smoke test failed"))
  (if (compiler-typecheck-prefix-cache-stats-smoke-ok?)
    unit
    (io.panic "typecheck: prefix snapshot cache stats smoke test failed"))
  (if (compiler-typecheck-error-ok?
    "(define (main) : i64 missing)"
    "typecheck: unbound name missing")
    unit
    (io.panic "typecheck: unbound-name diagnostic test failed"))
  (if (compiler-typecheck-error-ok?
    (compiler-typecheck-bad-call-source)
    "typecheck: call `id` argument 1 (parameter `x`) type mismatch: expected i64, found bool")
    unit
    (io.panic "typecheck: bad-call diagnostic test failed"))
  (if (compiler-typecheck-error-ok?
    (compiler-typecheck-branch-mismatch-source)
    "typecheck: if branches must match")
    unit
    (io.panic "typecheck: branch mismatch diagnostic test failed"))
  unit)

(define (compiler-typecheck-self-test-models) : unit
  (if (compiler-typecheck-aggregate-tests-ok?)
    unit
    (io.panic "typecheck: aggregate tests failed"))
  (if (compiler-typecheck-clone-tests-ok?)
    unit
    (io.panic "typecheck: clone tests failed"))
  (if (compiler-typecheck-foreach-spmd-tests-ok?)
    unit
    (io.panic "typecheck: foreach/spmd tests failed"))
  (if (compiler-typecheck-nominal-tests-ok?)
    unit
    (io.panic "typecheck: nominal tests failed"))
  (if (compiler-typecheck-abstraction-policy-tests-ok?)
    unit
    (io.panic "typecheck: abstraction policy tests failed"))
  (if (compiler-typecheck-region-tests-ok?)
    unit
    (io.panic "typecheck: region tests failed"))
  (if (compiler-typecheck-with-escape-tests-ok?)
    unit
    (io.panic "typecheck: with-escape tests failed"))
  (if (compiler-typecheck-in-arena-tests-ok?)
    unit
    (io.panic "typecheck: in-arena tests failed"))
  (if (compiler-typecheck-owner-model-tests-ok?)
    unit
    (io.panic "typecheck: lifetime owner model tests failed"))
  (if (compiler-typecheck-box-tests-ok?)
    unit
    (io.panic "typecheck: box tests failed"))
  (if (compiler-typecheck-raw-deref-field-tests-ok?)
    unit
    (io.panic "typecheck: raw-pointer field place tests failed"))
  (if (compiler-typecheck-init-tests-ok?)
    unit
    (io.panic "typecheck: init tests failed"))
  (if (compiler-typecheck-result-try-tests-ok?)
    unit
    (io.panic "typecheck: result try tests failed"))
  (if (compiler-typecheck-move-kind-tests-ok?)
    unit
    (io.panic "typecheck: move-kind classifier tests failed"))
  (if (compiler-typecheck-function-store-fork-tests-ok?)
    unit
    (io.panic "typecheck: function-local environment fork tests failed"))
  (if (compiler-typecheck-resource-with-tests-ok?)
    unit
    (io.panic "typecheck: resource with tests failed"))
  (if (compiler-typecheck-cleanup-struct-tests-ok?)
    unit
    (io.panic "typecheck: cleanup struct metadata tests failed"))
  (if (compiler-typecheck-cleanup-enum-tests-ok?)
    unit
    (io.panic "typecheck: cleanup enum metadata tests failed"))
  (if (compiler-typecheck-raw-pointer-tests-ok?)
    unit
    (io.panic "typecheck: raw pointer type tests failed"))
  (if (compiler-typecheck-extern-abi-tests-ok?)
    unit
    (io.panic "typecheck: extern ABI signature tests failed"))
  (if (compiler-typecheck-reference-tests-ok?)
    unit
    (io.panic "typecheck: reference tests failed"))
  (if (compiler-typecheck-slice-borrowed-records-tests-ok?)
    unit
    (io.panic "typecheck: slice borrowed-record tests failed"))
  (if (compiler-typecheck-located-ok?)
    unit
    (io.panic "typecheck: located diagnostic test failed"))
  (if (compiler-typecheck-quote-tests-ok?)
    unit
    (io.panic "typecheck: quote tests failed"))
  unit)

;; Runtime stdlib signature + shadowing coverage (migrated from
;; src/typechecker.rs). `io.emit-string`/`emit-str`/`io.print-error` are stdlib
;; functions that borrow `str`; `xgetbv` takes an integer; `cpuid` takes
;; integers; `string.string-ref`/`char-at` require an integer index. A user declaration
;; may still define the same source-level name when no stdlib import brings it
;; into scope.
(define (compiler-typecheck-runtime-builtin-emit-string-ok-source) : String
  (compiler-typecheck-with-io-source
    "(define (main) : i64
  (begin
    (io.emit-string \"hi\")
    (io.emit-string (begin \"ignored\" \"temporary\"))
    0))"))

(define (compiler-typecheck-runtime-stdlib-no-import-tests-ok?) : bool
  (and
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (io.emit-int 1) 0))"
      "typecheck: unknown qualified name io.emit-int; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (io.emit-string \"hi\") 0))"
      "typecheck: unknown qualified name io.emit-string; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (io.emit-str \"hi\") 0))"
      "typecheck: unknown qualified name io.emit-str; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (emit-newline) 0))"
      "typecheck: unbound name emit-newline")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (io.emit-bool true) 0))"
      "typecheck: unknown qualified name io.emit-bool; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (io.emit-char 'A') 0))"
      "typecheck: unknown qualified name io.emit-char; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (io.emit-float 1.5) 0))"
      "typecheck: unknown qualified name io.emit-float; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (begin (io.print-error \"hi\") 0))"
      "typecheck: unknown qualified name io.print-error; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (io.panic \"stop\"))"
      "typecheck: unknown qualified name io.panic; import the module or use a visible dotted module alias")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (io.error \"stop\"))"
      "typecheck: unknown qualified name io.error; import the module or use a visible dotted module alias")))

(define (compiler-typecheck-runtime-builtin-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-runtime-builtin-emit-string-ok-source))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (main) : i64 (begin (io.emit-str \"hi\") 0))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (main) : i64 (begin (io.print-error \"hi\") 0))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        (compiler-typecheck-with-alloc-string-helper-source
          "(define (main) : i64
  (let
    [s : String (string.int->string 42)]
    (begin
      (io.emit-string s)
      (io.emit-str s)
      (io.print-error s)
      0)))")))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-cpu-source
        "(define (main) : i64 (begin (xgetbv 0) 0))"))
    (compiler-typecheck-ok?
      "(define (io.emit-string [x : i64]) : i64 x)
(define (main) : i64 (io.emit-string 5))")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source
        "(define (main) : i64 (begin (io.emit-string 42) 0))")
      "typecheck: borrow requires a local, parameter, or aggregate place")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source
        "(define (main) : i64 (begin (io.emit-str 42) 0))")
      "typecheck: borrow requires a local, parameter, or aggregate place")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source
        "(define (main) : i64 (begin (io.print-error 42) 0))")
      "typecheck: borrow requires a local, parameter, or aggregate place")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-cpu-source
        "(define (main) : i64 (begin (xgetbv \"x\") 0))")
      "typecheck: xgetbv index must be integer")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-cpu-source
        "(define (main) : i64 (begin (cpuid \"x\" 0) 0))")
      "typecheck: call `cpuid` argument 1 (parameter `leaf`) type mismatch: expected i64, found String")
    (compiler-typecheck-runtime-stdlib-no-import-tests-ok?)
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (__tl_string_ref \"abc\" \"x\"))"
      "typecheck: call `__tl_string_ref` argument 2 type mismatch: expected integer, found String")
    (compiler-typecheck-error-ok?
      "(define (main) : i64 (__tl_string_ref \"abc\" \"x\"))"
      "typecheck: call `__tl_string_ref` argument 2 type mismatch: expected integer, found String")))

(define (compiler-typecheck-panic-error-never-tests-ok?) : bool
  (and
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f [s : String]) : i64 (io.panic s))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f [s : String]) : i64 (io.panic s))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f [s : String]) : i64 (io.error s))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f [s : String]) : i64 (io.error s))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f [flag : bool]) : i64 (if flag 42 (io.panic \"stop\")))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f [flag : bool]) : String (if flag \"ok\" (io.error \"stop\")))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(defenum Choice (Left) (Right))
(define (f [c : Choice]) : i64 (match c [(Left) (io.panic \"left\")] [(Right) 7]))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(defenum Choice (Left) (Right))
(define (f [c : Choice]) : String (match c [(Left) \"ok\"] [(Right) (io.error \"right\")]))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f) : unit (begin (io.panic \"stop\") unit))"))
    (compiler-typecheck-ok?
      (compiler-typecheck-with-io-source
        "(define (f) : unit (begin (io.error \"stop\")))"))
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source "(define (f) : i64 (io.panic))")
      "typecheck: call arity mismatch: io.panic expected 1 argument, got 0 arguments")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source
        "(define (f) : i64 (io.error \"a\" \"b\"))")
      "typecheck: call arity mismatch: io.error expected 1 argument, got 2 arguments")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source "(define (f) : i64 (io.panic 5))")
      "typecheck: borrow requires a local, parameter, or aggregate place")
    (compiler-typecheck-error-ok?
      (compiler-typecheck-with-io-source "(define (f) : i64 (io.error true))")
      "typecheck: borrow requires a local, parameter, or aggregate place")))

(define (compiler-typecheck-profile-no-default-tests-ok?) : bool
  (compiler-typecheck-error-ok?
    "(define (main) : i64 (profile-now-ms))"
    "typecheck: unbound name profile-now-ms"))

(define (compiler-typecheck-self-test-builtins) : unit
  (if (compiler-typecheck-runtime-builtin-tests-ok?)
    unit
    (io.panic "typecheck: runtime builtin tests failed"))
  (if (compiler-typecheck-profile-no-default-tests-ok?)
    unit
    (io.panic "typecheck: profile helpers should require stdlib import"))
  (if (compiler-typecheck-panic-error-never-tests-ok?)
    unit
    (io.panic "typecheck: panic/error never-context tests failed"))
  (if (compiler-typecheck-string-builtin-tests-ok?)
    unit
    (io.panic "typecheck: string builtin tests failed"))
  (if (compiler-typecheck-argv-builtin-tests-ok?)
    unit
    (io.panic "typecheck: argv builtin tests failed"))
  (if (compiler-typecheck-lambda-tests-ok?)
    unit
    (io.panic "typecheck: lambda tests failed"))
  (if (compiler-typecheck-cast-tests-ok?)
    unit
    (io.panic "typecheck: cast tests failed"))
  (if (compiler-typecheck-comptime-tests-ok?)
    unit
    (io.panic "typecheck: comptime tests failed"))
  (if (compiler-typecheck-type-literal-tests-ok?)
    unit
    (io.panic "typecheck: type-literal tests failed"))
  (if (compiler-typecheck-io-builtin-tests-ok?)
    unit
    (io.panic "typecheck: io builtin tests failed"))
  (if (compiler-typecheck-reflection-tests-ok?)
    unit
    (io.panic "typecheck: comptime reflection tests failed"))
  (if (compiler-typecheck-macro-generated-decl-tests-ok?)
    unit
    (io.panic "typecheck: macro generated-declaration tests failed"))
  (if (compiler-typecheck-layout-query-tests-ok?)
    unit
    (io.panic "typecheck: layout query tests failed"))
  (if (compiler-typecheck-defmacro-tests-ok?)
    unit
    (io.panic "typecheck: defmacro tests failed"))
  (if (compiler-typecheck-macro-expand-tests-ok?)
    unit
    (io.panic "typecheck: macro expansion tests failed")))

(define (compiler-typecheck-self-test) : i64
  (if (compiler-typecheck-lazy-table-storage-ok?)
    unit
    (io.panic "typecheck: lazy global table storage test failed"))
  (if (compiler-typecheck-inlay-hint-state-isolation-ok?)
    unit
    (io.panic "typecheck: inlay hint state isolation test failed"))
  (if (compiler-typecheck-inlay-hint-serial-adapters-ok?)
    unit
    (io.panic "typecheck: inlay hint serial adapters test failed"))
  (compiler-typecheck-self-test-basics)
  (compiler-typecheck-self-test-diagnostics)
  (compiler-typecheck-self-test-models)
  (compiler-typecheck-self-test-builtins)
  42)