(extern (callback) : (CFunc non-null (-> i64 i64)) (:symbol "tl_never_callback"))
(extern (calls) : i64 (:symbol "tl_never_calls"))
(extern (gets) : i64 (:symbol "tl_never_gets"))

(define selected : i64
  0)
(define arguments : i64
  0)
(define cleaned : i64
  0)

(define (mark!) : unit
  (set! selected (+ selected 1)))

(define (argument!) : i64
  (set! arguments (+ arguments 1))
  41)

(define (inc [value : i64]) : i64
  (+ value 1))

(define (cleanup [value : i64]) : unit
  (set! cleaned (+ cleaned value)))

(define (language-tail [_f : (-> i64 i64)]) : i64
  ((ann
      (begin
        (mark!)
        (return 42))
      : (-> i64 i64))
    (argument!)))

(define (language-ordinary [_f : (-> i64 i64)]) : i64
  (let
    [value : i64
      ((ann
          (begin
            (mark!)
            (return 42))
          : (-> i64 i64))
        (argument!))]
    (+ value 1)))

(define (foreign-tail [_f : (CFunc non-null (-> i64 i64))]) : i64
  ((ann
      (begin
        (mark!)
        (return 42))
      : (CFunc non-null (-> i64 i64)))
    (argument!)))

(define (foreign-ordinary [_f : (CFunc non-null (-> i64 i64))]) : i64
  (let
    [value : i64
      ((ann
          (begin
            (mark!)
            (return 42))
          : (CFunc non-null (-> i64 i64)))
        (argument!))]
    (+ value 1)))

(define (foreign-factory) : i64
  ((ann
      (begin
        (mark!)
        (return 42))
      : (CFunc non-null (-> i64 i64)))
    ((callback) (argument!))))

(define (with-cleanup [_f : (-> i64 i64)]) : i64
  (with
    ([token 7 cleanup])
    ((ann
        (begin
          (mark!)
          (return 42))
        : (-> i64 i64))
      (argument!))))

(define (conditional [early : bool] [f : (-> i64 i64)]) : i64
  ((if early
      (begin
        (mark!)
        (return 42))
      f)
    (argument!)))

(define (main) : i64
  (let
    [a (language-tail inc)]
    [b (language-ordinary inc)]
    [c (foreign-tail (callback))]
    [d (foreign-ordinary (callback))]
    [e (foreign-factory)]
    [f (with-cleanup inc)]
    [g (conditional true inc)]
    [h (conditional false inc)]
    (if (and
      (= a 42)
      (= b 42)
      (= c 42)
      (= d 42)
      (= e 42)
      (= f 42)
      (= g 42)
      (= h 42)
      (= selected 7)
      (= arguments 1)
      (= cleaned 7)
      (= (calls) 0)
      (= (gets) 2))
      42
      1)))