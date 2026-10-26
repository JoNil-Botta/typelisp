;: A field reached through a shared reference cannot be mutably borrowed, also
;: inside a match arm over another parameter.
(defstruct Cache
  (hits (__tl_dyn-array i64))
  (enabled bool))

(defenum Steps
  (Done)
  (More i64))

(define (record! [hits : (&mut hits (__tl_dyn-array i64))]) : i64
  (begin
    (set! (array-ref hits 0) (+ (array-ref hits 0) 1))
    (array-ref hits 0)))

(define (touch [cache : (& cache Cache)] [steps : Steps]) : i64
  (match steps
    [(Steps.Done) 0]
    [(Steps.More n)
      (if cache.enabled
        (+ n (record! (&mut cache.hits)))
        n)]))

(define (main) : i64
  0)