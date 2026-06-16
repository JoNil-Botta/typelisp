;; Refs #2893: scalar f32 in C ABI extern parameters and returns.
;;
;; Each extern is declared with scalar `f32` parameters and/or an `f32` return
;; type and linked against the C baseline in
;; benchmarks/c_abi_f32_scalar/baseline.c. The values are exactly representable
;; in IEEE-754 binary32, so single-precision arithmetic is exact and the checks
;; below use plain equality. `main` returns 42 only when every f32 extern call
;; lowers its XMM-register arguments and return value to match the C ABI.
(extern (f32-add [a : f32] [b : f32]) : f32 (:symbol "tl_cabi_f32_add"))
(extern (f32-scale [a : f32] [b : f32] [c : f32]) : f32 (:symbol "tl_cabi_f32_scale"))

;; Nine f32 arguments forces the ninth onto the System V stack (and past the
;; four positional Win64 register slots); it is returned unchanged.
(extern (f32-ninth
  [a : f32]
  [b : f32]
  [c : f32]
  [d : f32]
  [e : f32]
  [f : f32]
  [g : f32]
  [h : f32]
  [i : f32]) : f32 (:symbol "tl_cabi_f32_ninth"))

;; Interleaved integer/float arguments exercise the System V independent
;; integer/SSE register counters and the Windows shared positional slots.
(extern (f32-mix [n : i64] [x : f32] [m : i64] [y : f32]) : f32 (:symbol "tl_cabi_f32_mix"))

;; f32 argument with an integer return value (result in %rax).
(extern (f32-to-i64 [x : f32]) : i64 (:symbol "tl_cabi_f32_to_i64"))

(define (main) : i64
  (let
    [a : f32 2.0]
    [b : f32 3.0]
    ;; 2 + 3 = 5
    [sum : f32 (f32-add a b)]
    ;; 2 * 3 + 1 = 7
    [scaled : f32 (f32-scale a b 1.0)]
    ;; ninth argument returned unchanged = 9
    [ninth : f32 (f32-ninth 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0)]
    ;; (10 + 20) + 0.5 + 0.25 = 30.75
    [mixed : f32 (f32-mix 10 0.5 20 0.25)]
    ;; truncate the f32 result 7.0 back to an i64
    [t : i64 (f32-to-i64 scaled)]
    [s1 : i64
      (if (= sum 5.0)
        10
        0)]
    [s2 : i64
      (if (= scaled 7.0)
        10
        0)]
    [s3 : i64
      (if (= ninth 9.0)
        8
        0)]
    [s4 : i64
      (if (= mixed 30.75)
        7
        0)]
    [s5 : i64
      (if (= t 7)
        7
        0)]
    ;; 10 + 10 + 8 + 7 + 7 = 42
    (+ s1 (+ s2 (+ s3 (+ s4 s5))))))