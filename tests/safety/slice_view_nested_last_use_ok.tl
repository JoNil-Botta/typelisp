;; A nested shared child releases the original fixed owner after its final use.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [parent : (& items (Slice i64)) (slice-view items 0 4)]
    [child : (& items (Slice i64)) (slice-view parent 1 2)]
    (begin
      (array-ref child 0)
      (set! (array-ref items 0) 42)
      (array-ref items 0))))