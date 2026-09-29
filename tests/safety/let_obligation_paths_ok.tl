;; Every discharge edge of an ordinary `let` owner, each run once: main returns
;; 42 only when exactly 13 handles were cleaned.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(defstruct Pair
  (:cleanup cleanup-pair)
  (a FileHandle (:owned))
  (b i64))

(defenum Outcome
  (Ok i64)
  (Err i64))

(define (open [fd : i64]) : FileHandle
  (FileHandle fd))

(define (read-fd [h : (& h FileHandle)]) : i64
  h.fd)

(define (early-return [failed : bool]) : i64
  (let
    [h : FileHandle (open 1)]
    (begin
      (if failed
        (begin
          (cleanup-file-handle h)
          (return -1))
        unit)
      (let
        [fd : i64 (read-fd (& h))]
        (begin
          (cleanup-file-handle h)
          fd)))))

(define (both-arms [c : bool]) : i64
  (let
    [h : FileHandle (open 2)]
    (begin
      (if c
        (cleanup-file-handle h)
        (cleanup-file-handle h))
      0)))

(define (match-arms [r : Outcome]) : i64
  (let
    [h : FileHandle (open 3)]
    (match r
      [(Outcome.Ok v)
        (begin
          (cleanup-file-handle h)
          v)]
      [(Outcome.Err e)
        (begin
          (cleanup-file-handle h)
          e)])))

(define (loop-owners [n : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (let
          [h : FileHandle (open i)]
          (begin
            (cleanup-file-handle h)
            (set! i (+ i 1)))))
      i)))

(define (break-owner) : i64
  (begin
    (while true
      (let
        [h : FileHandle (open 4)]
        (begin
          (cleanup-file-handle h)
          (break))))
    0))

(define (to-let) : i64
  (let
    [h : FileHandle (open 5)]
    (let
      [g : FileHandle h]
      (begin
        (cleanup-file-handle g)
        0))))

(define (to-with) : i64
  (let
    [h : FileHandle (open 6)]
    (with ([w h cleanup-file-handle]) (read-fd (& w)))))

(define (to-aggregate) : i64
  (let
    [h : FileHandle (open 7)]
    (let
      [p : Pair (Pair h 8)]
      (let
        [b : i64 p.b]
        (begin
          (cleanup-pair p)
          b)))))

(define (returned) : FileHandle
  (let
    [h : FileHandle (open 9)]
    (return h)))

(define (as-value) : FileHandle
  (let
    [h : FileHandle (open 10)]
    (begin
      (read-fd (& h))
      h)))

(define (callers) : i64
  (let
    [a : FileHandle (returned)]
    [b : FileHandle (as-value)]
    (begin
      (cleanup-file-handle a)
      (cleanup-file-handle b)
      0)))

(define (main) : i64
  (begin
    (early-return true)
    (early-return false)
    (both-arms true)
    (match-arms (Outcome.Ok 1))
    (loop-owners 3)
    (break-owner)
    (to-let)
    (to-with)
    (to-aggregate)
    (callers)
    (+ closes 29)))