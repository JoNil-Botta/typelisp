;; Check-only: unsafe context cannot erase a callable's unsafe effect.
(import stdlib.string)

(define (main) : i64
  (unsafe
    (let
      [_copy : (-> (Ptr u8) (MutPtr u8) i64 i64 unit)
        string.str-copy-bytes-into]
      42)))