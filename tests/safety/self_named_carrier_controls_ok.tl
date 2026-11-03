;; #8998: a parameter whose own type carries its name (`[a : (& a T)]`,
;; `[s : (RefBox s)]`) is a self-named carrier: `a` is the caller's region, which
;; outlives the parameter and is unrelated to the other caller regions.
;; Valid callees with self-named carriers, called with a non-escaping local, a
;; global and a literal; a caller region outlives a by-value parameter's
;; container.
(define gvalue : i64
  5)

(define (same [a : (& a i64)] [q : (& q i64)]) : (& a i64)
  a)

(define (names [text : (& text str)]) : (& text str)
  text)

(define (keep [x : (& a i64)] [v : (__tl_dyn-array (& a i64))]) : i64
  (begin
    (__tl_array-push! v x)
    0))

(define (read-refs [refs : (__tl_dyn-array (&mut a i64))]) : i64
  0)

(define (stored
  [items : (&mut a (__tl_dyn-array i64))]
  [refs : (__tl_dyn-array (&mut a i64))]) : i64
  (begin
    (__tl_array-push! refs (&mut (array-ref items 0)))
    (read-refs refs)))

(define (main) : i64
  (let
    [g : i64 5]
    [local : i64 1]
    [x : i64 (deref (same (& local) (& g)))]
    [y : i64 (deref (same (& gvalue) (& g)))]
    (+ x (+ y (string-length-of (names "lit"))))))

(define (string-length-of [text : (& str)]) : i64
  0)