;; The round-6 review witnesses of #9593 (Opus and Sol on b012391a8), with the
;; arena renamed as the with-arena collision rule requires: each is accepted
;; and runs. Binders spelled like the caller lifetime inside the arena keep
;; their ordinary meaning.
(import stdlib.comptime)

(defenum E
  (r)
  (Other))

(defenum P
  (:lifetimes a)
  (Pair i64 (& a i64)))

(defmacro (typed-pair
  [a : ExprBindingClause]
  [b : ExprBindingClause]
  [body : Expr]) : Expr
  (comptime.expr-match
    (comptime.expr-binding-clause-init a)
    (comptime.match-arm-list-cons
      (comptime.match-arm
        (comptime.pattern-variant
          "Pair"
          (comptime.pattern-list-cons
            (comptime.pattern-binding-typed
              (comptime.expr-binding-clause-name a)
              (comptime.expr-binding-clause-type a))
            (comptime.pattern-list-cons
              (comptime.pattern-binding-typed
                (comptime.expr-binding-clause-name b)
                (comptime.expr-binding-clause-type b))
              (comptime.pattern-list-empty))))
        body)
      (comptime.match-arm-list-empty))))

;; Sol F1: a nullary variant spelled `r` binds nothing.
(define (nullary-variant [p : (& r i64)] [e : E]) : i64
  (with-arena
    ar
    (let
      [x : (Box i64) (box 42)]
      [saved : (& ar i64) (& ar (deref x))]
      (match e
        [r
          (let
            [alias : (& ar i64) (& ar (deref x))]
            (set! saved alias)
            (deref saved))]
        [Other 0]))))

;; Opus: mixed same-named parameters with an `r`-typed result.
(define (mixed-return [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [f
        (lambda ([r : i64] [r : (& r i64)]) : (& r i64)
          r)]
      (deref (f 1 p)))))

;; Sol F2: one aggregate parameter named `r` with an `r`-typed result.
(define (nested-return [p : (& r i64)]) : i64
  (let
    [t : (Tuple (& r i64) i64) (tuple p 0)]
    (with-arena
      ar
      (let
        [f
          (lambda ([r : (Tuple (& r i64) i64)]) : (& r i64)
            (tuple-ref r 0))]
        (deref (f t))))))

;; Sol F2: a scalar `r` beside a differently named parameter, both orders.
(define (other-param [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [f
        (lambda ([r : i64] [q : (& r i64)]) : i64
          (begin
            (& r q)
            21))]
      [g
        (lambda ([q : (& r i64)] [r : i64]) : i64
          (begin
            (& r q)
            21))]
      (+ (f 1 p) (g p 1)))))

;; Sol F3: mixed same-named typed payload binders built by a macro. The
;; payload and its borrow are arena data, so both name the renamed arena.
(define (typed-payloads [p : (& r i64)]) : i64
  (with-arena
    ar
    (let
      [x : (Box i64) (box 42)]
      [saved : (& ar i64) (& ar (deref x))]
      [t : (P ar) (Pair 1 saved)]
      (typed-pair
        [r : i64 t]
        [r : (& ar i64) t]
        (begin
          (& ar r)
          42)))))

(define (main) : i64
  (let
    [seed : i64 42]
    [total : i64
      (+
        (nullary-variant (& seed) (r))
        (+
          (mixed-return (& seed))
          (+
            (nested-return (& seed))
            (+ (other-param (& seed)) (typed-payloads (& seed))))))]
    (- total 168)))