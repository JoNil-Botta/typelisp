(define (close-fd [fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(define (steal [h : FileHandle]) : i64
  (with ([owned h cleanup-file-handle]) owned.fd))

(define (main) : i64
  (let
    [i : i64 0]
    (begin
      (while (< i 3)
        (with
          ([h (FileHandle i) cleanup-file-handle])
          (begin
            (set! i (+ i 1))
            (if (= i 2)
              (begin
                (steal h)
                (break))
              unit)
            unit)))
      i)))