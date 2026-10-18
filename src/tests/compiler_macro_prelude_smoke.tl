;; compiler_macro_prelude_smoke.tl - Implicit stdlib macro prelude smoke.
(import stdlib.io)

(define (compiler-macro-prelude-selfhost-smoke) : i64
  (let
    [value : i64 0]
    (if (and true true true)
      (set! value 1)
      (set! value 1000))
    (if (and
      true
      false
      (begin
        (set! value 1000)
        true))
      (set! value 1000)
      unit)
    (if (or false false true)
      (+= value 6)
      (set! value 1000))
    (if (or
      true
      (begin
        (set! value 1000)
        false))
      unit
      (set! value 1000))
    (when true (set! value 7))
    (when false (set! value 1000))
    (unless false (set! value (* value 6)))
    (unless true (set! value 1000))
    (set!
      value
      (if false
        1000
        (if (= value 42)
          value
          1000)))
    value))

(test
  macro-prelude-selfhost
  (if (= (compiler-macro-prelude-selfhost-smoke) 42)
    unit
    (io.panic "macro prelude smoke mismatch")))