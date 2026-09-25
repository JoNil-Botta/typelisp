;; Passing an aggregate to a C function or receiving one from it never
;; allocates, and a callee that writes its parameter never changes the caller's
;; value. Win64 passes an aggregate wider than 8 bytes by reference: the caller
;; hands the callee the address of a private copy, which is a frame temporary
;; of the caller, not an arena allocation (#7885). SysV passes these same
;; aggregates by value in registers or on the stack. A result that comes back
;; through a hidden result pointer, in two registers, or in one register but is
;; kept in memory by TypeLisp lands in caller frame storage too (#7990). Every
;; case calls C in a loop and measures `profile.alloc-total` around the loop.
;; `main` yields 42 only if no window allocates, every callee saw the right
;; values, no callee write reached the caller's value, and every result, even
;; one kept live across the next call to the same C function, reads back intact.
(import stdlib.profile)

;; 16 bytes: register-resident in TypeLisp, by reference on Win64.
(defstruct Pair
  (:repr c)
  (a i64)
  (b i64))

;; 24 bytes: memory-class in TypeLisp, by reference on Win64.
(defstruct Triple
  (:repr c)
  (a i64)
  (b i64)
  (c i64))

;; Tag plus a two-word payload: 24 bytes, by reference on Win64.
(defenum Choice
  (ChoiceNone)
  (ChoiceSome i64 i64))

;; 16 bytes: returned in RAX and XMM0 on SysV, through sret on Win64.
(defstruct IntDouble
  (:repr c)
  (a i64)
  (b f64))

;; 8 bytes: returned in RAX on both, but kept in memory by TypeLisp.
(defstruct IntFloat
  (:repr c)
  (a i32)
  (b f32))

(extern (pair-bump [p : Pair] [k : i64]) : i64 (:symbol "tl_win64_byref_pair_bump"))
(extern (triple-bump [t : Triple] [k : i64]) : i64 (:symbol "tl_win64_byref_triple_bump"))
(extern (choice-bump [c : Choice] [k : i64]) : i64 (:symbol "tl_win64_byref_choice_bump"))
(extern (pair-clobber-first [x : Pair] [y : Pair]) : i64 (:symbol "tl_win64_byref_pair_clobber_first"))
(extern (triple-clobber-first [x : Triple] [y : Triple]) : i64 (:symbol "tl_win64_byref_triple_clobber_first"))
(extern (pair-make [seed : i64]) : Pair (:symbol "tl_win64_byref_pair_make"))
(extern (triple-make [seed : i64]) : Triple (:symbol "tl_cabi_noalloc_triple_make"))
(extern triple-maker (:symbol "tl_cabi_noalloc_triple_make_ptr") : (CFunc
  non-null
  (-> i64 Triple)))
(extern (choice-make [seed : i64]) : Choice (:symbol "tl_cabi_noalloc_choice_make"))
(extern (int-double-make [seed : i64]) : IntDouble (:symbol "tl_cabi_noalloc_int_double_make"))
(extern (int-float-make [seed : i32]) : IntFloat (:symbol "tl_cabi_noalloc_int_float_make"))

(define rounds : i64
  64)

(define (case-pair) : i64
  (let
    [pair : Pair (Pair 3 4)]
    [sum : i64 0]
    [i : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i rounds)
        (begin
          ;; The callee adds 1000 to both fields of its copy and returns
          ;; the sum it saw before writing, plus `k`.
          (set! sum (+ sum (pair-bump pair i)))
          (set! i (+ i 1))))
      (unless (= (profile.alloc-total) before) (return 1))
      (unless (= sum (+ (* rounds 7) (/ (* rounds (- rounds 1)) 2))) (return 2))
      (unless (= pair.a 3) (return 3))
      (unless (= pair.b 4) (return 4))
      0)))

(define (case-triple) : i64
  (let
    [triple : Triple (Triple 5 6 7)]
    [sum : i64 0]
    [i : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i rounds)
        (begin
          (set! sum (+ sum (triple-bump triple i)))
          (set! i (+ i 1))))
      (unless (= (profile.alloc-total) before) (return 11))
      (unless
        (= sum (+ (* rounds 18) (/ (* rounds (- rounds 1)) 2)))
        (return 12))
      (unless (= triple.a 5) (return 13))
      (unless (= triple.b 6) (return 14))
      (unless (= triple.c 7) (return 15))
      0)))

(define (choice-payload-sum [c : Choice]) : i64
  (match c
    [(ChoiceNone) (- 0 1)]
    [(ChoiceSome x y) (+ x y)]))

(define (case-choice) : i64
  (let
    [choice : Choice (ChoiceSome 8 9)]
    [none : Choice (ChoiceNone)]
    [sum : i64 0]
    [none-sum : i64 0]
    [i : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i rounds)
        (begin
          (set! sum (+ sum (choice-bump choice i)))
          (set! none-sum (+ none-sum (choice-bump none i)))
          (set! i (+ i 1))))
      (unless (= (profile.alloc-total) before) (return 21))
      (unless
        (= sum (+ (* rounds 17) (/ (* rounds (- rounds 1)) 2)))
        (return 22))
      (unless
        (= none-sum (+ (* rounds 500) (/ (* rounds (- rounds 1)) 2)))
        (return 23))
      (unless (= (choice-payload-sum choice) 17) (return 24))
      (unless (= (choice-payload-sum none) (- 0 1)) (return 25))
      0)))

;; Two aggregate arguments in one call get distinct copies even when both come
;; from the same value: the callee overwrites `x` and then reads `y`.
(define (case-two-args) : i64
  (let
    [pair : Pair (Pair 1 2)]
    [triple : Triple (Triple 3 4 5)]
    [pair-sum : i64 0]
    [triple-sum : i64 0]
    [i : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i rounds)
        (begin
          (set! pair-sum (+ pair-sum (pair-clobber-first pair pair)))
          (set!
            triple-sum
            (+ triple-sum (triple-clobber-first triple (Triple i i i))))
          (set! i (+ i 1))))
      (unless (= (profile.alloc-total) before) (return 31))
      (unless (= pair-sum (* rounds 3)) (return 32))
      (unless (= triple-sum (* 3 (/ (* rounds (- rounds 1)) 2))) (return 33))
      (unless (= (+ pair.a pair.b) 3) (return 34))
      (unless (= (+ triple.a (+ triple.b triple.c)) 12) (return 35))
      0)))

;; A call result passed straight on as an aggregate argument, alone and as
;; both arguments of one call. On Win64 the 16-byte `pair-make` result comes
;; back through a hidden-sret frame buffer.
(define (case-call-result) : i64
  (let
    [sum : i64 0]
    [pair-sum : i64 0]
    [i : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i rounds)
        (begin
          (set! sum (+ sum (pair-bump (pair-make i) 0)))
          (set!
            pair-sum
            (+ pair-sum (pair-clobber-first (pair-make i) (pair-make (+ i 1)))))
          (set! i (+ i 1))))
      (unless (= (profile.alloc-total) before) (return 40))
      ;; pair-make i = (i, 2i + 1); its sum is 3i + 1.
      (unless
        (= sum (+ rounds (* 3 (/ (* rounds (- rounds 1)) 2))))
        (return 41))
      (unless
        (= pair-sum (+ (* rounds 4) (* 3 (/ (* rounds (- rounds 1)) 2))))
        (return 42))
      0)))

(define (triple-made? [t : Triple] [seed : i64]) : bool
  (and (= t.a seed) (= t.b (+ seed 100)) (= t.c (+ seed 200))))

;; Each iteration keeps the previous iteration's result live across the next
;; call through the same call site, directly and through a `CFunc`, so a
;; result buffer shared between executions of one call would overwrite it. A
;; ring holds copies of the last four results and must not alias any buffer.
(define (case-triple-result) : i64
  (let
    [prev : Triple (triple-make 0)]
    [prev-indirect : Triple (triple-maker 0)]
    [ring : (Array Triple 4)
      (array (Triple 0 0 0) (Triple 0 0 0) (Triple 0 0 0) (Triple 0 0 0))]
    [i : i64 1]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i rounds)
        (let
          [cur : Triple (triple-make i)]
          [cur-indirect : Triple (triple-maker (* i 2))]
          (begin
            (unless (triple-made? prev (- i 1)) (return 51))
            (unless (triple-made? prev-indirect (* (- i 1) 2)) (return 52))
            (unless (triple-made? cur i) (return 53))
            (unless (triple-made? cur-indirect (* i 2)) (return 54))
            (set! (array-ref ring (% i 4)) cur)
            (set! prev cur)
            (set! prev-indirect cur-indirect)
            (set! i (+ i 1)))))
      (unless (= (profile.alloc-total) before) (return 50))
      (unless
        (triple-made? (array-ref ring (% (- rounds 1) 4)) (- rounds 1))
        (return 55))
      (unless
        (triple-made? (array-ref ring (% (- rounds 4) 4)) (- rounds 4))
        (return 56))
      (unless (triple-made? prev (- rounds 1)) (return 57))
      0)))

(define (choice-made-sum [c : Choice]) : i64
  (match c
    [(ChoiceNone) (- 0 1)]
    [(ChoiceSome x y) (+ x y)]))

;; Payload enum results, alternating variants, with the previous one live.
(define (case-choice-result) : i64
  (let
    [prev : Choice (choice-make 0)]
    [sum : i64 0]
    [i : i64 1]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i rounds)
        (let
          [cur : Choice (choice-make i)]
          (begin
            (unless
              (=
                (choice-made-sum prev)
                (if (= (% (- i 1) 2) 0)
                  (* (- i 1) 4)
                  (- 0 1)))
              (return 61))
            (set! sum (+ sum (choice-made-sum cur)))
            (set! prev cur)
            (set! i (+ i 1)))))
      (unless (= (profile.alloc-total) before) (return 60))
      ;; Even i in [2, rounds) contribute 4i; odd ones contribute -1.
      (unless
        (=
          sum
          (- (* 4 (* 2 (/ (* (/ rounds 2) (- (/ rounds 2) 1)) 2))) (/ rounds 2)))
        (return 62))
      0)))

;; Mixed integer/float results: two registers on SysV and sret on Win64
;; (`IntDouble`), and one register holding a value that TypeLisp keeps in
;; memory (`IntFloat`).
(define (case-mixed-result) : i64
  (let
    [prev-wide : IntDouble (int-double-make 0)]
    [prev-small : IntFloat (int-float-make 0)]
    [i : i64 1]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< i rounds)
        (let
          [wide : IntDouble (int-double-make i)]
          [small : IntFloat (int-float-make (cast i : i32))]
          (begin
            (unless (= prev-wide.a (- i 1)) (return 71))
            (unless (= prev-wide.b (+ (cast (- i 1) : f64) 0.5)) (return 72))
            (unless (= (cast prev-small.a : i64) (- i 1)) (return 73))
            (unless
              (= prev-small.b (+ (cast (- i 1) : f32) (cast 0.25 : f32)))
              (return 74))
            (unless (= wide.a i) (return 75))
            (unless (= (cast small.a : i64) i) (return 76))
            (set! prev-wide wide)
            (set! prev-small small)
            (set! i (+ i 1)))))
      (unless (= (profile.alloc-total) before) (return 70))
      (unless (= prev-wide.a (- rounds 1)) (return 77))
      (unless (= (cast prev-small.a : i64) (- rounds 1)) (return 78))
      0)))

(define (main) : i64
  (let
    [pair : i64 (case-pair)]
    [triple : i64 (case-triple)]
    [choice : i64 (case-choice)]
    [two-args : i64 (case-two-args)]
    [call-result : i64 (case-call-result)]
    [triple-result : i64 (case-triple-result)]
    [choice-result : i64 (case-choice-result)]
    [mixed-result : i64 (case-mixed-result)]
    (cond
      [(not (= pair 0)) pair]
      [(not (= triple 0)) triple]
      [(not (= choice 0)) choice]
      [(not (= two-args 0)) two-args]
      [(not (= call-result 0)) call-result]
      [(not (= triple-result 0)) triple-result]
      [(not (= choice-result 0)) choice-result]
      [(not (= mixed-result 0)) mixed-result]
      [else 42])))