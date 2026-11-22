;; A frame address plus a scaled index: `%a = addr_of %cell ; %t = mul %i, 8 ;
;; %u = add %a, %t` (the index is 0, so the read is `cell` itself). The single-use addr-of is forwarded, so its allocator home
;; never receives the address and the backend's LEA pair must not read it as
;; the base register.
(import stdlib.io)

(define (main) : i64
  (let
    [cell : i64 30]
    [i : u64 (cast (- (io.arg-count) 1) : u64)]
    [addr : u64
      (+
        (unsafe
          (ptr->int (ptr-addr-of cell)))
        (* i 8))]
    (io.println
      "{}"
      (unsafe
        (ptr-read (int->ptr addr : (Ptr i64)))))
    0))