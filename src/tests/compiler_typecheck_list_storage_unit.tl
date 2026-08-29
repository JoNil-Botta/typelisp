;; Test-only coverage for persistent typechecker list storage.
(import stdlib.str_cat_runtime as str_cat)
(import compiler_typecheck_core as tc_core)
(import compiler_typecheck_api as tc_api)
(import compiler_diagnostic as diagnostic)
(import stdlib.arena)
(import stdlib.io)
(import stdlib.string)

(define (compiler-typecheck-list-storage-unit-tests-ok?) : bool
  (let
    [string-root : tc_core.TcStringList
      (tc_core.tc-string-list-cons tc_core.TcStringList.Nil "root")]
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
        (tc_core.tc-string-list-cons tc_core.TcStringList.Nil "deep-root")
        "deep-base")]
    [name-base : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-cons
        (tc_core.tc-name-id-list-cons tc_core.TcNameIdList.Nil 10)
        20)]
    [name-right : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-cons
        (tc_core.tc-global-shared-view name-base)
        30)]
    [name-sibling : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-cons name-base 40)]
    [set-a : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-add
        (tc_core.tc-name-id-list-add tc_core.TcNameIdList.Nil 1)
        2)]
    [set-b : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-add
        (tc_core.tc-name-id-list-add tc_core.TcNameIdList.Nil 2)
        1)]
    [set-superset : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-add (tc_core.tc-global-shared-view set-b) 3)]
    [home : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    [scratch-child : tc_core.TcStringList tc_core.TcStringList.Nil]
    [growth-sibling : tc_core.TcStringList tc_core.TcStringList.Nil]
    [deep : tc_core.TcNameIdList tc_core.TcNameIdList.Nil]
    [index : i64 0]
    (begin
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
        (begin
          (arena.set! home)
          (arena.destroy scratch)))
      (while (< index 4096)
        (begin
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
          (set! index (+ index 1))))
      (and
        (=
          (tc_core.tc-string-list-len
            (tc_core.tc-global-shared-view string-root))
          1)
        (=
          (tc_core.tc-string-list-len
            (tc_core.tc-global-shared-view string-base))
          2)
        (=
          (tc_core.tc-string-list-len
            (tc_core.tc-global-shared-view string-left))
          3)
        (=
          (tc_core.tc-string-list-len
            (tc_core.tc-global-shared-view string-right))
          3)
        (= (tc_core.tc-string-list-len growth-sibling) 3)
        (= (tc_core.tc-string-list-len string-deep) 258)
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
        (tc_core.tc-name-id-list-eq
          (tc_core.tc-global-shared-view set-a)
          (tc_core.tc-global-shared-view set-b))
        ;; Preserve the historical left-membership behavior of this predicate.
        (tc_core.tc-name-id-list-eq
          (tc_core.tc-global-shared-view set-a)
          (tc_core.tc-global-shared-view set-superset))
        (not
          (tc_core.tc-name-id-list-eq
            (tc_core.tc-global-shared-view set-superset)
            (tc_core.tc-global-shared-view set-a)))
        (not
          (tc_core.tc-name-id-list-eq
            tc_core.TcNameIdList.Nil
            (tc_core.tc-global-shared-view set-a)))
        (=
          (tc_core.tc-name-id-list-len
            (tc_core.tc-name-id-list-add
              (tc_core.tc-global-shared-view set-a)
              2))
          2)
        (tc_core.tc-name-id-list-overlaps?
          (tc_core.tc-global-shared-view name-right)
          (tc_core.tc-global-shared-view name-sibling))
        (not
          (tc_core.tc-name-id-list-contains
            (tc_core.tc-global-shared-view name-right)
            40))
        (tc_core.tc-name-id-list-contains
          (tc_core.tc-global-shared-view name-sibling)
          40)
        (=
          (tc_core.tc-name-id-list-len (tc_core.tc-global-shared-view deep))
          4096)
        (=
          (tc_core.tc-name-id-list-head (tc_core.tc-global-shared-view deep))
          4095)
        (=
          (tc_core.tc-name-id-list-head
            (tc_core.tc-name-id-list-rest (tc_core.tc-global-shared-view deep)))
          4094)
        (tc_core.tc-name-id-list-contains
          (tc_core.tc-global-shared-view deep)
          0)
        (match (tc_core.tc-global-shared-view string-left)
          [(tc_core.TcStringList.Dense left-address _ _)
            (match (tc_core.tc-global-shared-view string-right)
              [(tc_core.TcStringList.Dense right-address _ _)
                (= left-address right-address)]
              [_ false])]
          [_ false])
        (match (tc_core.tc-global-shared-view name-right)
          [(tc_core.TcNameIdList.Dense right-address _ _)
            (match (tc_core.tc-global-shared-view name-sibling)
              [(tc_core.TcNameIdList.Dense sibling-address _ _)
                (= right-address sibling-address)]
              [_ false])]
          [_ false])))))

(define (compiler-typecheck-wide-list-storage-source [count : i64]) : String
  (let
    [macro-params : String ""]
    [function-params : String ""]
    [args : String ""]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [suffix : String (string.int->string index)]
          (begin
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
            (set! index (+ index 1)))))
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
          "))))")))))

(define (compiler-typecheck-wide-list-storage-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    (compiler-typecheck-wide-list-storage-source 256))
    [(tc_core.ResultCompilerTypecheck.Ok _) true]
    [(tc_core.ResultCompilerTypecheck.Err diagnostics)
      (let
        [diag : diagnostic.CompilerDiagnostic
          (diagnostic.compiler-diagnostic-list-first
            (diagnostic.compiler-diagnostic-list-box-shared-view diagnostics))]
        (begin
          (io.print-error (diagnostic.compiler-diagnostic-message diag))
          false))]))

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