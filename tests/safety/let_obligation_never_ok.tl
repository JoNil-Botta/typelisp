;; No cleanup runs on a never edge, including a moved non-move-aware with owner.
(import stdlib.io)

(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(define (never-let) : never
  (let
    [h : Handle (Handle 1)]
    (io.panic "no normal exit")))

(define (never-with) : never
  (with
    ([h (Handle 2) cleanup-handle])
    (cleanup-handle h)
    (io.panic "no normal exit")))

(define (both-never [flag : bool]) : never
  (let
    [h : Handle (Handle 3)]
    (if flag
      (begin
        (cleanup-handle h)
        (io.panic "first"))
      (io.panic "second"))))

(define (select [mode : i64]) : i64
  (if (= mode 0)
    (never-let)
    (if (= mode 1)
      (never-with)
      (if (= mode 2)
        (both-never true)
        42))))

(define (main) : i64
  (select 3))