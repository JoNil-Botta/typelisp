;; #8894: a function with more float parameters than the ABI has float
;; argument registers copies its stack-passed float parameters into their
;; frame homes in the prologue. At opt2 that copy staged through the incoming
;; register of a float parameter the allocator had pinned there, overwriting
;; the parameter before its first read. Every value below is a small integer
;; and every partial sum is exact, so an overwritten argument changes the
;; result.
(defstruct PairF64
  (x f64)
  (y f64))

;; The issue's reproduction: System V passes i and j on the stack while c..h
;; stay in their incoming registers.
(define (fin
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [h : f64]
  [i : f64]
  [j : f64]) : i64
  (let
    [sum : f64
      (+
        a
        (+
          (* 11.0 b)
          (+
            (* 121.0 c)
            (+
              (* 1331.0 d)
              (+
                (* 14641.0 e)
                (+
                  (* 161051.0 f)
                  (+
                    (* 1771561.0 g)
                    (+
                      (* 19487171.0 h)
                      (+ (* 214358881.0 i) (* 2357947691.0 j))))))))))]
    [want : f64
      (+
        2.0
        (+
          (* 11.0 1.0)
          (+
            (* 121.0 4.0)
            (+
              (* 1331.0 3.0)
              (+
                (* 14641.0 10.0)
                (+
                  (* 161051.0 5.0)
                  (+
                    (* 1771561.0 6.0)
                    (+
                      (* 19487171.0 7.0)
                      (+ (* 214358881.0 8.0) (* 2357947691.0 9.0))))))))))]
    (if (= sum want)
      42
      (+ 100 (% (cast sum : i64) 100)))))

;; The same copy for a register group: on System V the pair does not fit the
;; one float argument register left after g, so both of its words arrive on
;; the stack.
(define (fin-pair
  [a : f64]
  [b : f64]
  [c : f64]
  [d : f64]
  [e : f64]
  [f : f64]
  [g : f64]
  [p : PairF64]) : f64
  (+
    a
    (+
      (* 11.0 b)
      (+
        (* 121.0 c)
        (+
          (* 1331.0 d)
          (+
            (* 14641.0 e)
            (+
              (* 161051.0 f)
              (+ (* 1771561.0 g) (+ (* 19487171.0 p.x) (* 214358881.0 p.y))))))))))

;; Win64 passes every parameter past the fourth on the stack. Twenty floats
;; leave more stack-passed values than free XMM registers, so some live in
;; frame slots on both ABIs. Weight 2^k keeps the sum exact.
(define (fin-wide
  [a0 : f64]
  [a1 : f64]
  [a2 : f64]
  [a3 : f64]
  [a4 : f64]
  [a5 : f64]
  [a6 : f64]
  [a7 : f64]
  [a8 : f64]
  [a9 : f64]
  [a10 : f64]
  [a11 : f64]
  [a12 : f64]
  [a13 : f64]
  [a14 : f64]
  [a15 : f64]
  [a16 : f64]
  [a17 : f64]
  [a18 : f64]
  [a19 : f64]) : f64
  (+
    a0
    (+
      (* 2.0 a1)
      (+
        (* 4.0 a2)
        (+
          (* 8.0 a3)
          (+
            (* 16.0 a4)
            (+
              (* 32.0 a5)
              (+
                (* 64.0 a6)
                (+
                  (* 128.0 a7)
                  (+
                    (* 256.0 a8)
                    (+
                      (* 512.0 a9)
                      (+
                        (* 1024.0 a10)
                        (+
                          (* 2048.0 a11)
                          (+
                            (* 4096.0 a12)
                            (+
                              (* 8192.0 a13)
                              (+
                                (* 16384.0 a14)
                                (+
                                  (* 32768.0 a15)
                                  (+
                                    (* 65536.0 a16)
                                    (+
                                      (* 131072.0 a17)
                                      (+ (* 262144.0 a18) (* 524288.0 a19)))))))))))))))))))))

;; f32 parameters take the same copy with single-precision moves.
(define (fin-f32
  [a : f32]
  [b : f32]
  [c : f32]
  [d : f32]
  [e : f32]
  [f : f32]
  [g : f32]
  [h : f32]
  [i : f32]
  [j : f32]) : f32
  (+
    a
    (+
      (* (cast 2.0 : f32) b)
      (+
        (* (cast 4.0 : f32) c)
        (+
          (* (cast 8.0 : f32) d)
          (+
            (* (cast 16.0 : f32) e)
            (+
              (* (cast 32.0 : f32) f)
              (+
                (* (cast 64.0 : f32) g)
                (+
                  (* (cast 128.0 : f32) h)
                  (+ (* (cast 256.0 : f32) i) (* (cast 512.0 : f32) j)))))))))))

(define (fin-case) : i64
  (fin 2.0 1.0 4.0 3.0 10.0 5.0 6.0 7.0 8.0 9.0))

(define (pair-ok?) : bool
  (=
    (fin-pair 2.0 1.0 4.0 3.0 10.0 5.0 6.0 (PairF64 7.0 8.0))
    (+
      2.0
      (+
        (* 11.0 1.0)
        (+
          (* 121.0 4.0)
          (+
            (* 1331.0 3.0)
            (+
              (* 14641.0 10.0)
              (+
                (* 161051.0 5.0)
                (+ (* 1771561.0 6.0) (+ (* 19487171.0 7.0) (* 214358881.0 8.0)))))))))))

(define (wide-ok?) : bool
  ;; Sum over k of (k + 1) * 2^k for k = 0..19 is 19 * 2^20 + 1.
  (=
    (fin-wide
      1.0
      2.0
      3.0
      4.0
      5.0
      6.0
      7.0
      8.0
      9.0
      10.0
      11.0
      12.0
      13.0
      14.0
      15.0
      16.0
      17.0
      18.0
      19.0
      20.0)
    19922945.0))

(define (f32-ok?) : bool
  ;; Sum over k of (k + 1) * 2^k for k = 0..9 is 9 * 2^10 + 1.
  (=
    (fin-f32
      (cast 1.0 : f32)
      (cast 2.0 : f32)
      (cast 3.0 : f32)
      (cast 4.0 : f32)
      (cast 5.0 : f32)
      (cast 6.0 : f32)
      (cast 7.0 : f32)
      (cast 8.0 : f32)
      (cast 9.0 : f32)
      (cast 10.0 : f32))
    (cast 9217.0 : f32)))

(define (main) : i64
  (unless (= (fin-case) 42) (return 1))
  (unless (pair-ok?) (return 2))
  (unless (wide-ok?) (return 3))
  (unless (f32-ok?) (return 4))
  42)