;; #1995: Linux System V two-eightbyte C aggregate returns.
;;
;; PairI64 proves INTEGER/INTEGER uses %rax then %rdx, MixIF and MixFI prove
;; mixed INTEGER/SSE returns use the first register in each bank according to the
;; eightbyte class, and PairF64 proves SSE/SSE uses %xmm0 then %xmm1.
(defstruct PairI64
  (:repr c)
  (lo i64)
  (hi i64))

(defstruct MixIF
  (:repr c)
  (tag i64)
  (value f64))

(defstruct MixFI
  (:repr c)
  (value f64)
  (tag i64))

(defstruct PairF64
  (:repr c)
  (x f64)
  (y f64))

(extern (pair-i64-make [seed : i64]) : PairI64 (:symbol "tl_cabi_pair_i64_make"))
(extern pair-i64-maker (:symbol "tl_cabi_pair_i64_make_ptr") : (-> i64 PairI64))
(extern (mix-if-make [seed : i64]) : MixIF (:symbol "tl_cabi_mix_if_make"))
(extern (mix-fi-make [seed : i64]) : MixFI (:symbol "tl_cabi_mix_fi_make"))
(extern (pair-f64-make [seed : i64]) : PairF64 (:symbol "tl_cabi_pair_f64_make"))

(define (main) : i64
  (let
    [pair : PairI64 (pair-i64-make 4)]
    [pair-copy : (-> i64 PairI64) pair-i64-maker]
    [pair-via-ptr : PairI64 (pair-copy 6)]
    [mix-if : MixIF (mix-if-make 5)]
    [mix-fi : MixFI (mix-fi-make 7)]
    [floats : PairF64 (pair-f64-make 10)]
    (begin
      (unless (= (struct-get pair lo) 14) (return 1))
      (unless (= (struct-get pair hi) 24) (return 2))
      (unless (= (struct-get pair-via-ptr lo) 36) (return 3))
      (unless (= (struct-get pair-via-ptr hi) 46) (return 4))
      (unless (= (struct-get mix-if tag) 8) (return 5))
      (unless (= (struct-get mix-if value) 9.0) (return 6))
      (unless (= (struct-get mix-fi value) 12.0) (return 7))
      (unless (= (struct-get mix-fi tag) 13) (return 8))
      (unless (= (struct-get floats x) 11.0) (return 9))
      (unless (= (struct-get floats y) 12.0) (return 10))
      42)))