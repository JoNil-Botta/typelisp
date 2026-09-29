;; A mutable bytes view needs a mutable source; a shared view never becomes one.
(define (main) : i64
  (let
    [items : (Array u8 2) (array (cast 1 : u8) (cast 2 : u8))]
    [shared : (& items bytes) (__tl_bytes-view items 0 2)]
    [writable : (&mut items bytes) (__tl_bytes-mut-view shared 0 1)]
    0))