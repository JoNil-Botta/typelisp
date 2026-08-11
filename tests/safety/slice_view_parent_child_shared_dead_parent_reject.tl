;; Even when the parent binding is dead, its live shared child keeps the
;; original owner borrowed until the child's last use.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [parent : (& items (Slice i64)) (slice-view items 0 4)]
    [child : (& items (Slice i64)) (slice-view parent 1 2)]
    (begin
      (set! (array-ref items 0) 99)
      (array-ref child 0))))