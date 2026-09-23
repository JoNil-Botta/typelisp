;; Refs #7988: a by-value memory-class aggregate parameter is passed on the
;; stack on SysV, so the scalars after it arrive one register earlier. The opt 2
;; shrinkwrapped entry guard must test the scalar the source names, not the
;; register a register-only mapping would have given it.
(define (score [text : (Array u16 64)] [length : i64] [salt : i64]) : i64
  (if (<= length 0)
    1
    (let
      [total : i64 0]
      [index : i64 0]
      (begin
        (while (< index length)
          (begin
            (set! total (+ (* total 31) (cast (array-ref text index) : i64)))
            (set! total (+ total salt))
            (set! index (+ index 1))))
        (+ 2 (% total 5))))))

;; Two memory-class parameters with the guard on each length, as in the
;; Winsock module-identity check.
(define (identity
  [left : (Array u16 64)]
  [left-length : i64]
  [right : (Array u16 64)]
  [right-length : i64]) : i64
  (when
    (or
      (<= left-length 0)
      (>= left-length 64)
      (<= right-length 0)
      (>= right-length 64))
    (return 1))
  (let
    [index : i64 0]
    [same : bool true]
    (begin
      (while (and same (< index left-length))
        (begin
          (when
            (!= (array-ref left index) (array-ref right index))
            (set! same false))
          (set! index (+ index 1))))
      (if (and same (= left-length right-length))
        2
        3))))

(define (main) : i64
  (let
    [text : (Array u16 64) (init : (Array u16 64))]
    [other : (Array u16 64) (init : (Array u16 64))]
    (begin
      (set! (array-ref text 0) (cast 65 : u16))
      (set! (array-ref other 0) (cast 65 : u16))
      (cond
        [(not (= (score text -1 7) 1)) 10]
        [(not (= (score text 0 -5) 1)) 11]
        [(not (= (identity text -1 other 1) 1)) 12]
        [(not (= (identity text 1 other -1) 1)) 13]
        [(not (= (identity text 1 other 64) 1)) 14]
        [(not (= (identity text 1 other 1) 2)) 15]
        [else 42]))))