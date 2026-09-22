;; compiler-scaling - deterministic compiler-scaling fixtures (#7773).
;;
;; usage: compiler-scaling <dimension> <size>
;;
;; Prints one TypeLisp program to stdout. Each dimension varies exactly one
;; property of the input, so a growth curve over <size> isolates one compiler
;; cost. Every program checks its own result: the generator evaluates the same
;; arithmetic while it emits the source, and `main` returns 42 only when the
;; compiled program reproduces that value. A size never changes what a unit
;; does, only how many units there are, so a smaller input can never stand in
;; for a larger one.
;;
;; Dimensions:
;;   decls   <size> small functions, all reachable from `main` through a chain
;;           of eight-way callers (declaration count).
;;   cfg     one function whose body is <size> sequential two-armed branches
;;           over one running value (function and CFG size).
;;   fields  one struct with <size> fields, built once and summed field by
;;           field (aggregate width).
(import stdlib.io)
(import stdlib.string)
(import stdlib.str_cat)

(define scaling-mask : i64
  1048575)
(define scaling-size-limit : i64
  1000000)

(define (scaling-line [text : String]) : unit
  (io.println "{}" text))

(define (scaling-int [value : i64]) : String
  (string.int->string value))

;; decls: f<i>(x) = x * (i mod 7 + 1) + (i mod 11).
(define (decls-unit-value [index : i64] [x : i64]) : i64
  (+ (* x (+ (% index 7) 1)) (% index 11)))

(define (decls-emit-units [size : i64]) : unit
  (let
    [index : i64 0]
    (while (< index size)
      (begin
        (scaling-line
          (str_cat.str-cat
            "(define (f"
            (scaling-int index)
            " [x : i64]) : i64\n  (+ (* x "
            (scaling-int (+ (% index 7) 1))
            ") "
            (scaling-int (% index 11))
            "))\n"))
        (set! index (+ index 1))))))

;; Callers g<k> sum eight units each and chain to g<k-1>, so every unit is
;; reachable and no single expression grows with <size>. Returns the value the
;; last caller produces for x = 1.
(define (decls-emit-callers [size : i64]) : i64
  (let
    [start : i64 0]
    [group : i64 0]
    [expected : i64 0]
    (begin
      (while (< start size)
        (let
          [index : i64 start]
          [stop : i64
            (if (< (+ start 8) size)
              (+ start 8)
              size)]
          [sum : i64 expected]
          (begin
            (io.print-format
              "(define (g{} [x : i64]) : i64\n  (bit-and (+ "
              group)
            (if (= group 0)
              (io.print-format "{}" "0")
              (io.print-format "(g{} x)" (- group 1)))
            (while (< index stop)
              (begin
                (io.print-format " (f{} x)" index)
                (set! sum (+ sum (decls-unit-value index 1)))
                (set! index (+ index 1))))
            (io.print-format ") {}))\n\n" scaling-mask)
            (set! expected (bit-and sum scaling-mask))
            (set! start stop)
            (set! group (+ group 1)))))
      (io.print-format
        "(define (main) : i64\n  (if (= (g{} 1) {}) 42 1))\n"
        (- group 1)
        expected)
      expected)))

(define (emit-decls [size : i64]) : unit
  (begin
    (decls-emit-units size)
    (decls-emit-callers size)
    unit))

;; cfg: step i takes one of two arms on the running value, then masks it.
(define (cfg-step [acc : i64] [index : i64]) : i64
  (bit-and
    (if (= (bit-and acc (+ (% index 5) 1)) 0)
      (+ acc (+ (% index 13) 1))
      (+ (* acc 3) (% index 7)))
    scaling-mask))

(define (emit-cfg [size : i64]) : unit
  (let
    [index : i64 0]
    [acc : i64 5]
    (begin
      (scaling-line
        "(define (walk [x : i64]) : i64\n  (let\n    [acc : i64 x]\n    (begin")
      (while (< index size)
        (begin
          (io.print-format
            "      (if (= (bit-and acc {}) 0) (set! acc (+ acc {})) (set! acc (+ (* acc 3) {})))\n"
            (+ (% index 5) 1)
            (+ (% index 13) 1)
            (% index 7))
          (io.print-format "      (set! acc (bit-and acc {}))\n" scaling-mask)
          (set! acc (cfg-step acc index))
          (set! index (+ index 1))))
      (scaling-line "      acc)))\n")
      (io.print-format
        "(define (main) : i64\n  (if (= (walk 5) {}) 42 1))\n"
        acc))))

;; fields: field i holds (i mod 97) + 1; `total` adds one field per statement,
;; so no expression grows with <size>.
(define (emit-fields [size : i64]) : unit
  (let
    [index : i64 0]
    [expected : i64 0]
    (begin
      (scaling-line "(defstruct Wide")
      (while (< index size)
        (begin
          (io.print-format "  (f{} i64)\n" index)
          (set! index (+ index 1))))
      (scaling-line "  (tail i64))\n")
      (scaling-line "(define (make) : Wide\n  (Wide")
      (set! index 0)
      (while (< index size)
        (begin
          (io.print-format "    {}\n" (+ (% index 97) 1))
          (set! expected (bit-and (+ expected (+ (% index 97) 1)) scaling-mask))
          (set! index (+ index 1))))
      (scaling-line "    0))\n")
      (scaling-line
        "(define (total [w : (& w Wide)]) : i64\n  (let\n    [sum : i64 0]\n    (begin")
      (set! index 0)
      (while (< index size)
        (begin
          (io.print-format
            "      (set! sum (bit-and (+ sum w.f{}) {}))\n"
            index
            scaling-mask)
          (set! index (+ index 1))))
      (scaling-line "      sum)))\n")
      (io.print-format
        "(define (main) : i64\n  (let\n    [w : Wide (make)]\n    (if (= (total (& w)) {}) 42 1)))\n"
        expected))))

(define (scaling-usage) : i64
  (begin
    (io.print-error
      "usage: compiler-scaling <decls|cfg|fields> <size>\n  size is a decimal integer from 1 to 1000000\n")
    2))

;; A size is digits only: `string.>int` alone would read "12x" as 12.
(define (scaling-size-text-valid? [text : (& text str)]) : bool
  (let
    [length : i64 (string.string-length text)]
    [index : i64 0]
    [ok : bool (and (> length 0) (<= length 7))]
    (begin
      (while (and ok (< index length))
        (let
          [c : char (string.string-ref text index)]
          (begin
            (set! ok (and (>= (cast c : i64) 48) (<= (cast c : i64) 57)))
            (set! index (+ index 1)))))
      ok)))

(define (main) : i64
  (if (not (= (io.arg-count) 3))
    (scaling-usage)
    (let
      [dimension : String (io.arg 1)]
      [size-text : String (io.arg 2)]
      (if (not (scaling-size-text-valid? (& size-text)))
        (scaling-usage)
        (let
          [size : i64 (string.>int (& size-text))]
          (if (or (< size 1) (> size scaling-size-limit))
            (scaling-usage)
            (cond
              [(string.eq (& dimension) "decls")
                (begin
                  (emit-decls size)
                  0)]
              [(string.eq (& dimension) "cfg")
                (begin
                  (emit-cfg size)
                  0)]
              [(string.eq (& dimension) "fields")
                (begin
                  (emit-fields size)
                  0)]
              [else (scaling-usage)])))))))