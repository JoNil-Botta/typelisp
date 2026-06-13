(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

(defstruct InnerByteC
  (:repr c)
  (value u8))

(defstruct OuterByteC
  (:repr c)
  (inner InnerByteC))

(defstruct InnerPairDefault
  (lo u8)
  (hi u8))

(defstruct OuterPairC
  (:repr c)
  (inner InnerPairDefault))

(defstruct InnerWordC
  (:repr c)
  (lo u16)
  (hi u16))

(defstruct OuterWordDefault
  (inner InnerWordC))

(defstruct InnerDoubleC
  (:repr c)
  (value f64))

(defstruct OuterDoubleC
  (:repr c)
  (inner InnerDoubleC))

(defstruct WideInnerDefault
  (a u64)
  (b u64))

(defstruct WideOuterC
  (:repr c)
  (tag u32)
  (inner WideInnerDefault)
  (tail u32))

(extern (nested-byte-score [arg : OuterByteC] [tag : u64]) : i64 (:symbol "tl_cabi_nested_byte_score"))

(extern (nested-byte-make [tag : u64]) : OuterByteC (:symbol "tl_cabi_nested_byte_make"))

(extern (nested-pair-score [arg : OuterPairC] [tag : u64]) : i64 (:symbol "tl_cabi_nested_pair_score"))

(extern nested-pair-scorer (:symbol "tl_cabi_nested_pair_score_ptr") : (->
  OuterPairC
  u64
  i64))

(extern (nested-pair-make [tag : u64]) : OuterPairC (:symbol "tl_cabi_nested_pair_make"))

(extern (nested-word-score [arg : OuterWordDefault] [tag : u64]) : i64 (:symbol "tl_cabi_nested_word_score"))

(extern (nested-word-make [tag : u64]) : OuterWordDefault (:symbol "tl_cabi_nested_word_make"))

(extern (nested-double-score [arg : OuterDoubleC] [tag : u64]) : i64 (:symbol "tl_cabi_nested_double_score"))

(extern (nested-double-make [tag : u64]) : OuterDoubleC (:symbol "tl_cabi_nested_double_make"))

(extern nested-double-maker (:symbol "tl_cabi_nested_double_make_ptr") : (->
  u64
  OuterDoubleC))

(extern (nested-wide-score [arg : WideOuterC] [tag : u64]) : i64 (:symbol "tl_cabi_nested_wide_score"))

(extern nested-wide-scorer (:symbol "tl_cabi_nested_wide_score_ptr") : (->
  WideOuterC
  u64
  i64))

(extern (nested-wide-make [tag : u64]) : WideOuterC (:symbol "tl_cabi_nested_wide_make"))

(extern nested-wide-maker (:symbol "tl_cabi_nested_wide_make_ptr") : (->
  u64
  WideOuterC))

(define (main) : i64
  (let
    [byte-direct : i64
      (nested-byte-score (OuterByteC (InnerByteC (cast 7 : u8))) (cast 1 : u64))]
    [byte-returned : i64
      (nested-byte-score (nested-byte-make (cast 2 : u64)) (cast 2 : u64))]
    [pair-direct : i64
      (nested-pair-score
        (OuterPairC (InnerPairDefault (cast 3 : u8) (cast 4 : u8)))
        (cast 3 : u64))]
    [pair-returned : i64
      (nested-pair-score (nested-pair-make (cast 4 : u64)) (cast 4 : u64))]
    [pair-indirect : i64
      (nested-pair-scorer
        (OuterPairC (InnerPairDefault (cast 8 : u8) (cast 9 : u8)))
        (cast 5 : u64))]
    [word-direct : i64
      (nested-word-score
        (OuterWordDefault (InnerWordC (cast 100 : u16) (cast 200 : u16)))
        (cast 6 : u64))]
    [word-returned : i64
      (nested-word-score (nested-word-make (cast 7 : u64)) (cast 7 : u64))]
    [double-direct : i64
      (nested-double-score (OuterDoubleC (InnerDoubleC 1.5)) (cast 8 : u64))]
    [double-returned : i64
      (nested-double-score (nested-double-make (cast 9 : u64)) (cast 9 : u64))]
    [double-indirect-returned : i64
      (nested-double-score
        (nested-double-maker (cast 10 : u64))
        (cast 10 : u64))]
    [wide-direct-value : WideOuterC
      (WideOuterC
        (cast 11 : u32)
        (WideInnerDefault (cast 1000 : u64) (cast 2000 : u64))
        (cast 12 : u32))]
    [wide-direct : i64 (nested-wide-score wide-direct-value (cast 11 : u64))]
    [wide-indirect-value : WideOuterC
      (WideOuterC
        (cast 13 : u32)
        (WideInnerDefault (cast 3000 : u64) (cast 4000 : u64))
        (cast 14 : u32))]
    [wide-indirect : i64
      (nested-wide-scorer wide-indirect-value (cast 12 : u64))]
    [wide-returned : i64
      (nested-wide-score (nested-wide-make (cast 13 : u64)) (cast 13 : u64))]
    [wide-indirect-returned : i64
      (nested-wide-score (nested-wide-maker (cast 14 : u64)) (cast 14 : u64))]
    (core/cond
      (not (= byte-direct 11))
      1
      (not (= byte-returned 12))
      2
      (not (= pair-direct 21))
      3
      (not (= pair-returned 22))
      4
      (not (= pair-indirect 23))
      5
      (not (= word-direct 31))
      6
      (not (= word-returned 32))
      7
      (not (= double-direct 41))
      8
      (not (= double-returned 42))
      9
      (not (= double-indirect-returned 43))
      10
      (not (= wide-direct 51))
      11
      (not (= wide-indirect 52))
      12
      (not (= wide-returned 53))
      13
      (not (= wide-indirect-returned 54))
      14
      42)))