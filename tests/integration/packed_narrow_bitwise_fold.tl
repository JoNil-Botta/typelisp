;; Each packed layout fills one register word. Smaller structs below also
;; retain their memory-storage behavior.
(defstruct PackedI8
  (low i8)
  (high i8)
  (tag i16)
  (tail i32))

(defstruct PackedI16
  (low i16)
  (high i16)
  (tail i32))

(defstruct PackedI32
  (low i32)
  (high i32))

(defstruct SmallI8
  (low i8)
  (high i8))

(defstruct SmallI16
  (low i16)
  (high i16))

(define (forward-i8 [value : PackedI8]) : PackedI8
  value)

(define (forward-i16 [value : PackedI16]) : PackedI16
  value)

(define (forward-i32 [value : PackedI32]) : PackedI32
  value)

(define (matches-i8 [value : PackedI8] [low : i8] [high : i8]) : bool
  (and
    (= value.low low)
    (= value.high high)
    (= value.tag (cast 11 : i16))
    (= value.tail (cast 13 : i32))))

(define (matches-i16 [value : PackedI16] [low : i16] [high : i16]) : bool
  (and (= value.low low) (= value.high high) (= value.tail (cast 13 : i32))))

(define (matches-i32 [value : PackedI32] [low : i32] [high : i32]) : bool
  (and (= value.low low) (= value.high high)))

(define (main) : i64
  (let
    [small8 : SmallI8 (SmallI8 (cast -3 : i8) (cast 7 : i8))]
    [small16 : SmallI16 (SmallI16 (cast -3 : i16) (cast 7 : i16))]
    (if (and
      (= small8.low (cast -3 : i8))
      (= small8.high (cast 7 : i8))
      (= small16.low (cast -3 : i16))
      (= small16.high (cast 7 : i16))
      (matches-i8
        (forward-i8
          (PackedI8
            (cast -128 : i8)
            (cast 7 : i8)
            (cast 11 : i16)
            (cast 13 : i32)))
        (cast -128 : i8)
        (cast 7 : i8))
      (matches-i8
        (forward-i8
          (PackedI8
            (cast -3 : i8)
            (cast 7 : i8)
            (cast 11 : i16)
            (cast 13 : i32)))
        (cast -3 : i8)
        (cast 7 : i8))
      (matches-i8
        (forward-i8
          (PackedI8
            (cast -1 : i8)
            (cast 7 : i8)
            (cast 11 : i16)
            (cast 13 : i32)))
        (cast -1 : i8)
        (cast 7 : i8))
      (matches-i8
        (forward-i8
          (PackedI8 (cast 0 : i8) (cast 7 : i8) (cast 11 : i16) (cast 13 : i32)))
        (cast 0 : i8)
        (cast 7 : i8))
      (matches-i8
        (forward-i8
          (PackedI8
            (cast 127 : i8)
            (cast 7 : i8)
            (cast 11 : i16)
            (cast 13 : i32)))
        (cast 127 : i8)
        (cast 7 : i8))
      (matches-i8
        (forward-i8
          (PackedI8
            (cast -3 : i8)
            (cast -7 : i8)
            (cast 11 : i16)
            (cast 13 : i32)))
        (cast -3 : i8)
        (cast -7 : i8))
      (matches-i8
        (forward-i8
          (PackedI8
            (cast -3 : i8)
            (cast 127 : i8)
            (cast 11 : i16)
            (cast 13 : i32)))
        (cast -3 : i8)
        (cast 127 : i8))
      (matches-i16
        (forward-i16
          (PackedI16 (cast -32768 : i16) (cast 7 : i16) (cast 13 : i32)))
        (cast -32768 : i16)
        (cast 7 : i16))
      (matches-i16
        (forward-i16 (PackedI16 (cast -3 : i16) (cast 7 : i16) (cast 13 : i32)))
        (cast -3 : i16)
        (cast 7 : i16))
      (matches-i16
        (forward-i16 (PackedI16 (cast -1 : i16) (cast 7 : i16) (cast 13 : i32)))
        (cast -1 : i16)
        (cast 7 : i16))
      (matches-i16
        (forward-i16 (PackedI16 (cast 0 : i16) (cast 7 : i16) (cast 13 : i32)))
        (cast 0 : i16)
        (cast 7 : i16))
      (matches-i16
        (forward-i16
          (PackedI16 (cast 32767 : i16) (cast 7 : i16) (cast 13 : i32)))
        (cast 32767 : i16)
        (cast 7 : i16))
      (matches-i16
        (forward-i16
          (PackedI16 (cast -3 : i16) (cast -123 : i16) (cast 13 : i32)))
        (cast -3 : i16)
        (cast -123 : i16))
      (matches-i16
        (forward-i16
          (PackedI16 (cast -3 : i16) (cast 32767 : i16) (cast 13 : i32)))
        (cast -3 : i16)
        (cast 32767 : i16))
      (matches-i32
        (forward-i32 (PackedI32 (cast -2147483648 : i32) (cast 7 : i32)))
        (cast -2147483648 : i32)
        (cast 7 : i32))
      (matches-i32
        (forward-i32 (PackedI32 (cast -3 : i32) (cast 7 : i32)))
        (cast -3 : i32)
        (cast 7 : i32))
      (matches-i32
        (forward-i32 (PackedI32 (cast -1 : i32) (cast 7 : i32)))
        (cast -1 : i32)
        (cast 7 : i32))
      (matches-i32
        (forward-i32 (PackedI32 (cast 0 : i32) (cast 7 : i32)))
        (cast 0 : i32)
        (cast 7 : i32))
      (matches-i32
        (forward-i32 (PackedI32 (cast 2147483647 : i32) (cast 7 : i32)))
        (cast 2147483647 : i32)
        (cast 7 : i32))
      (matches-i32
        (forward-i32 (PackedI32 (cast -3 : i32) (cast -123456 : i32)))
        (cast -3 : i32)
        (cast -123456 : i32))
      (matches-i32
        (forward-i32 (PackedI32 (cast -3 : i32) (cast 2147483647 : i32)))
        (cast -3 : i32)
        (cast 2147483647 : i32)))
      42
      1)))