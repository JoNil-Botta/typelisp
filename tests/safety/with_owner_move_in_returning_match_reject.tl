(define (close-fd [fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (steal [h : FileHandle]) : i64
  (with ([owned h cleanup-file-handle]) owned.fd))

(defenum Mode
  (Fast)
  (Slow))

(define (pick [mode : Mode]) : i64
  (with
    ([h (FileHandle 3) cleanup-file-handle])
    (begin
      (match mode
        [(Mode.Fast) (return (steal h))]
        [(Mode.Slow) unit])
      7)))

(define (main) : i64
  (pick (Mode.Slow)))