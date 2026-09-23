;; Passing an aggregate to a C function never allocates, and a callee that
;; writes its parameter never changes the caller's value. Win64 passes an
;; aggregate wider than 8 bytes by reference: the caller hands the callee the
;; address of a private copy, which is a frame temporary of the caller, not an
;; arena allocation (#7885). SysV passes these same aggregates by value in
;; registers or on the stack. Every case calls C callees that overwrite their
;; aggregate parameter in a loop and measures `profile.alloc-total` around the
;; loop. `main` yields 42 only if no window allocates, every callee saw the
;; right values, and no callee write reached the caller's value.
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

(extern (pair-bump [p : Pair] [k : i64]) : i64 (:symbol "tl_win64_byref_pair_bump"))
(extern (triple-bump [t : Triple] [k : i64]) : i64 (:symbol "tl_win64_byref_triple_bump"))
(extern (choice-bump [c : Choice] [k : i64]) : i64 (:symbol "tl_win64_byref_choice_bump"))
(extern (pair-clobber-first [x : Pair] [y : Pair]) : i64 (:symbol "tl_win64_byref_pair_clobber_first"))
(extern (triple-clobber-first [x : Triple] [y : Triple]) : i64 (:symbol "tl_win64_byref_triple_clobber_first"))
(extern (pair-make [seed : i64]) : Pair (:symbol "tl_win64_byref_pair_make"))

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
;; both arguments of one call. This case checks values only: on Win64 the
;; 16-byte `pair-make` result comes back through a hidden-sret buffer that is
;; still an arena allocation (#7990).
(define (case-call-result) : i64
  (let
    [sum : i64 0]
    [pair-sum : i64 0]
    [i : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (set! sum (+ sum (pair-bump (pair-make i) 0)))
          (set!
            pair-sum
            (+ pair-sum (pair-clobber-first (pair-make i) (pair-make (+ i 1)))))
          (set! i (+ i 1))))
      ;; pair-make i = (i, 2i + 1); its sum is 3i + 1.
      (unless
        (= sum (+ rounds (* 3 (/ (* rounds (- rounds 1)) 2))))
        (return 41))
      (unless
        (= pair-sum (+ (* rounds 4) (* 3 (/ (* rounds (- rounds 1)) 2))))
        (return 42))
      0)))

(define (main) : i64
  (let
    [pair : i64 (case-pair)]
    [triple : i64 (case-triple)]
    [choice : i64 (case-choice)]
    [two-args : i64 (case-two-args)]
    [call-result : i64 (case-call-result)]
    (cond
      [(not (= pair 0)) pair]
      [(not (= triple 0)) triple]
      [(not (= choice 0)) choice]
      [(not (= two-args 0)) two-args]
      [(not (= call-result 0)) call-result]
      [else 42])))