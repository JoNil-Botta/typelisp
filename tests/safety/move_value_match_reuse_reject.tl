;; A variable in a `match` arm is moved with the `match`'s consumed value.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (consume [h : FileHandle]) : i64
  (let
    [fd : i64 h.fd]
    (begin
      (cleanup-file-handle h)
      fd)))

(defenum Mode
  (Fast)
  (Slow))

(define (pick [mode : Mode] [x : FileHandle] [z : FileHandle]) : i64
  (+
    (consume
      (match mode
        [(Mode.Fast) x]
        [(Mode.Slow) z]))
    (consume x)))

(define (main) : i64
  (pick Mode.Fast (FileHandle 41) (FileHandle 1)))