;; Test-only coverage for persistent typechecker list storage.
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
      (tc_core.tc-string-list-cons string-root "base")]
    ;; Retain the parent while extending two siblings. Both dense snapshots
    ;; share one append-only store, but neither tail may leak into the other.
    [string-left : tc_core.TcStringList
      (tc_core.tc-string-list-cons string-base "left")]
    [string-right : tc_core.TcStringList
      (tc_core.tc-string-list-cons string-base "right")]
    [string-deep : tc_core.TcStringList
      (tc_core.tc-string-list-cons
        (tc_core.tc-string-list-cons tc_core.TcStringList.Nil "deep-root")
        "deep-base")]
    [name-base : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-cons
        (tc_core.tc-name-id-list-cons tc_core.TcNameIdList.Nil 10)
        20)]
    [name-right : tc_core.TcNameIdList
      (tc_core.tc-name-id-list-cons name-base 30)]
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
    [set-superset : tc_core.TcNameIdList (tc_core.tc-name-id-list-add set-b 3)]
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
      (unsafe
        (arena.set! scratch))
      (set!
        scratch-child
        (tc_core.tc-string-list-cons
          string-base
          (string.append "scratch-" "owned")))
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
              (tc_core.tc-string-list-cons string-base "sibling"))
            unit)
          (set! index (+ index 1))))
      (and
        (= (tc_core.tc-string-list-len string-root) 1)
        (= (tc_core.tc-string-list-len string-base) 2)
        (= (tc_core.tc-string-list-len string-left) 3)
        (= (tc_core.tc-string-list-len string-right) 3)
        (= (tc_core.tc-string-list-len growth-sibling) 3)
        (= (tc_core.tc-string-list-len string-deep) 258)
        (string.eq (tc_core.tc-string-list-head string-left) "left")
        (string.eq (tc_core.tc-string-list-head string-right) "right")
        (string.eq (tc_core.tc-string-list-head scratch-child) "scratch-owned")
        (string.eq
          (tc_core.tc-string-list-head
            (tc_core.tc-string-list-rest string-left))
          "base")
        (tc_core.tc-string-list-contains string-left "root")
        (not (tc_core.tc-string-list-contains string-left "right"))
        (tc_core.tc-name-id-list-eq set-a set-b)
        ;; Preserve the historical left-membership behavior of this predicate.
        (tc_core.tc-name-id-list-eq set-a set-superset)
        (not (tc_core.tc-name-id-list-eq set-superset set-a))
        (not (tc_core.tc-name-id-list-eq tc_core.TcNameIdList.Nil set-a))
        (=
          (tc_core.tc-name-id-list-len (tc_core.tc-name-id-list-add set-a 2))
          2)
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
          [(tc_core.TcStringList.Dense left-address _ _)
            (match string-right
              [(tc_core.TcStringList.Dense right-address _ _)
                (= left-address right-address)]
              [_ false])]
          [_ false])
        (match name-right
          [(tc_core.TcNameIdList.Dense right-address _ _)
            (match name-sibling
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
              (string.append
                macro-params
                (string.append " [m" (string.append suffix " : Expr]"))))
            (set!
              function-params
              (string.append
                function-params
                (string.append " [p" (string.append suffix " : i64]"))))
            (set! args (string.append args (string.append " " suffix)))
            (set! index (+ index 1)))))
      (let
        [last : String (string.int->string (- count 1))]
        (string.append
          "(defmacro (wide-macro"
          (string.append
            macro-params
            (string.append
              ") : Expr m"
              (string.append
                last
                (string.append
                  ")\n(define (wide-fn"
                  (string.append
                    function-params
                    (string.append
                      ") : i64 p"
                      (string.append
                        last
                        (string.append
                          ")\n(define (sibling [flag : bool]) : i64\n  (let [outer : i64 1]\n    (+ outer (if flag (let [left : i64 2] left) (let [right : i64 3] right)))))\n(define (main) : i64\n  (+ (sibling true)\n    (+ (wide-fn"
                          (string.append
                            args
                            (string.append
                              ")\n      (wide-macro"
                              (string.append args "))))"))))))))))))))))

(define (compiler-typecheck-wide-list-storage-ok?) : bool
  (match (tc_api.typecheck-compiler-source
    (compiler-typecheck-wide-list-storage-source 256))
    [(tc_core.ResultCompilerTypecheck.Ok _) true]
    [(tc_core.ResultCompilerTypecheck.Err diagnostics)
      (begin
        (io.print-error
          (diagnostic.compiler-diagnostic-message
            (diagnostic.compiler-diagnostic-list-first (box-get diagnostics))))
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