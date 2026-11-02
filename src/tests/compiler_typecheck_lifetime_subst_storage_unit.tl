;; Test-only coverage for persistent lifetime-substitution storage.
(import stdlib.iterator)
(import compiler_typecheck_core as tc_core)
(import compiler_ast_types as ast)
(import stdlib.io)
(import stdlib.string)
(import compiler_diagnostic as cdiag)

(define (tc-lifetime-subst-must-bind
  [subst : tc_core.TcLifetimeSubst]
  [from : i64]
  [to : i64]) : tc_core.TcLifetimeSubst
  (match (tc_core.tc-lifetime-subst-bind subst from to)
    [(Ok next) next]
    [(Err message) (io.panic message)]))

(define (tc-lifetime-subst-lookup-eq?
  [subst : tc_core.TcLifetimeSubst]
  [from : i64]
  [to : i64]) : bool
  (match (tc_core.tc-lifetime-subst-lookup subst from)
    [(Some actual) (= actual to)]
    [(No) false]))

(define (tc-lifetime-subst-lookup-missing?
  [subst : tc_core.TcLifetimeSubst]
  [from : i64]) : bool
  (match (tc_core.tc-lifetime-subst-lookup subst from)
    [(Some _) false]
    [(No) true]))

(define (tc-lifetime-subst-build [count : i64] [reverse? : bool]) : tc_core.TcLifetimeSubst
  (let
    [subst : tc_core.TcLifetimeSubst Nil]
    (for [index (iterator.range 0 count)]
      (let
        [from : i64
          (if reverse?
            (- (- count index) 1)
            index)]
        (set! subst (tc-lifetime-subst-must-bind subst from (+ from 100000)))))
    subst))

(define (tc-lifetime-subst-len [subst : tc_core.TcLifetimeSubst]) : i64
  (match subst
    [(Nil) 0]
    [(One _ _) 1]
    [(Dense _ _ len) len]))

(define (tc-lifetime-subst-wide-and-order-ok?) : bool
  (let
    [count : i64 2048]
    [forward : tc_core.TcLifetimeSubst (tc-lifetime-subst-build count false)]
    [reverse : tc_core.TcLifetimeSubst (tc-lifetime-subst-build count true)]
    [index : i64 0]
    [ok : bool true]
    (while (and ok (< index count))
      (if (and
        (tc-lifetime-subst-lookup-eq? forward index (+ index 100000))
        (tc-lifetime-subst-lookup-eq? reverse index (+ index 100000)))
        unit
        (set! ok false))
      (+= index 1))
    (and
      ok
      (= (tc-lifetime-subst-len forward) count)
      (= (tc-lifetime-subst-len reverse) count))))

(define (tc-lifetime-subst-list-ok?) : bool
  (let
    [subst : tc_core.TcLifetimeSubst
      (tc-lifetime-subst-must-bind
        (tc-lifetime-subst-must-bind Nil 1 101)
        3
        103)]
    [input : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
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
        (= (ast.ast-lifetime-list-get (& output) 2 -1) 103)))))

;; An empty substitution renames nothing, so each entry point returns its input:
;; the same lifetimes and the same child type ids, with no rebuilt nodes.
(define (tc-lifetime-subst-nil-identity-ok?) : bool
  (let
    [lifetimes : ast.AstLifetimeList (ast.ast-lifetime-list-new)]
    [ref-id : i64 (ast.ty-node-push (& (ast.ast-ty-ref 7 (& (String)))))]
    [ret-id : i64 (ast.ty-node-push (& (ast.ast-ty-mut-ref 8 (& (I64)))))]
    [types : ast.AstTypeList (ast.ast-type-list-new)]
    [fn-args : ast.AstTypeList (ast.ast-type-list-new)]
    (ast.ast-lifetime-list-push (&mut lifetimes) 7)
    (ast.ast-lifetime-list-push (&mut lifetimes) 8)
    (ast.ast-type-list-push (&mut types) ref-id)
    (ast.ast-type-list-push (&mut types) ret-id)
    (ast.ast-type-list-push (&mut fn-args) ref-id)
    (let
      [same-lifetimes : ast.AstLifetimeList
        (tc_core.tc-lifetime-subst-list Nil lifetimes)]
      [same-types : ast.AstTypeList
        (tc_core.tc-lifetime-subst-type-list Nil types)]
      (and
        (= (ast.ast-lifetime-list-len (& same-lifetimes)) 2)
        (= (ast.ast-lifetime-list-get (& same-lifetimes) 0 -1) 7)
        (= (ast.ast-lifetime-list-get (& same-lifetimes) 1 -1) 8)
        (= (ast.ast-type-list-len (& same-types)) 2)
        (= (ast.ast-type-list-get (& same-types) 0 -1) ref-id)
        (= (ast.ast-type-list-get (& same-types) 1 -1) ret-id)
        (match (tc_core.tc-lifetime-subst-type
          Nil
          (ast.AstType.Func (box fn-args) ret-id))
          [(Func _ ret) (= ret ret-id)]
          [_ false])))))

(define (tc-lifetime-subst-storage-ok?) : bool
  (let
    [one : tc_core.TcLifetimeSubst (tc-lifetime-subst-must-bind Nil 10 110)]
    [root : tc_core.TcLifetimeSubst (tc-lifetime-subst-must-bind one 20 120)]
    ;; Retain the shared root while extending two siblings. The append-only
    ;; store may be shared, but neither sibling's tail may leak into the other.
    [left : tc_core.TcLifetimeSubst (tc-lifetime-subst-must-bind root 30 130)]
    [right : tc_core.TcLifetimeSubst (tc-lifetime-subst-must-bind root 40 140)]
    [duplicate : tc_core.TcLifetimeSubst
      (tc-lifetime-subst-must-bind left 30 130)]
    (and
      (= (tc-lifetime-subst-len Nil) 0)
      (= (tc-lifetime-subst-len one) 1)
      (= (tc-lifetime-subst-len root) 2)
      (= (tc-lifetime-subst-len left) 3)
      (= (tc-lifetime-subst-len right) 3)
      (tc-lifetime-subst-lookup-eq? root 10 110)
      (tc-lifetime-subst-lookup-eq? root 20 120)
      (tc-lifetime-subst-lookup-missing? root 30)
      (tc-lifetime-subst-lookup-missing? root 40)
      (tc-lifetime-subst-lookup-eq? left 30 130)
      (tc-lifetime-subst-lookup-missing? left 40)
      (tc-lifetime-subst-lookup-eq? right 40 140)
      (tc-lifetime-subst-lookup-missing? right 30)
      (match left
        [(Dense left-address left-tail left-len)
          (match right
            [(Dense right-address _ _)
              (and
                (= left-address right-address)
                (match duplicate
                  [(Dense duplicate-address duplicate-tail duplicate-len)
                    (and
                      (= duplicate-address left-address)
                      (= duplicate-tail left-tail)
                      (= duplicate-len left-len))]
                  [_ false]))]
            [_ false])]
        [_ false])
      (match (tc_core.tc-lifetime-subst-bind left 30 999)
        [(Ok _) false]
        [(Err message)
          (string.eq
            message
            (cdiag.compiler-diagnostic-typecheck-tagged
              (LifetimeMismatch)
              "typecheck: constructor lifetime mismatch"))])
      (tc-lifetime-subst-list-ok?)
      (tc-lifetime-subst-nil-identity-ok?)
      (tc-lifetime-subst-wide-and-order-ok?))))

(test
  compiler-typecheck-lifetime-subst-invariant-facts
  (let
    [names : (__tl_dyn-array i64)
      (__tl_make-array (cast 0 : i64) 1 4611686018427387904 9223372036854775807)]
    [root : tc_core.TcLifetimeSubst
      (tc-lifetime-subst-must-bind
        (tc-lifetime-subst-must-bind Nil 10 110)
        20
        120)]
    [index : i64 0]
    (while (< index (array-length names))
      (let
        [name : i64 (array-ref names index)]
        [key : i64 (tc_core.tc-lifetime-subst-pin-key name)]
        [pinned : tc_core.TcLifetimeSubst
          (tc_core.tc-lifetime-subst-push-for-variance
            root
            name
            777
            (tc_core.TcVariance.TcVarianceInvariant))]
        [sibling : tc_core.TcLifetimeSubst
          (tc-lifetime-subst-must-bind root 30 130)]
        (unless
          (and
            (< key 0)
            (tc_core.tc-lifetime-subst-pinned? pinned name)
            (not (tc_core.tc-lifetime-subst-pinned? root name))
            (not (tc_core.tc-lifetime-subst-pinned? sibling name))
            (tc-lifetime-subst-lookup-eq? pinned name 777)
            (tc-lifetime-subst-lookup-missing? root name)
            (tc-lifetime-subst-lookup-eq? pinned 10 110)
            (tc-lifetime-subst-lookup-eq? sibling 20 120)
            (= (tc_core.tc-lifetime-subst-apply pinned 31) 31))
          (io.panic
            "typecheck: invariant fact escaped its lifetime domain or snapshot")))
      (set! index (+ index 1)))))

(test
  compiler-typecheck-lifetime-subst-storage
  (unless
    (tc-lifetime-subst-storage-ok?)
    (io.panic "typecheck: dense lifetime-substitution storage failed")))