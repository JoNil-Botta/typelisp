;; Earlier operands are values even when a later operand rebinds their source.
;; Every pointer below addresses a live, aligned scalar; no invalid address or
;; concurrent access is needed to expose delayed operand reads.
(define (offset-ok?) : bool
  (let
    [first : i64 10]
    [second : i64 20]
    [source : (MutPtr i64)
      (unsafe
        (ptr-addr-of first))]
    [got : i64
      (unsafe
        (ptr-read
          (ptr-offset
            source
            (begin
              (set! source (ptr-addr-of second))
              0))))]
    (= got 10)))

(define (write-ok?) : bool
  (let
    [first : i64 10]
    [second : i64 20]
    [destination : (MutPtr i64)
      (unsafe
        (ptr-addr-of first))]
    (begin
      (unsafe
        (ptr-write!
          destination
          (begin
            (set! destination (ptr-addr-of second))
            99)))
      (and (= first 99) (= second 20)))))

(define (atomic-store-ok?) : bool
  (let
    [first : i64 10]
    [second : i64 20]
    [destination : (MutPtr i64)
      (unsafe
        (ptr-addr-of first))]
    (begin
      (unsafe
        (atomic-store!
          destination
          (begin
            (set! destination (ptr-addr-of second))
            99)))
      (and (= first 99) (= second 20)))))

(define (volatile-store-ok?) : bool
  (let
    [first : i64 10]
    [second : i64 20]
    [destination : (MutPtr i64)
      (unsafe
        (ptr-addr-of first))]
    (begin
      (unsafe
        (volatile-store!
          destination
          (begin
            (set! destination (ptr-addr-of second))
            99)))
      (and (= first 99) (= second 20)))))

(define (atomic-fetch-add-ok?) : bool
  (let
    [first : i64 10]
    [second : i64 20]
    [destination : (MutPtr i64)
      (unsafe
        (ptr-addr-of first))]
    [old : i64
      (unsafe
        (atomic-fetch-add!
          destination
          (begin
            (set! destination (ptr-addr-of second))
            5)))]
    (and (= old 10) (= first 15) (= second 20))))

(define (atomic-cas-ok?) : bool
  (let
    [first : i64 10]
    [second : i64 20]
    [expected : i64 10]
    [destination : (MutPtr i64)
      (unsafe
        (ptr-addr-of first))]
    [old : i64
      (unsafe
        (atomic-cas!
          destination
          expected
          (begin
            (set! destination (ptr-addr-of second))
            (set! expected 20)
            99)))]
    (and (= old 10) (= first 99) (= second 20) (= expected 20))))

(define (main) : i64
  (cond
    [(not (offset-ok?)) 1]
    [(not (write-ok?)) 2]
    [(not (atomic-store-ok?)) 3]
    [(not (volatile-store-ok?)) 4]
    [(not (atomic-fetch-add-ok?)) 5]
    [(not (atomic-cas-ok?)) 6]
    [else 42]))