(import function_assignment_dep.cap as imported-cap)
(import function_assignment_dep as dep)

(define (cap) : i64
  1)

(define (big) : i64
  42)

(define selected : (-> i64)
  cap)

(defstruct Callbacks
  (cap (-> i64)))

(defmacro (assign [place : Expr] [value : Expr]) : Expr
  `(set! ,place ,value))

(define (replace-parameter [cap : (-> i64)]) : i64
  (begin
    (set! cap big)
    (cap)))

(define (main) : i64
  (let
    [same-name : i64
      (let
        [cap : (-> i64) cap]
        (if (= (cap) 1)
          (begin
            (set! cap big)
            (cap))
          1))]
    [import-shadow : i64
      (let
        [imported-cap : (-> i64) imported-cap]
        (if (= (imported-cap) 4096)
          (begin
            (assign imported-cap big)
            (imported-cap))
          1))]
    [field : i64
      (let
        [dep : Callbacks (Callbacks cap)]
        (begin
          (set! dep.cap big)
          (dep.cap)))]
    [closure : (-> i64)
      (lambda () : i64
        1)]
    (begin
      (set! selected big)
      (set!
        closure
        (lambda () : i64
          42))
      (if (and
        (= same-name 42)
        (= import-shadow 42)
        (= field 42)
        (= (replace-parameter cap) 42)
        (= (selected) 42)
        (= (closure) 42))
        42
        1))))