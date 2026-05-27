(define (main) : i64
  (begin
    (let
      [i64-zero : i64 (shl 1 0)]
      (let
        [i64-max : i64 (shr 1 63)]
        (let
          [u64-max : u64 (shr (cast -1 : u64) 63)]
          (let
            [u8-max : u8 (shr (cast 128 : u8) (cast 7 : u8))]
            (if (and
              (and (= i64-zero 1) (= i64-max 0))
              (and (= u64-max (cast 1 : u64)) (= u8-max (cast 1 : u8))))
              42
              1)))))))