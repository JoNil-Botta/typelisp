;; The same parent/child lifetime rule applies to exclusive Slice views.
(define (main) : i64
  (let
    [items : (Array i64 4) (array 10 20 30 40)]
    [parent : (&mut items (Slice i64)) (slice-mut-view items 0 4)]
    [child : (&mut items (Slice i64)) (slice-mut-view parent 1 2)]
    (begin
      (set! (array-ref items 0) 99)
      (array-ref child 0))))