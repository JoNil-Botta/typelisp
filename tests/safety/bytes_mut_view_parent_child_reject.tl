;; A mutable parent view cannot be reborrowed mutably while a shared child view
;; of it is live.
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [items : (Array u8 4)
      (array (cast 1 : u8) (cast 2 : u8) (cast 3 : u8) (cast 4 : u8))]
    [parent : (&mut items bytes) (__tl_bytes-mut-view items 0 4)]
    [child : (& items bytes) (__tl_bytes-view parent 1 2)]
    [again : (&mut items bytes) (__tl_bytes-mut-view parent 0 1)]
    (byte_buf.bytes-length child)))