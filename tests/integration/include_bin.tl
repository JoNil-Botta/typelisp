(include-bin payload "include_bin_payload.bin")

(define (byte-at [items : (Array u8)] [idx : i64]) : i64
  (cast (array-ref items idx) : i64))

(define (main) : i64
  (if (and
    (= (array-length payload) 6)
    (= (byte-at payload 0) 0)
    (= (byte-at payload 1) 65)
    (= (byte-at payload 2) 127)
    (= (byte-at payload 3) 128)
    (= (byte-at payload 4) 255)
    (= (byte-at payload 5) 10))
    42
    1))