(import stdlib.io)

;; FORCING / CORRECTNESS test for inline fast allocation scratch preservation.
;;
;; `run-alloc` keeps several 16-byte register-group values live across a small
;; boxed allocation. The backend lowers that allocation through
;; compiler-backend-emit-inline-fast-alloc, whose fast path scavenges scratch
;; registers for the active arena and next bump pointer. After the allocation the
;; checksum reads every pair field, so a scratch pick that clobbers a live group
;; word makes this path diverge from the scalar reference path.
;;
;; Inputs come from io.arg-count so the optimizer cannot constant-fold the
;; checksum away. The test is also run by verify-integration.sh's opt2 backend
;; fixture lane, where register-group allocation is enabled.
(defstruct Pair
  (x i64)
  (y i64))

(define (mix [a : i64] [b : i64]) : i64
  (bit-and (+ (* a 5) b) 281474976710655))

(define (run-alloc [seed : i64]) : i64
  (let
    [p0 : Pair
      (Pair (mix (+ seed 10) (+ seed 11)) (mix (+ seed 12) (+ seed 13)))]
    [p1 : Pair
      (Pair (mix (+ seed 20) (+ seed 21)) (mix (+ seed 22) (+ seed 23)))]
    [p2 : Pair
      (Pair (mix (+ seed 30) (+ seed 31)) (mix (+ seed 32) (+ seed 33)))]
    [p3 : Pair
      (Pair (mix (+ seed 40) (+ seed 41)) (mix (+ seed 42) (+ seed 43)))]
    [p4 : Pair
      (Pair (mix (+ seed 50) (+ seed 51)) (mix (+ seed 52) (+ seed 53)))]
    [p5 : Pair
      (Pair (mix (+ seed 60) (+ seed 61)) (mix (+ seed 62) (+ seed 63)))]
    [cell : (Box i64)
      (box (+ (struct-get p0 x) (+ (struct-get p3 y) (struct-get p5 x))))]
    [bonus : i64 (box-get cell)]
    (+
      (bit-xor
        (bit-xor
          (bit-xor
            (bit-xor
              (bit-xor
                (bit-xor
                  (bit-xor
                    (bit-xor
                      (bit-xor
                        (bit-xor
                          (bit-xor (struct-get p0 x) (struct-get p0 y))
                          (struct-get p1 x))
                        (struct-get p1 y))
                      (struct-get p2 x))
                    (struct-get p2 y))
                  (struct-get p3 x))
                (struct-get p3 y))
              (struct-get p4 x))
            (struct-get p4 y))
          (struct-get p5 x))
        (struct-get p5 y))
      bonus)))

(define (run-ref [seed : i64]) : i64
  (let
    [p0x : i64 (mix (+ seed 10) (+ seed 11))]
    [p0y : i64 (mix (+ seed 12) (+ seed 13))]
    [p1x : i64 (mix (+ seed 20) (+ seed 21))]
    [p1y : i64 (mix (+ seed 22) (+ seed 23))]
    [p2x : i64 (mix (+ seed 30) (+ seed 31))]
    [p2y : i64 (mix (+ seed 32) (+ seed 33))]
    [p3x : i64 (mix (+ seed 40) (+ seed 41))]
    [p3y : i64 (mix (+ seed 42) (+ seed 43))]
    [p4x : i64 (mix (+ seed 50) (+ seed 51))]
    [p4y : i64 (mix (+ seed 52) (+ seed 53))]
    [p5x : i64 (mix (+ seed 60) (+ seed 61))]
    [p5y : i64 (mix (+ seed 62) (+ seed 63))]
    [bonus : i64 (+ p0x (+ p3y p5x))]
    (+
      (bit-xor
        (bit-xor
          (bit-xor
            (bit-xor
              (bit-xor
                (bit-xor
                  (bit-xor
                    (bit-xor (bit-xor (bit-xor (bit-xor p0x p0y) p1x) p1y) p2x)
                    p2y)
                  p3x)
                p3y)
              p4x)
            p4y)
          p5x)
        p5y)
      bonus)))

(define (main) : i64
  (let
    [seed : i64 (+ (io.arg-count) 17)]
    [ra : i64 (run-alloc seed)]
    [rr : i64 (run-ref seed)]
    (if (= ra rr)
      42
      1)))