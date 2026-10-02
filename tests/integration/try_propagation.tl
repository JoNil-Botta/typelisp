;; `(try expr)` between result-like families whose Err payload types are equal
;; and whose Ok variants differ (one payload, none, or two in the enclosing
;; family), with macros in the operand, inside a lambda and a loop, and with
;; the `with` cleanups and `with-arena` resets that run on the error path, plus
;; option-like families. The Err payload is a 24-byte struct, so those families
;; are returned in memory; `WordResult`, `WordCheck` and `MaybeWord` are 16
;; bytes and come back in a register group. Every input is offset by `base`,
;; derived from the argument count, so opt2 keeps each error path.
(import stdlib.io)
(import stdlib.string)

(extern (tl_region_mark) : u64)

(defstruct Diag
  (code i64)
  (line i64)
  (col i64))

(defenum ReadResult
  (Ok i64)
  (Err Diag))

(defenum FlagResult
  (Ok bool)
  (Err Diag))

(defenum CheckResult
  (Ok)
  (Err Diag))

(defenum SpanResult
  (Ok i64 i64)
  (Err Diag))

(defenum WordResult
  (Ok i64)
  (Err i64))

(defenum WordCheck
  (Ok)
  (Err i64))

(defenum MaybeDiag
  (Some Diag)
  (None))

(defenum MaybeWord
  (Some i64)
  (None))

(define (read [x : i64]) : ReadResult
  (if (>= x 0)
    (Ok x)
    (Err (Diag 3 x 9))))

(define (check [x : i64]) : CheckResult
  (if (< x 100)
    Ok
    (Err (Diag 4 x 1))))

(define (read-word [x : i64]) : WordResult
  (if (>= x 0)
    (Ok x)
    (Err (- 0 x))))

(define (find-diag [x : i64]) : MaybeDiag
  (if (> x 0)
    (Some (Diag x 0 0))
    None))

(define (diag-score [d : Diag]) : i64
  (+ (* 100 d.code) (* 10 d.line) d.col))

(define (read-score [r : ReadResult]) : i64
  (match r
    [(Ok v) v]
    [(Err d) (- 0 (diag-score d))]))

(define (flag-score [r : FlagResult]) : i64
  (match r
    [(Ok b)
      (if b
        1
        2)]
    [(Err d) (- 0 (diag-score d))]))

(define (check-score [r : CheckResult]) : i64
  (match r
    [Ok 0]
    [(Err d) (- 0 (diag-score d))]))

(define (word-score [r : WordResult]) : i64
  (match r
    [(Ok v) v]
    [(Err e) (- 0 e)]))

(define (word-check-score [r : WordCheck]) : i64
  (match r
    [Ok 0]
    [(Err e) (- 0 e)]))

(define (maybe-diag-score [m : MaybeDiag]) : i64
  (match m
    [(Some d) (diag-score d)]
    [None -1]))

(define (maybe-word-score [m : MaybeWord]) : i64
  (match m
    [(Some v) v]
    [None -1]))

;; A `*-shared-view`-style place macro, `cond` and `and` inside try operands.
(defmacro (word-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(define (flag-via-macros [x : i64] [y : i64]) : FlagResult
  (let
    [a : i64 (try (read (word-view x)))]
    [b : i64 (try (read (cond [(> y 10) (- y 10)] [else y])))]
    [c : i64
      (try
        (read
          (if (and (> a 0) (> b 0))
            (+ a b)
            (- a 1))))]
    (Ok (> c 5))))

;; The enclosing family's Ok has no payload; a unit try yields `unit`.
(define (validate [x : i64]) : CheckResult
  (let
    [_ : i64 (try (read x))]
    (begin
      (try (check x))
      Ok)))

(define (double-checked [x : i64]) : ReadResult
  (let
    [_ : unit (try (check x))]
    (Ok (* 2 x))))

;; The enclosing family's Ok variant may carry several payloads.
(define (span [x : i64] [y : i64]) : SpanResult
  (Ok (try (read x)) (try (read y))))

(define (span-score [r : SpanResult]) : i64
  (match r
    [(Ok from to) (+ (* 100 from) to)]
    [(Err d) (- 0 (diag-score d))]))

;; Register-group families on both sides, with a unit success.
(define (word-sum [x : i64] [y : i64]) : WordResult
  (Ok (+ (try (read-word x)) (try (read-word y)))))

(define (word-validate [x : i64]) : WordCheck
  (let
    [_ : i64 (try (read-word x))]
    Ok))

;; Option-like families propagate absence across families as well, returned
;; in memory (`MaybeDiag`) and in a register group (`MaybeWord`).
(define (find-word [x : i64]) : MaybeWord
  (let
    [d : Diag (try (find-diag x))]
    (Some (+ d.code 1))))

(define (find-diag-again [x : i64]) : MaybeDiag
  (let
    [w : i64 (try (find-word x))]
    (Some (Diag w w w))))

(define (lambda-flag [x : i64]) : FlagResult
  (let
    [f
      (lambda ([y : i64]) : FlagResult
        (Ok (> (try (read y)) 2)))]
    (f x)))

(define (sum-down [n : i64] [start : i64]) : ReadResult
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! acc (+ acc (try (read (- start i)))))
          (set! i (+ i 1))))
      (Ok acc))))

(define cleanups : i64
  0)

(define (release [h : i64]) : unit
  (set! cleanups (+ (* cleanups 10) h)))

;; `inner` is released before `outer` on both exits.
(define (with-cleanup [x : i64]) : ReadResult
  (with
    ([outer 1 release] [inner 2 release])
    (Ok (+ outer inner (try (read x))))))

;; A failing later initializer releases the bindings already made.
(define (with-init-cleanup [x : i64]) : ReadResult
  (with
    ([first 3 release] [second (try (read x)) release])
    (Ok (+ first second))))

;; The error path leaves the scratch arena reset and the outer arena current.
(define (arena-step [x : i64]) : ReadResult
  (let
    [n : i64
      (with-arena
        scratch
        (let
          [text : String (string.int->string x)]
          (+ (string.string-length text) (try (read x)))))]
    (Ok n)))

(define (main) : i64
  (let
    [base : i64 (- (io.arg-count) 1)]
    [mark : u64 (tl_region_mark)]
    (begin
      (unless
        (= (flag-score (flag-via-macros (+ base 4) (+ base 13))) 1)
        (return 1))
      (unless
        (= (flag-score (flag-via-macros (+ base 1) (+ base 2))) 2)
        (return 2))
      (unless (= (flag-score (flag-via-macros (- base 2) 5)) -289) (return 3))
      (unless (= (flag-score (flag-via-macros 4 (- base 9))) -219) (return 4))
      (unless (= (flag-score (flag-via-macros base base)) -299) (return 5))
      (unless (= (check-score (validate (+ base 7))) 0) (return 6))
      (unless (= (check-score (validate (- base 4))) -269) (return 7))
      (unless (= (check-score (validate (+ base 200))) -2401) (return 8))
      (unless (= (read-score (double-checked (+ base 21))) 42) (return 9))
      (unless (= (read-score (double-checked (+ base 150))) -1901) (return 10))
      (unless (= (span-score (span (+ base 3) 4)) 304) (return 35))
      (unless (= (span-score (span 3 (- base 4))) -269) (return 36))
      (unless (= (word-score (word-sum (+ base 20) 22)) 42) (return 11))
      (unless (= (word-score (word-sum (+ base 20) -22)) -22) (return 12))
      (unless (= (word-score (word-sum (- base 5) 22)) -5) (return 13))
      (unless (= (word-check-score (word-validate (+ base 8))) 0) (return 14))
      (unless (= (word-check-score (word-validate (- base 8))) -8) (return 15))
      (unless (= (flag-score (lambda-flag (+ base 3))) 1) (return 16))
      (unless (= (flag-score (lambda-flag (- base 6))) -249) (return 17))
      (unless (= (read-score (sum-down 3 (+ base 5))) 12) (return 18))
      (unless (= (read-score (sum-down 8 (+ base 5))) -299) (return 19))
      (unless (= (read-score (with-cleanup (+ base 4))) 7) (return 20))
      (unless (= cleanups 21) (return 21))
      (unless (= (read-score (with-cleanup (- base 7))) -239) (return 22))
      (unless (= cleanups 2121) (return 23))
      (set! cleanups 0)
      (unless (= (read-score (with-init-cleanup (+ base 4))) 7) (return 24))
      (unless (= cleanups 43) (return 25))
      (unless (= (read-score (with-init-cleanup (- base 1))) -299) (return 26))
      (unless (= cleanups 433) (return 27))
      (unless (= (read-score (arena-step (+ base 25))) 27) (return 28))
      (unless (= (read-score (arena-step (- base 25))) -59) (return 29))
      (unless (= (tl_region_mark) mark) (return 30))
      (unless (= (maybe-word-score (find-word (+ base 5))) 6) (return 31))
      (unless (= (maybe-word-score (find-word (- base 5))) -1) (return 32))
      (unless
        (= (maybe-diag-score (find-diag-again (+ base 5))) 666)
        (return 33))
      (unless
        (= (maybe-diag-score (find-diag-again (- base 5))) -1)
        (return 34))
      42)))