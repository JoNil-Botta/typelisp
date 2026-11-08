;; Generated: see direct-object-region-compare in tests/codegen/native-link.cases.
(define (rd [p : (& p i32)]) : (in p i32)
  (deref p))

(define hi : i32
  1)
(define lo : i32
  -1)

(define (op0 [a : (& a i32)] [b : (& b i32)]) : bool
  (< (rd a) (rd b)))

(define flag0 : bool
  false)

(define (op1 [a : (& a i32)] [b : (& b i32)]) : bool
  (<= (rd a) (rd b)))

(define flag1 : bool
  false)

(define (op2 [a : (& a i32)] [b : (& b i32)]) : bool
  (> (rd a) (rd b)))

(define flag2 : bool
  false)

(define (op3 [a : (& a i32)] [b : (& b i32)]) : bool
  (>= (rd a) (rd b)))

(define flag3 : bool
  false)

(define (op4 [a : (& a i32)] [b : (& b i32)]) : bool
  (= (rd a) (rd b)))

(define flag4 : bool
  false)

(define (op5 [a : (& a i32)] [b : (& b i32)]) : bool
  (not (= (rd a) (rd b))))

(define flag5 : bool
  false)

(define (main) : i64
  (set! hi hi)
  (set! lo lo)
  (set! flag0 (op0 (& lo) (& hi)))
  (set! flag1 (op1 (& lo) (& hi)))
  (set! flag2 (op2 (& lo) (& hi)))
  (set! flag3 (op3 (& lo) (& hi)))
  (set! flag4 (op4 (& lo) (& hi)))
  (set! flag5 (op5 (& lo) (& hi)))
  (+
    (bit-and
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of flag0) : (Ptr i64))))
      1)
    (*
      2
      (+
        (bit-and
          (unsafe
            (ptr-read (ptr-cast (ptr-addr-of flag1) : (Ptr i64))))
          1)
        (*
          2
          (+
            (bit-and
              (unsafe
                (ptr-read (ptr-cast (ptr-addr-of flag2) : (Ptr i64))))
              1)
            (*
              2
              (+
                (bit-and
                  (unsafe
                    (ptr-read (ptr-cast (ptr-addr-of flag3) : (Ptr i64))))
                  1)
                (*
                  2
                  (+
                    (bit-and
                      (unsafe
                        (ptr-read (ptr-cast (ptr-addr-of flag4) : (Ptr i64))))
                      1)
                    (*
                      2
                      (+
                        (bit-and
                          (unsafe
                            (ptr-read
                              (ptr-cast (ptr-addr-of flag5) : (Ptr i64))))
                          1)
                        (* 2 0)))))))))))))