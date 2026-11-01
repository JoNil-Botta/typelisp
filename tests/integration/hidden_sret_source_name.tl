(defstruct Big
  (a i64)
  (b i64)
  (c i64))

(define (raw-alias
  ;; lint-allow: local-name-case -- regression for the formerly hidden spelling.
  [x01__sret : (MutPtr i64)]
  [other : (MutPtr i64)]
  [depth : i64]) : i64
  (if (> depth 0)
    (raw-alias x01__sret other (- depth 1))
    (unsafe
      (let
        [before : i64 (ptr-read x01__sret)]
        [_ : unit (ptr-write! other 20)]
        (+ before (ptr-read x01__sret))))))

(define (ref-alias
  ;; lint-allow: local-name-case -- regression for the formerly hidden spelling.
  [x01__sret : (& x01__sret i64)]
  [other : (& other i64)]
  [depth : i64]) : i64
  (if (> depth 0)
    (ref-alias x01__sret other (- depth 1))
    (+ (deref x01__sret) (deref other))))

;; lint-allow: local-name-case -- regression for the formerly hidden spelling.
(define (aggregate [x01__sret : (& x01__sret i64)]) : Big
  (Big (deref x01__sret) 11 12))

(define (main) : i64
  (let
    [value : i64 10]
    [raw : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [a : i64 (raw-alias raw raw 2)]
    [b : i64 (ref-alias (& value) (& value) 2)]
    [c : Big (aggregate (& value))]
    (if (and (= a 30) (= b 40) (= c.a 20) (= c.b 11) (= c.c 12))
      42
      1)))