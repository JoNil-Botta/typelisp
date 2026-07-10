;: #2610: moving a cleanup-owned dotted field must follow the tracked path.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct FileHandle
  (:cleanup cleanup-file-handle)
  (fd i64 (:cleanup close-fd)))

(defstruct Holder
  (:cleanup cleanup-holder)
  (handle FileHandle (:owned))
  (size i64))

(define (take-handle [_handle : FileHandle]) : unit
  unit)

(define (main) : i64
  (with
    ([h (Holder (FileHandle 7) 1) cleanup-holder])
    (begin
      (take-handle h.handle)
      0)))