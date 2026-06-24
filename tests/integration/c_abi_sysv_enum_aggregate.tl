;; #1985: Linux System V enum aggregate C ABI. Payload enums use the default
;; TypeLisp tagged-union layout: int64 tag at offset 0, payload union at offset 8.
(defenum SmallChoice
  (SmallNone)
  (SmallSome i64))

(defstruct WrappedSmall
  (choice SmallChoice))

(defenum FloatChoice
  (FloatNone)
  (FloatSome f64))

(defenum WideChoice
  (WideNone)
  (WideSome u64 u64))

(extern (small-score [arg : SmallChoice] [bias : i64]) : i64 (:symbol "tl_cabi_small_choice_score"))
(extern small-scorer (:symbol "tl_cabi_small_choice_score_ptr") : (->
  SmallChoice
  i64
  i64))
(extern (small-make [seed : i64] [make-some : i64]) : SmallChoice (:symbol "tl_cabi_small_choice_make"))
(extern (wrapped-small-score [arg : WrappedSmall] [bias : i64]) : i64 (:symbol "tl_cabi_wrapped_small_score"))
(extern (wrapped-small-make [seed : i64]) : WrappedSmall (:symbol "tl_cabi_wrapped_small_make"))
(extern (float-score [arg : FloatChoice] [bias : i64]) : i64 (:symbol "tl_cabi_float_choice_score"))
(extern float-scorer (:symbol "tl_cabi_float_choice_score_ptr") : (->
  FloatChoice
  i64
  i64))
(extern (float-make [seed : f64] [make-some : i64]) : FloatChoice (:symbol "tl_cabi_float_choice_make"))
(extern (wide-score [arg : WideChoice] [salt : u64]) : i64 (:symbol "tl_cabi_wide_choice_score"))
(extern wide-scorer (:symbol "tl_cabi_wide_choice_score_ptr") : (->
  WideChoice
  u64
  i64))
(extern (wide-make [seed : u64]) : WideChoice (:symbol "tl_cabi_wide_choice_make"))

(define (small-value [s : SmallChoice]) : i64
  (match s
    [SmallNone -1]
    [(SmallSome value) value]))

(define (wrapped-small-value [w : WrappedSmall]) : i64
  (small-value (struct-get w choice)))

(define (float-value [f : FloatChoice]) : i64
  (match f
    [FloatNone -1]
    [(FloatSome value) (cast value : i64)]))

(define (wide-value [w : WideChoice]) : i64
  (match w
    [WideNone -1]
    [(WideSome lo hi) (+ (cast lo : i64) (* 2 (cast hi : i64)))]))

(define (main) : i64
  (let
    [small-copy : (-> SmallChoice i64 i64) small-scorer]
    [float-copy : (-> FloatChoice i64 i64) float-scorer]
    [wide-copy : (-> WideChoice u64 i64) wide-scorer]
    [small-direct : i64 (small-score (SmallSome 11) 5)]
    [small-via-ptr : i64 (small-copy (SmallNone) 7)]
    [small-made : SmallChoice (small-make 9 1)]
    [wrapped-direct : i64 (wrapped-small-score (WrappedSmall (SmallSome 12)) 8)]
    [wrapped-made : WrappedSmall (wrapped-small-make 6)]
    [float-direct : i64 (float-score (FloatSome 2.5) 3)]
    [float-via-ptr : i64 (float-copy (FloatNone) 4)]
    [float-made : FloatChoice (float-make 4.25 1)]
    [wide-direct : i64
      (wide-score (WideSome (cast 2 : u64) (cast 3 : u64)) (cast 4 : u64))]
    [wide-via-ptr : i64 (wide-copy (WideNone) (cast 6 : u64))]
    [wide-made : WideChoice (wide-make (cast 10 : u64))]
    (begin
      (unless (= small-direct 38) (return 1))
      (unless (= small-via-ptr 1007) (return 2))
      (unless (= (small-value small-made) 49) (return 3))
      (unless (= wrapped-direct 92) (return 4))
      (unless (= (wrapped-small-value wrapped-made) 66) (return 5))
      (unless (= float-direct 28) (return 6))
      (unless (= float-via-ptr 2004) (return 7))
      (unless (= (float-value float-made) 5) (return 8))
      (unless (= wide-direct 35) (return 9))
      (unless (= wide-via-ptr 3006) (return 10))
      (unless (= (wide-value wide-made) 85) (return 11))
      42)))