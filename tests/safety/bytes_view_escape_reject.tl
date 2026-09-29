;; A bytes view cannot outlive the array it views.
(define (escape) : (& static bytes)
  (let
    [items : (Array u8 2) (array (cast 1 : u8) (cast 2 : u8))]
    (__tl_bytes-view items 0 2)))

(define (main) : i64
  (begin
    (escape)
    0))