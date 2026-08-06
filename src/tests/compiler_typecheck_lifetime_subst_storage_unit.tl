;; Test-only coverage for persistent lifetime-substitution storage.
(import compiler_typecheck_core as tc_core)
(import compiler_ast_types as ast)
(import stdlib.io)
(import stdlib.string)

(define (tc-lifetime-subst-must-bind
  [subst : tc_core.TcLifetimeSubst]
  [from : i64]
  [to : i64]) : tc_core.TcLifetimeSubst
  (match (tc_core.tc-lifetime-subst-bind subst from to)
    [(tc_core.ResultTcLifetimeSubst.Ok next) next]
    [(tc_core.ResultTcLifetimeSubst.Err message) (io.panic message)]))

(define (tc-lifetime-subst-lookup-eq?
  [subst : tc_core.TcLifetimeSubst]
  [from : i64]
  [to : i64]) : bool
  (match (tc_core.tc-lifetime-subst-lookup subst from)
    [(tc_core.TcMaybeNameId.Some actual) (= actual to)]
    [(tc_core.TcMaybeNameId.No) false]))

(define (tc-lifetime-subst-lookup-missing?
  [subst : tc_core.TcLifetimeSubst]
  [from : i64]) : bool
  (match (tc_core.tc-lifetime-subst-lookup subst from)
    [(tc_core.TcMaybeNameId.Some _) false]
    [(tc_core.TcMaybeNameId.No) true]))

(define (tc-lifetime-subst-build [count : i64] [reverse? : bool]) : tc_core.TcLifetimeSubst
  (let
    [subst : tc_core.TcLifetimeSubst tc_core.TcLifetimeSubst.Nil]
    [index : i64 0]
    (begin
      (while (< index count)
        (let
          [from : i64
            (if reverse?
              (- (- count index) 1)
              index)]
          (begin
            (set!
              subst
              (tc-lifetime-subst-must-bind subst from (+ from 100000)))
            (set! index (+ index 1)))))
      subst)))

(define (tc-lifetime-subst-wide-and-order-ok?) : bool
  (let
    [count : i64 2048]
    [forward : tc_core.TcLifetimeSubst (tc-lifetime-subst-build count false)]
    [reverse : tc_core.TcLifetimeSubst (tc-lifetime-subst-build count true)]
    [index : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< index count))
        (begin
          (if (and
            (tc-lifetime-subst-lookup-eq? forward index (+ index 100000))
            (tc-lifetime-subst-lookup-eq? reverse index (+ index 100000)))
            unit
            (set! ok false))
          (set! index (+ index 1))))
      (and
        ok
        (= (tc_core.tc-lifetime-subst-len forward) count)
        (= (tc_core.tc-lifetime-subst-len reverse) count)))))

(define (tc-lifetime-subst-list-ok?) : bool
  (let
    [subst : tc_core.TcLifetimeSubst
      (tc-lifetime-subst-must-bind
        (tc-lifetime-subst-must-bind tc_core.TcLifetimeSubst.Nil 1 101)
        3
        103)]
    [input : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
    (begin
      (ast.ast-lifetime-list-push (&mut input) 1)
      (ast.ast-lifetime-list-push (&mut input) 2)
      (ast.ast-lifetime-list-push (&mut input) 3)
      (let
        [output : ast.AstLifetimeList
          (tc_core.tc-lifetime-subst-list subst input)]
        (and
          (= (ast.ast-lifetime-list-len (& output)) 3)
          (= (ast.ast-lifetime-list-get (& output) 0 -1) 101)
          (= (ast.ast-lifetime-list-get (& output) 1 -1) 2)
          (= (ast.ast-lifetime-list-get (& output) 2 -1) 103))))))

(define (tc-lifetime-subst-storage-ok?) : bool
  (let
    [one : tc_core.TcLifetimeSubst
      (tc-lifetime-subst-must-bind tc_core.TcLifetimeSubst.Nil 10 110)]
    [root : tc_core.TcLifetimeSubst (tc-lifetime-subst-must-bind one 20 120)]
    ;; Retain the shared root while extending two siblings. The append-only
    ;; store may be shared, but neither sibling's tail may leak into the other.
    [left : tc_core.TcLifetimeSubst (tc-lifetime-subst-must-bind root 30 130)]
    [right : tc_core.TcLifetimeSubst (tc-lifetime-subst-must-bind root 40 140)]
    [duplicate : tc_core.TcLifetimeSubst
      (tc-lifetime-subst-must-bind left 30 130)]
    (and
      (= (tc_core.tc-lifetime-subst-len tc_core.TcLifetimeSubst.Nil) 0)
      (= (tc_core.tc-lifetime-subst-len one) 1)
      (= (tc_core.tc-lifetime-subst-len root) 2)
      (= (tc_core.tc-lifetime-subst-len left) 3)
      (= (tc_core.tc-lifetime-subst-len right) 3)
      (tc-lifetime-subst-lookup-eq? root 10 110)
      (tc-lifetime-subst-lookup-eq? root 20 120)
      (tc-lifetime-subst-lookup-missing? root 30)
      (tc-lifetime-subst-lookup-missing? root 40)
      (tc-lifetime-subst-lookup-eq? left 30 130)
      (tc-lifetime-subst-lookup-missing? left 40)
      (tc-lifetime-subst-lookup-eq? right 40 140)
      (tc-lifetime-subst-lookup-missing? right 30)
      (match left
        [(tc_core.TcLifetimeSubst.Dense left-address left-tail left-len)
          (match right
            [(tc_core.TcLifetimeSubst.Dense right-address _ _)
              (and
                (= left-address right-address)
                (match duplicate
                  [(tc_core.TcLifetimeSubst.Dense
                      duplicate-address
                      duplicate-tail
                      duplicate-len)
                    (and
                      (= duplicate-address left-address)
                      (= duplicate-tail left-tail)
                      (= duplicate-len left-len))]
                  [_ false]))]
            [_ false])]
        [_ false])
      (match (tc_core.tc-lifetime-subst-bind left 30 999)
        [(tc_core.ResultTcLifetimeSubst.Ok _) false]
        [(tc_core.ResultTcLifetimeSubst.Err message)
          (string.eq message "typecheck: constructor lifetime mismatch")])
      (tc-lifetime-subst-list-ok?)
      (tc-lifetime-subst-wide-and-order-ok?))))

(test
  compiler-typecheck-lifetime-subst-storage
  (unless
    (tc-lifetime-subst-storage-ok?)
    (io.panic "typecheck: dense lifetime-substitution storage failed")))