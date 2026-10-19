(define events : i64
  0)

(define (mark [value : (& a i64)] [digit : i64]) : (& a i64)
  (set! events (+ (* events 10) digit))
  value)

(define (sum3 [items : (& items (Array (& a i64) 3))]) : i64
  (+
    (deref (array-ref items 0))
    (+ (deref (array-ref items 1)) (deref (array-ref items 2)))))

(define (permutations [xs : (& a (Array i64 1))] [ys : (& b (Array i64 1))]) : i64
  (let
    [z : i64 12]
    [refs-abc (array (& (array-ref xs 0)) (& (array-ref ys 0)) (& z))]
    [refs-acb (array (& (array-ref xs 0)) (& z) (& (array-ref ys 0)))]
    [refs-bac (array (& (array-ref ys 0)) (& (array-ref xs 0)) (& z))]
    [refs-bca (array (& (array-ref ys 0)) (& z) (& (array-ref xs 0)))]
    [refs-cab (array (& z) (& (array-ref xs 0)) (& (array-ref ys 0)))]
    [refs-cba (array (& z) (& (array-ref ys 0)) (& (array-ref xs 0)))]
    (+
      (sum3 (& refs-abc))
      (+
        (sum3 (& refs-acb))
        (+
          (sum3 (& refs-bac))
          (+ (sum3 (& refs-bca)) (+ (sum3 (& refs-cab)) (sum3 (& refs-cba)))))))))

(define (ordered [xs : (& a (Array i64 1))]) : bool
  (let
    [z : i64 32]
    [items (array (mark (& (array-ref xs 0)) 1) (mark (& z) 2))]
    [forward : i64 (+ (deref (array-ref items 0)) (deref (array-ref items 1)))]
    [reversed (array (mark (& z) 3) (mark (& (array-ref xs 0)) 4))]
    [backward : i64
      (+ (deref (array-ref reversed 0)) (deref (array-ref reversed 1)))]
    (and (= events 1234) (= forward 42) (= backward 42))))

(define (nested [xs : (& a (Array i64 1))]) : bool
  (let
    [z : i64 32]
    [items (array (tuple (& (array-ref xs 0)) 1) (tuple (& z) 2))]
    [reversed (array (tuple (& z) 2) (tuple (& (array-ref xs 0)) 1))]
    [left (array-ref items 0)]
    [right (array-ref items 1)]
    (and
      (= (+ (deref (tuple-ref left 0)) (deref (tuple-ref right 0))) 42)
      (= (+ (tuple-ref left 1) (tuple-ref right 1)) 3)
      (=
        (+
          (deref (tuple-ref (array-ref reversed 0) 0))
          (deref (tuple-ref (array-ref reversed 1) 0)))
        42))))

(define (scoped) : i64
  (let
    [plain (box (ann 10 : i64))]
    (with-arena
      phase
      (let
        [items (array plain (box (ann 32 : i64)))]
        (+ (deref (array-ref items 0)) (deref (array-ref items 1)))))))

(define (main) : i64
  (let
    [xs : (Array i64 1) (array 10)]
    [ys : (Array i64 1) (array 20)]
    [single (array (& (array-ref xs 0)))]
    [equal (array (& (array-ref xs 0)) (& (array-ref xs 0)))]
    [integers (array (ann 1 : i64) 41)]
    (if (and
      (= (permutations (& xs) (& ys)) 252)
      (ordered (& xs))
      (nested (& xs))
      (= (scoped) 42)
      (= (+ (array-ref integers 0) (array-ref integers 1)) 42)
      (= (deref (array-ref single 0)) 10)
      (= (deref (array-ref equal 1)) 10))
      42
      1)))