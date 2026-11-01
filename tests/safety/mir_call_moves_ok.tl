;; Valid twins of the call move rejections: an assignment reinitializes a
;; moved binder, Copy arguments stay readable, and each branch may move the
;; same value once.
(defstruct Pair
  (left i64)
  (right i64))

(define (consume [_text : String]) : i64
  20)

(define (forward [text : String]) : String
  text)

(define (pair-weight [_pair : Pair]) : i64
  1)

(define (reinitialize [text : String] [other : String]) : i64
  (let
    [first : i64 (consume text)]
    (begin
      (set! text (forward other))
      (+ first (consume text)))))

(define (copies [pair : Pair]) : i64
  (+ (pair-weight pair) (pair-weight pair)))

(define (either [text : String] [flag : bool]) : i64
  (if flag
    (consume text)
    (- (consume text) 20)))

(define (main) : i64
  (let
    [pair : Pair (Pair 1 2)]
    (+ (reinitialize "a" "b") (copies pair) (either "c" false))))