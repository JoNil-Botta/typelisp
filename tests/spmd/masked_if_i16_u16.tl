(define (init-i16 [xs : (Array i16)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs i (cast (- (* i 37) 500) : i16))
        (set! i (+ i 1))))))

(define (fill-i16-foreach
  [xs : (Array i16)]
  [out : (Array i16)]
  [n : i64]
  [pivot : i16]
  [one : i16]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) pivot)
      (array-set! out i pivot)
      (array-set! out i (+ (array-ref xs i) one)))))

(define (fill-i16-scalar
  [xs : (Array i16)]
  [out : (Array i16)]
  [n : i64]
  [pivot : i16]
  [one : i16]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (< (array-ref xs i) pivot)
          (array-set! out i pivot)
          (array-set! out i (+ (array-ref xs i) one)))
        (set! i (+ i 1))))))

(define (eq-i16 [a : (Array i16)] [b : (Array i16)] [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (case-i16 [n : i64]) : bool
  (let
    [xs : (Array i16) (make-array i16 n)]
    [got : (Array i16) (make-array i16 n)]
    [want : (Array i16) (make-array i16 n)]
    [pivot : i16 (cast 0 : i16)]
    [one : i16 (cast 1 : i16)]
    (begin
      (init-i16 xs n)
      (fill-i16-foreach xs got n pivot one)
      (fill-i16-scalar xs want n pivot one)
      (eq-i16 got want n))))

(define (init-u16 [xs : (Array u16)] [n : i64]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (array-set! xs i (cast (+ (* i 37) 10) : u16))
        (set! i (+ i 1))))))

(define (fill-u16-foreach
  [xs : (Array u16)]
  [out : (Array u16)]
  [n : i64]
  [limit : u16]
  [one : u16]) : unit
  (foreach
    ([i : i64 0 n])
    (if (< (array-ref xs i) limit)
      (array-set! out i limit)
      (array-set! out i (+ (array-ref xs i) one)))))

(define (fill-u16-scalar
  [xs : (Array u16)]
  [out : (Array u16)]
  [n : i64]
  [limit : u16]
  [one : u16]) : unit
  (let
    [i : i64 0]
    (while (< i n)
      (begin
        (if (< (array-ref xs i) limit)
          (array-set! out i limit)
          (array-set! out i (+ (array-ref xs i) one)))
        (set! i (+ i 1))))))

(define (eq-u16 [a : (Array u16)] [b : (Array u16)] [n : i64]) : bool
  (let
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (if (!= (array-ref a i) (array-ref b i))
            (set! ok false)
            unit)
          (set! i (+ i 1))))
      ok)))

(define (case-u16 [n : i64]) : bool
  (let
    [xs : (Array u16) (make-array u16 n)]
    [got : (Array u16) (make-array u16 n)]
    [want : (Array u16) (make-array u16 n)]
    [limit : u16 (cast 500 : u16)]
    [one : u16 (cast 1 : u16)]
    (begin
      (init-u16 xs n)
      (fill-u16-foreach xs got n limit one)
      (fill-u16-scalar xs want n limit one)
      (eq-u16 got want n))))

(define (all-cases) : bool
  (and
    (case-i16 0)
    (case-i16 3)
    (case-i16 32)
    (case-i16 33)
    (case-u16 0)
    (case-u16 3)
    (case-u16 32)
    (case-u16 33)))

(define (main) : i64
  (if (all-cases)
    42
    1))