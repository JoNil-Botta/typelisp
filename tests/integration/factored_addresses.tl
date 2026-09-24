;; Multi-field array reads cover each factored byte stride. The arithmetic
;; oracle is independent of the array address calculation.
(import stdlib.io)

(defstruct Slot3x2
  (f0 u16)
  (f1 u16)
  (f2 u16))

(define (read-Slot3x2
  [values : (& values (__tl_dyn-array Slot3x2))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+ (+ 0 (* (cast item.f0 : i64) 1)) (* (cast item.f1 : i64) 2))
      (* (cast item.f2 : i64) 3))))

(define (check-Slot3x2 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot3x2) (__tl_make-array Slot3x2 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot3x2
              (cast (+ (* i 101) 7) : u16)
              (cast (+ (* i 101) 14) : u16)
              (cast (+ (* i 101) 21) : u16)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot3x2 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 6) 98)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 6))))))
          (set! j (+ j 1))))
      total)))

(defstruct Slot5x2
  (f0 u16)
  (f1 u16)
  (f2 u16)
  (f3 u16)
  (f4 u16))

(define (read-Slot5x2
  [values : (& values (__tl_dyn-array Slot5x2))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+
        (+
          (+ (+ 0 (* (cast item.f0 : i64) 1)) (* (cast item.f1 : i64) 2))
          (* (cast item.f2 : i64) 3))
        (* (cast item.f3 : i64) 4))
      (* (cast item.f4 : i64) 5))))

(define (check-Slot5x2 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot5x2) (__tl_make-array Slot5x2 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot5x2
              (cast (+ (* i 101) 7) : u16)
              (cast (+ (* i 101) 14) : u16)
              (cast (+ (* i 101) 21) : u16)
              (cast (+ (* i 101) 28) : u16)
              (cast (+ (* i 101) 35) : u16)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot5x2 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 15) 385)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 10))))))
          (set! j (+ j 1))))
      total)))

(defstruct Slot9x2
  (f0 u16)
  (f1 u16)
  (f2 u16)
  (f3 u16)
  (f4 u16)
  (f5 u16)
  (f6 u16)
  (f7 u16)
  (f8 u16))

(define (read-Slot9x2
  [values : (& values (__tl_dyn-array Slot9x2))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+
        (+
          (+
            (+
              (+
                (+
                  (+
                    (+ 0 (* (cast item.f0 : i64) 1))
                    (* (cast item.f1 : i64) 2))
                  (* (cast item.f2 : i64) 3))
                (* (cast item.f3 : i64) 4))
              (* (cast item.f4 : i64) 5))
            (* (cast item.f5 : i64) 6))
          (* (cast item.f6 : i64) 7))
        (* (cast item.f7 : i64) 8))
      (* (cast item.f8 : i64) 9))))

(define (check-Slot9x2 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot9x2) (__tl_make-array Slot9x2 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot9x2
              (cast (+ (* i 101) 7) : u16)
              (cast (+ (* i 101) 14) : u16)
              (cast (+ (* i 101) 21) : u16)
              (cast (+ (* i 101) 28) : u16)
              (cast (+ (* i 101) 35) : u16)
              (cast (+ (* i 101) 42) : u16)
              (cast (+ (* i 101) 49) : u16)
              (cast (+ (* i 101) 56) : u16)
              (cast (+ (* i 101) 63) : u16)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot9x2 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 45) 1995)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 18))))))
          (set! j (+ j 1))))
      total)))

(defstruct Slot3x4
  (f0 i32)
  (f1 i32)
  (f2 i32))

(define (read-Slot3x4
  [values : (& values (__tl_dyn-array Slot3x4))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+ (+ 0 (* (cast item.f0 : i64) 1)) (* (cast item.f1 : i64) 2))
      (* (cast item.f2 : i64) 3))))

(define (check-Slot3x4 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot3x4) (__tl_make-array Slot3x4 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot3x4
              (cast (+ (* i 101) 7) : i32)
              (cast (+ (* i 101) 14) : i32)
              (cast (+ (* i 101) 21) : i32)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot3x4 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 6) 98)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 12))))))
          (set! j (+ j 1))))
      total)))

(defstruct Slot5x4
  (f0 i32)
  (f1 i32)
  (f2 i32)
  (f3 i32)
  (f4 i32))

(define (read-Slot5x4
  [values : (& values (__tl_dyn-array Slot5x4))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+
        (+
          (+ (+ 0 (* (cast item.f0 : i64) 1)) (* (cast item.f1 : i64) 2))
          (* (cast item.f2 : i64) 3))
        (* (cast item.f3 : i64) 4))
      (* (cast item.f4 : i64) 5))))

(define (check-Slot5x4 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot5x4) (__tl_make-array Slot5x4 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot5x4
              (cast (+ (* i 101) 7) : i32)
              (cast (+ (* i 101) 14) : i32)
              (cast (+ (* i 101) 21) : i32)
              (cast (+ (* i 101) 28) : i32)
              (cast (+ (* i 101) 35) : i32)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot5x4 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 15) 385)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 20))))))
          (set! j (+ j 1))))
      total)))

(defstruct Slot9x4
  (f0 i32)
  (f1 i32)
  (f2 i32)
  (f3 i32)
  (f4 i32)
  (f5 i32)
  (f6 i32)
  (f7 i32)
  (f8 i32))

(define (read-Slot9x4
  [values : (& values (__tl_dyn-array Slot9x4))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+
        (+
          (+
            (+
              (+
                (+
                  (+
                    (+ 0 (* (cast item.f0 : i64) 1))
                    (* (cast item.f1 : i64) 2))
                  (* (cast item.f2 : i64) 3))
                (* (cast item.f3 : i64) 4))
              (* (cast item.f4 : i64) 5))
            (* (cast item.f5 : i64) 6))
          (* (cast item.f6 : i64) 7))
        (* (cast item.f7 : i64) 8))
      (* (cast item.f8 : i64) 9))))

(define (check-Slot9x4 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot9x4) (__tl_make-array Slot9x4 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot9x4
              (cast (+ (* i 101) 7) : i32)
              (cast (+ (* i 101) 14) : i32)
              (cast (+ (* i 101) 21) : i32)
              (cast (+ (* i 101) 28) : i32)
              (cast (+ (* i 101) 35) : i32)
              (cast (+ (* i 101) 42) : i32)
              (cast (+ (* i 101) 49) : i32)
              (cast (+ (* i 101) 56) : i32)
              (cast (+ (* i 101) 63) : i32)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot9x4 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 45) 1995)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 36))))))
          (set! j (+ j 1))))
      total)))

(defstruct Slot3x8
  (f0 i64)
  (f1 i64)
  (f2 i64))

(define (read-Slot3x8
  [values : (& values (__tl_dyn-array Slot3x8))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+ (+ 0 (* (cast item.f0 : i64) 1)) (* (cast item.f1 : i64) 2))
      (* (cast item.f2 : i64) 3))))

(define (check-Slot3x8 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot3x8) (__tl_make-array Slot3x8 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot3x8
              (cast (+ (* i 101) 7) : i64)
              (cast (+ (* i 101) 14) : i64)
              (cast (+ (* i 101) 21) : i64)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot3x8 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 6) 98)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 24))))))
          (set! j (+ j 1))))
      total)))

(defstruct Slot5x8
  (f0 i64)
  (f1 i64)
  (f2 i64)
  (f3 i64)
  (f4 i64))

(define (read-Slot5x8
  [values : (& values (__tl_dyn-array Slot5x8))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+
        (+
          (+ (+ 0 (* (cast item.f0 : i64) 1)) (* (cast item.f1 : i64) 2))
          (* (cast item.f2 : i64) 3))
        (* (cast item.f3 : i64) 4))
      (* (cast item.f4 : i64) 5))))

(define (check-Slot5x8 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot5x8) (__tl_make-array Slot5x8 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot5x8
              (cast (+ (* i 101) 7) : i64)
              (cast (+ (* i 101) 14) : i64)
              (cast (+ (* i 101) 21) : i64)
              (cast (+ (* i 101) 28) : i64)
              (cast (+ (* i 101) 35) : i64)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot5x8 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 15) 385)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 40))))))
          (set! j (+ j 1))))
      total)))

(defstruct Slot9x8
  (f0 i64)
  (f1 i64)
  (f2 i64)
  (f3 i64)
  (f4 i64)
  (f5 i64)
  (f6 i64)
  (f7 i64)
  (f8 i64))

(define (read-Slot9x8
  [values : (& values (__tl_dyn-array Slot9x8))]
  [index : i64]) : i64
  (let
    [item (& (array-ref values index))]
    (+
      (+
        (+
          (+
            (+
              (+
                (+
                  (+
                    (+ 0 (* (cast item.f0 : i64) 1))
                    (* (cast item.f1 : i64) 2))
                  (* (cast item.f2 : i64) 3))
                (* (cast item.f3 : i64) 4))
              (* (cast item.f4 : i64) 5))
            (* (cast item.f5 : i64) 6))
          (* (cast item.f6 : i64) 7))
        (* (cast item.f7 : i64) 8))
      (* (cast item.f8 : i64) 9))))

(define (check-Slot9x8 [seed : i64]) : i64
  (let
    [values : (__tl_dyn-array Slot9x8) (__tl_make-array Slot9x8 97)]
    [i : i64 0]
    [j : i64 0]
    [total : i64 0]
    (begin
      (while (< i 97)
        (begin
          (set!
            (array-ref values i)
            (Slot9x8
              (cast (+ (* i 101) 7) : i64)
              (cast (+ (* i 101) 14) : i64)
              (cast (+ (* i 101) 21) : i64)
              (cast (+ (* i 101) 28) : i64)
              (cast (+ (* i 101) 35) : i64)
              (cast (+ (* i 101) 42) : i64)
              (cast (+ (* i 101) 49) : i64)
              (cast (+ (* i 101) 56) : i64)
              (cast (+ (* i 101) 63) : i64)))
          (set! i (+ i 1))))
      (while (< j 257)
        (begin
          (set! i (% (+ (* j 37) seed) 97))
          (let
            [actual : i64 (read-Slot9x8 (& values) i)]
            (begin
              (when (!= actual (+ (* (* i 101) 45) 1995)) (return -1))
              ;; Keep the complete byte offset observable as well as its address.
              (set! total (+ total (+ actual (* i 72))))))
          (set! j (+ j 1))))
      total)))

(define (main) : i64
  (let
    [seed : i64 (io.arg-count)]
    [total : i64 0]
    (begin
      (let
        [value : i64 (check-Slot3x2 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (let
        [value : i64 (check-Slot5x2 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (let
        [value : i64 (check-Slot9x2 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (let
        [value : i64 (check-Slot3x4 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (let
        [value : i64 (check-Slot5x4 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (let
        [value : i64 (check-Slot9x4 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (let
        [value : i64 (check-Slot3x8 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (let
        [value : i64 (check-Slot5x8 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (let
        [value : i64 (check-Slot9x8 seed)]
        (begin
          (when (< value 0) (return 1))
          (set! total (+ total value))))
      (io.println "{}" total)
      0)))