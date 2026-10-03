;; Test-only coverage for persistent typechecker list storage.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_typecheck_core as tc_core)
(import compiler_typecheck_api as tc_api)
(import compiler_diagnostic as diagnostic)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)

(define (tc-string-list-len [items : tc_core.TcStringList]) : i64
  (match items
    [(Nil) 0]
    [(One _) 1]
    [(Dense _ _ len) len]))

(define (compiler-typecheck-list-storage-unit-tests-ok?) : bool
  (let
    [string-root : tc_core.TcStringList
      (tc_core.tc-string-list-cons Nil "root")]
    [string-base : tc_core.TcStringList
      (tc_core.tc-string-list-cons
        (tc_core.tc-global-shared-view string-root)
        "base")]
    ;; Retain the parent while extending two siblings. Both dense snapshots
    ;; share one append-only store, but neither tail may leak into the other.
    [string-left : tc_core.TcStringList
      (tc_core.tc-string-list-cons
        (tc_core.tc-global-shared-view string-base)
        "left")]
    [string-right : tc_core.TcStringList
      (tc_core.tc-string-list-cons
        (tc_core.tc-global-shared-view string-base)
        "right")]
    [string-deep : tc_core.TcStringList
      (tc_core.tc-string-list-cons
        (tc_core.tc-string-list-cons Nil "deep-root")
        "deep-base")]
    [name-base : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-cons (tc_core.tc-name-id-list-cons Nil 10) 20)]
    [name-right : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-cons name-base 30)]
    [name-sibling : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-cons name-base 40)]
    [set-a : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-add (tc_core.tc-name-id-list-add Nil 1) 2)]
    [set-b : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-add (tc_core.tc-name-id-list-add Nil 2) 1)]
    [set-superset : tc_core.TcNameIdList (tc_core.tc-name-id-list-add set-b 3)]
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [scratch-child : tc_core.TcStringList Nil]
    [growth-sibling : tc_core.TcStringList Nil]
    [deep : tc_core.TcNameIdList Nil]
    [index : i64 0]
    ;; Append a scratch-owned string to an outer store, discard the scratch,
    ;; then grow through unrelated siblings. The retained child must keep its
    ;; owner-arena copy rather than a stale source pointer.
    ;; Keep the manual arena protocol here: the checker cannot express that
    ;; `tc-string-list-cons` returns storage copied into its persistent store,
    ;; and this test specifically verifies that ownership boundary after the
    ;; source arena is destroyed.
    (unsafe
      (arena.set! scratch))
    (set!
      scratch-child
      (tc_core.tc-string-list-cons
        (tc_core.tc-global-shared-view string-base)
        (str_cat.str-cat "scratch-" "owned")))
    (unsafe
      (arena.set! home)
      (arena.destroy scratch))
    (while (< index 4096)
      (set! deep (tc_core.tc-name-id-list-cons deep index))
      (if (< index 256)
        (set! string-deep (tc_core.tc-string-list-cons string-deep "deep"))
        unit)
      (if (< index 16)
        (set!
          growth-sibling
          (tc_core.tc-string-list-cons
            (tc_core.tc-global-shared-view string-base)
            "sibling"))
        unit)
      (set! index (+ index 1)))
    (and
      (= (tc-string-list-len string-root) 1)
      (= (tc-string-list-len string-base) 2)
      (= (tc-string-list-len (tc_core.tc-global-shared-view string-left)) 3)
      (= (tc-string-list-len (tc_core.tc-global-shared-view string-right)) 3)
      (= (tc-string-list-len growth-sibling) 3)
      (= (tc-string-list-len string-deep) 258)
      (string.eq
        (tc_core.tc-string-list-head
          (tc_core.tc-global-shared-view string-left))
        "left")
      (string.eq
        (tc_core.tc-string-list-head
          (tc_core.tc-global-shared-view string-right))
        "right")
      (string.eq (tc_core.tc-string-list-head scratch-child) "scratch-owned")
      (string.eq
        (tc_core.tc-string-list-head
          (tc_core.tc-string-list-rest
            (tc_core.tc-global-shared-view string-left)))
        "base")
      (tc_core.tc-string-list-contains
        (tc_core.tc-global-shared-view string-left)
        "root")
      (not
        (tc_core.tc-string-list-contains
          (tc_core.tc-global-shared-view string-left)
          "right"))
      (tc_core.tc-name-id-list-eq set-a set-b)
      ;; Preserve the historical left-membership behavior of this predicate.
      (tc_core.tc-name-id-list-eq set-a set-superset)
      (not (tc_core.tc-name-id-list-eq set-superset set-a))
      (not (tc_core.tc-name-id-list-eq Nil set-a))
      (= (tc_core.tc-name-id-list-len (tc_core.tc-name-id-list-add set-a 2)) 2)
      (tc_core.tc-name-id-list-overlaps? name-right name-sibling)
      (not (tc_core.tc-name-id-list-contains name-right 40))
      (tc_core.tc-name-id-list-contains name-sibling 40)
      (= (tc_core.tc-name-id-list-len deep) 4096)
      (= (tc_core.tc-name-id-list-head deep) 4095)
      (=
        (tc_core.tc-name-id-list-head (tc_core.tc-name-id-list-rest deep))
        4094)
      (tc_core.tc-name-id-list-contains deep 0)
      (match string-left
        [(Dense left-address _ _)
          (match string-right
            [(Dense right-address _ _) (= left-address right-address)]
            [_ false])]
        [_ false])
      (match name-right
        [(Dense right-address _ _)
          (match name-sibling
            [(Dense sibling-address _ _) (= right-address sibling-address)]
            [_ false])]
        [_ false]))))

(define (compiler-typecheck-wide-list-storage-source [count : i64]) : String
  (let
    [macro-params : String ""]
    [function-params : String ""]
    [args : String ""]
    [index : i64 0]
    (while (< index count)
      (let
        [suffix : String (string.int->string index)]
        (set!
          macro-params
          (str_cat.str-cat
            macro-params
            " [m"
            (tc_core.tc-global-shared-view suffix)
            " : Expr]"))
        (set!
          function-params
          (str_cat.str-cat
            function-params
            " [p"
            (tc_core.tc-global-shared-view suffix)
            " : i64]"))
        (set! args (str_cat.str-cat args " " suffix))
        (set! index (+ index 1))))
    (let
      [last : String (string.int->string (- count 1))]
      (str_cat.str-cat
        "(defmacro (wide-macro"
        macro-params
        ") : Expr m"
        (tc_core.tc-global-shared-view last)
        ")\n(define (wide-fn"
        function-params
        ") : i64 p"
        last
        ")\n(define (sibling [flag : bool]) : i64\n  (let [outer : i64 1]\n    (+ outer (if flag (let [left : i64 2] left) (let [right : i64 3] right)))))\n(define (main) : i64\n  (+ (sibling true)\n    (+ (wide-fn"
        (tc_core.tc-global-shared-view args)
        ")\n      (wide-macro"
        args
        "))))"))))

(define (compiler-typecheck-wide-list-storage-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    (compiler-typecheck-wide-list-storage-source 256))
    [(Ok _) true]
    [(Err diagnostics)
      (let
        [diag : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first (deref diagnostics))]
        (io.print-error (diagnostic.compiler-diagnostic-message diag))
        false)]))

(test
  compiler-typecheck-wide-list-storage
  (unless
    (compiler-typecheck-wide-list-storage-ok?)
    (io.panic "typecheck: wide dense-list storage stress failed")))

(test
  compiler-typecheck-dense-list-storage
  (unless
    (compiler-typecheck-list-storage-unit-tests-ok?)
    (io.panic "typecheck: dense list storage unit tests failed")))