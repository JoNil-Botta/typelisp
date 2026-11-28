;; Snapshot a computed gang binding, mutate its source in the scalar body,
;; and read the saved lane after the write. Check the saved value,
;; visitation order, and tail count against a scalar loop.
(defmacro (check-lanes [T : type] [name : Expr]) : Decls
  `(define (,name [n : i64]) : bool
    (let
      [xs : (__tl_dyn-array ,T) (__tl_make-array ,T n)]
      [zero : ,T (cast 0 : ,T)]
      [i : i64 0]
      [seen : i64 0]
      [ok : bool true]
      [sparse : i64 0]
      [constants : i64 0]
      (while (< i n)
        (set! (array-ref xs i) (cast (- i 35) : ,T))
        (set! i (+ i 1)))
      (foreach
        ([j : i64 0 n])
        (let
          [v : ,T (array-ref xs j)]
          (foreach-active
            [lane : i64]
            (set!
              (array-ref xs (lane-value j))
              (cast (% (lane-value j) 7) : ,T))
            (set!
              ok
              (and
                ok
                (= seen (lane-value j))
                (= (lane-value v) (cast (- seen 35) : ,T))
                (= lane (lane-value (program-index)))
                (= lane (% seen (program-count)))))
            (set! seen (+ seen 1)))))
      (foreach
        ([k : i64 0 n])
        (let
          [v : ,T (array-ref xs k)]
          (if (= v zero)
            (foreach-active
              [lane : i64]
              (set! ok (and ok (= (lane-value k) (* sparse 7))))
              (set! sparse (+ sparse 1)))
            unit)))
      ;; A constant gang binding still has a concrete element type and a
      ;; vector representation, even when there are no array operands.
      (foreach
        ([k : i64 0 n])
        (let
          [v : ,T (cast 7 : ,T)]
          (foreach-active
            [lane : i64]
            (set! ok (and ok (= (lane-value v) (cast 7 : ,T))))
            (set! constants (+ constants 1)))))
      (and ok (= seen n) (= constants n) (= sparse (/ (+ n 6) 7))))))

(check-lanes i8 signed-byte)

(check-lanes u8 unsigned-byte)

(check-lanes i16 signed-word)

(check-lanes u16 unsigned-word)

(check-lanes i32 signed-dword)

(check-lanes u32 unsigned-dword)

(check-lanes i64 signed-qword)

(check-lanes u64 unsigned-qword)

(check-lanes f32 single)

(check-lanes f64 double)

(define (annotated-let) : bool
  (let
    [total : i64 0]
    (foreach
      ([i : i64 0 67])
      (let
        [v : i16 -9]
        (foreach-active
          [lane : i64]
          (set! total (+ total (cast (lane-value v) : i64))))))
    (= total -603)))

(define (main) : i64
  (if (and
    (annotated-let)
    (signed-byte 67)
    (unsigned-byte 67)
    (signed-word 67)
    (unsigned-word 67)
    (signed-dword 67)
    (unsigned-dword 67)
    (signed-qword 67)
    (unsigned-qword 67)
    (single 67)
    (double 67))
    42
    1))