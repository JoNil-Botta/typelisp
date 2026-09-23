;; Tuple literals live in inline frame storage (#7070). Every case below lets a
;; tuple outlive the expression, loop iteration or frame that built it -- struct
;; fields, enum payloads, globals, closure captures, MoveOnly elements, returns
;; and loop-carried rebinding of register-class and memory-class tuples -- and
;; then overwrites the dead frames before reading, so a value that aliased freed
;; frame storage instead of being copied would read clobbered bytes.
(import stdlib.string)

(defstruct Holder
  (pair (Tuple i64 i64))
  (wide (Tuple i64 i64 i64 i64))
  (tag i64))

(defenum Carrier
  (Wide (Tuple i64 i64 i64 i64))
  (None))

(define stored : (Tuple i64 i64 i64 i64)
  (tuple 1 2 3 4))

(define (clobber [n : i64]) : i64
  (let
    [t : (Tuple i64 i64 i64 i64) (tuple n n n n)]
    (if (<= n 0)
      (tuple-ref t 0)
      (+ (tuple-ref t 3) (clobber (- n 1))))))

(define (make-wide [x : i64]) : (Tuple i64 i64 i64 i64)
  (tuple x (+ x 1) (+ x 2) (+ x 3)))

(define (make-holder [x : i64]) : Holder
  (Holder (tuple x x) (make-wide x) x))

(define (make-carrier [x : i64]) : Carrier
  (Carrier.Wide (tuple x x x (+ x 5))))

(define (make-reader [x : i64]) : (-> i64)
  (let
    [t : (Tuple i64 i64 i64 i64) (tuple x x x (+ x 7))]
    (lambda () : i64
      (tuple-ref t 3))))

(define (set-global! [x : i64]) : unit
  (set! stored (tuple x x x (+ x 9))))

(define (loop-carried [n : i64]) : i64
  (let
    [acc : (Tuple i64 i64 i64 i64) (tuple 0 0 0 0)]
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            acc
            (tuple
              i
              (tuple-ref acc 0)
              (tuple-ref acc 1)
              (+ (tuple-ref acc 3) i)))
          (set! i (+ i 1))))
      (+ (tuple-ref acc 3) (tuple-ref acc 2)))))

(define (with-string [x : i64]) : (Tuple String i64 i64)
  (tuple (string.concat "ab" "cd") x x))

(defstruct Keep
  (first (Tuple i64 i64))
  (last (Tuple i64 i64 i64)))

(define (prev-cur-small [n : i64]) : i64
  (let
    [prev : (Tuple i64 i64) (tuple 0 0)]
    [sum : i64 0]
    [i : i64 1]
    (begin
      (while (<= i n)
        (let
          [cur : (Tuple i64 i64) (tuple i (* i 2))]
          (begin
            (set! sum (+ sum (+ (tuple-ref prev 1) (tuple-ref cur 0))))
            (set! prev cur)
            (set! i (+ i 1)))))
      (+ sum (tuple-ref prev 1)))))

(define (prev-cur-wide [n : i64]) : i64
  (let
    [prev : (Tuple i64 i64 i64) (tuple 0 0 0)]
    [sum : i64 0]
    [i : i64 1]
    (begin
      (while (<= i n)
        (let
          [cur : (Tuple i64 i64 i64) (tuple i (* i 2) (* i 3))]
          (begin
            (set! sum (+ sum (+ (tuple-ref prev 2) (tuple-ref cur 0))))
            (set! prev cur)
            (set! i (+ i 1)))))
      (+ sum (tuple-ref prev 2)))))

(define (keep-first-last [n : i64]) : Keep
  (let
    [first : (Tuple i64 i64) (tuple 0 0)]
    [last : (Tuple i64 i64 i64) (tuple 0 0 0)]
    [i : i64 1]
    (begin
      (while (<= i n)
        (begin
          (when (= i 1) (set! first (tuple i (+ i 100))))
          (set! last (tuple i (+ i 1) (+ i 2)))
          (set! i (+ i 1))))
      (Keep first last))))

(define (nested-calls [x : i64]) : (Tuple (Tuple i64 i64) (Tuple i64 i64 i64))
  (tuple (tuple x (+ x 1)) (tuple x (+ x 2) (+ x 3))))

(define (main) : i64
  (let
    [h : Holder (make-holder 3)]
    [c : Carrier (make-carrier 4)]
    [r : (-> i64) (make-reader 5)]
    [s : (Tuple String i64 i64) (with-string 6)]
    [k : Keep (keep-first-last 5)]
    [nested : (Tuple (Tuple i64 i64) (Tuple i64 i64 i64)) (nested-calls 7)]
    (begin
      (set-global! 10)
      (clobber 40)
      (unless (= (tuple-ref h.wide 3) 6) (return 1))
      (unless (= (tuple-ref h.pair 1) 3) (return 2))
      (unless
        (=
          (match c
            [(Carrier.Wide w) (tuple-ref w 3)]
            [(Carrier.None) 0])
          9)
        (return 3))
      (unless (= (r) 12) (return 4))
      (unless (= (tuple-ref stored 3) 19) (return 5))
      (unless (= (loop-carried 10) 52) (return 6))
      (unless (= (string.string-length (tuple-ref s 0)) 4) (return 7))
      ;; (0+1)+(2+2)+(4+3)+(6+4) = 22, plus the final prev.1 = 8.
      (unless (= (prev-cur-small 4) 30) (return 8))
      ;; (0+1)+(3+2)+(6+3)+(9+4) = 28, plus the final prev.2 = 12.
      (unless (= (prev-cur-wide 4) 40) (return 9))
      (unless
        (= (+ (tuple-ref k.first 1) (tuple-ref k.last 2)) 108)
        (return 10))
      (unless
        (=
          (+
            (tuple-ref (tuple-ref nested 0) 1)
            (tuple-ref (tuple-ref nested 1) 2))
          18)
        (return 11))
      42)))