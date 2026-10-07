;; A struct field of the entry's exact type keeps the unsafe effect, so a
;; safe call through it is rejected (#7742). Check-only; never executed.
(import stdlib.thread)

(defstruct Holder
  (entry (CFunc unsafe-non-null (-> i64 i64))))

(define (main) : i64
  (let
    [holder : Holder (Holder thread.thread-windows-entry)]
    (holder.entry 0)))