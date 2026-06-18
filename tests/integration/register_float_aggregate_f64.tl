;; #2601: exact aligned f64 fields in <=16-byte aggregates are register-resident
;; SSE eightbytes. #2855 covers packed f32 SSE eightbytes in the sibling fixture.
(defstruct PairF64
  (x f64)
  (y f64))

(defstruct MixIF
  (i i64)
  (f f64))

(defenum FloatRes
  (Good f64)
  (Bad f64))

(define global-pair : PairF64
  (PairF64 2.0 3.0))
(define global-mix : MixIF
  (MixIF 7 8.5))

(define (pair-sum [p : PairF64]) : f64
  (+ (struct-get p x) (struct-get p y)))

(define (make-pair [x : f64] [y : f64]) : PairF64
  (PairF64 x y))

(define (choose-pair [take-left : bool]) : PairF64
  (if take-left
    (PairF64 1.25 2.75)
    (PairF64 9.0 10.0)))

(define (mix-i [m : MixIF]) : i64
  (struct-get m i))

(define (mix-f [m : MixIF]) : f64
  (struct-get m f))

(define (handle [r : FloatRes]) : f64
  (match r
    [(Good value) value]
    [(Bad value) (- 0.0 value)]))

;; Eight preceding f64 parameters exhaust SysV's xmm arg bank before `p`; they
;; also put `p` past Win64's four positional register slots.
(define (stack-pair
  [a : f64]
  [_b : f64]
  [_c : f64]
  [_d : f64]
  [_e : f64]
  [_f : f64]
  [_g : f64]
  [h : f64]
  [p : PairF64]) : f64
  (+ (+ a h) (pair-sum p)))

(define (case-pair-return) : bool
  (= (pair-sum (make-pair 1.5 2.5)) 4.0))

(define (case-pair-phi) : bool
  (= (pair-sum (choose-pair true)) 4.0))

(define (case-mixed) : bool
  (let
    [m : MixIF (MixIF 11 4.5)]
    (if (= (mix-i m) 11)
      (= (mix-f m) 4.5)
      false)))

(define (case-enum) : bool
  (if (= (handle (Good 6.5)) 6.5)
    (= (handle (Bad 1.25)) (- 0.0 1.25))
    false))

(define (case-stack) : bool
  (= (stack-pair 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 (PairF64 9.0 10.0)) 28.0))

(define (case-global) : bool
  (begin
    (set! global-pair (make-pair 12.5 0.5))
    (set! global-mix (MixIF 17 1.5))
    (if (= (pair-sum global-pair) 13.0)
      (if (= (mix-i global-mix) 17)
        (= (mix-f global-mix) 1.5)
        false)
      false)))

(define (case-array) : bool
  (let
    [items : (Array PairF64) (make-array PairF64 2)]
    (begin
      (array-set! items 0 (PairF64 3.0 4.0))
      (array-set! items 1 (PairF64 5.0 6.0))
      (if (= (pair-sum (array-ref items 0)) 7.0)
        (= (struct-get (array-ref items 1) y) 6.0)
        false))))

(define (case-capture) : bool
  (let
    [p : PairF64 (PairF64 20.0 22.0)]
    [reader : (-> f64)
      (lambda () : f64
        (pair-sum p))]
    (= (reader) 42.0)))

(define (main) : i64
  (begin
    (unless (case-pair-return) (return 1))
    (unless (case-pair-phi) (return 2))
    (unless (case-mixed) (return 3))
    (unless (case-enum) (return 4))
    (unless (case-stack) (return 5))
    (unless (case-global) (return 6))
    (unless (case-array) (return 7))
    (unless (case-capture) (return 8))
    42))