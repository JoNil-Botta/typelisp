(extern foreign-word (:symbol "tl-data-word") : i64)
(extern foreign-float (:symbol "tl_data_float") : f32)
(extern foreign-byte (:symbol "tl_data_byte") : u8)
(extern plain : i64)
(extern (check-data [phase : i64]) : i64 (:symbol "tl_data_check"))

(define local-word : i64
  7)

(define (store [value : i64] [poke : i64]) : unit
  (if (< poke 0)
    (store value (+ poke 1))
    (begin
      (set! foreign-word value)
      (set! foreign-float 13.5)
      (set! foreign-byte (cast 254 : u8))
      (set! plain 19)
      (set! local-word 9))))

(define (address [poke : i64]) : (MutPtr i64)
  (if (< poke 0)
    (address (+ poke 1))
    (unsafe
      (ptr-addr-of foreign-word))))

(define (main) : i64
  (if (and
    (= foreign-word 7)
    (= (cast foreign-float : i64) 42)
    (= (cast foreign-byte : i64) 255)
    (= plain 17)
    (= local-word 7))
    (begin
      (store 40 0)
      (if (and
        (= foreign-word 40)
        (= (cast foreign-float : i64) 13)
        (= (cast foreign-byte : i64) 254)
        (= plain 19)
        (= local-word 9)
        (= (check-data 0) 1))
        (begin
          (unsafe
            (ptr-write! (address 0) 42)
            (ptr-write! (ptr-addr-of foreign-float) 15.25)
            (ptr-write! (ptr-addr-of foreign-byte) (cast 253 : u8))
            (ptr-write! (ptr-addr-of plain) 21)
            (ptr-write! (ptr-addr-of local-word) 11))
          (if (and
            (= foreign-word 42)
            (= (cast foreign-float : i64) 15)
            (= (cast foreign-byte : i64) 253)
            (= plain 21)
            (= local-word 11)
            (= (check-data 1) 1))
            42
            3))
        2))
    1))