;; Exact runtime aliases must retain live values and use the ordinary allocator
;; for a growing segment or shared arena. Native and C declarations exercise
;; both call metadata paths on Linux and Windows.
(import stdlib.io)
(import stdlib.arena)

(extern (reserve-native [bytes : i64]) : (MutPtr i64) (:symbol "tl_alloc"))
(extern (reserve-c [bytes : i64]) : (MutPtr i64) (:abi c) (:symbol "tl_alloc"))
(extern (reserve-large [bytes : i64]) : (MutPtr u8) (:symbol "tl_alloc"))

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
    [cell : (MutPtr i64) (reserve-native 24)]
    [_write : unit
      (unsafe
        (ptr-write! cell (+ p0.x (+ p3.y p5.x))))]
    [second : (MutPtr i64) (reserve-c 63)]
    [_second : unit
      (unsafe
        (ptr-write! second 999))]
    [bonus : i64
      (unsafe
        (ptr-read (ptr-cast cell : (Ptr i64))))]
    (+
      (bit-xor
        (bit-xor
          (bit-xor
            (bit-xor
              (bit-xor
                (bit-xor
                  (bit-xor
                    (bit-xor
                      (bit-xor (bit-xor (bit-xor p0.x p0.y) p1.x) p1.y)
                      p2.x)
                    p2.y)
                  p3.x)
                p3.y)
              p4.x)
            p4.y)
          p5.x)
        p5.y)
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

(define (check) : bool
  (let
    [seed : i64 (+ (io.arg-count) 17)]
    [ra : i64 (run-alloc seed)]
    [rr : i64 (run-ref seed)]
    (= ra rr)))

(define (arena-word [owner : arena.Arena] [offset : i64]) : i64
  (unsafe
    (ptr-read (int->ptr (+ (arena.raw-handle owner) offset) : (Ptr i64)))))

(define (main) : i64
  (let
    [home : arena.Arena (arena.current)]
    [owner : arena.Arena (arena.make)]
    [shared : arena.Arena (arena.make-atomic)]
    [ok : bool (check)]
    (begin
      (unsafe
        (arena.set! owner))
      (set! ok (and (check) ok))
      ;; Leave sixteen bytes in this segment, forcing the next 24-byte alias
      ;; allocation through the slow path. The end field differs by platform.
      (let
        [end : i64 (arena-word owner (cfg windows 64 24))]
        [cursor : i64 (arena-word owner 16)]
        (reserve-large (- (- end cursor) 16)))
      (set! ok (and (= (arena-word owner 56) (arena.raw-handle owner)) ok))
      (set! ok (and (check) ok))
      (set! ok (and (!= (arena-word owner 56) (arena.raw-handle owner)) ok))
      (unsafe
        (arena.set! shared))
      (set! ok (and (check) ok))
      (unsafe
        (begin
          (arena.set! home)
          (arena.destroy owner)
          (arena.destroy shared)))
      (if ok
        42
        1))))