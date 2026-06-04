(import "stdlib/io.tl")

(define (path-separator? [c : char]) : bool
  (= c #/'))

(define (path-starts-separator? [path : String]) : bool
  (and (> (string-length path) 0) (path-separator? (string-ref path 0))))

(define (path-ends-separator? [path : String]) : bool
  (let
    [n : i64 (string-length path)]
    (and (> n 0) (path-separator? (string-ref path (- n 1))))))

(define (path-join [left : String] [right : String]) : String
  (cond
    [(= (string-length left) 0) right]
    [(= (string-length right) 0) left]
    [(path-ends-separator? left)
      (if (path-starts-separator? right)
        (string-append left (substring right 1 (- (string-length right) 1)))
        (string-append left right))]
    [(path-starts-separator? right) (string-append left right)]
    [else (string-append (string-append left "/") right)]))

(define (last-separator-index [path : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (string-length path)]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (path-separator? (string-ref path i))
            (set! last i)
            (set! last last))
          (set! i (+ i 1))))
      last)))

(define (dirname [path : String]) : String
  (let
    [last : i64 (last-separator-index path)]
    (if (< last 0)
      "."
      (if (= last 0)
        "/"
        (substring path 0 last)))))

(define (basename [path : String]) : String
  (let
    [n : i64 (string-length path)]
    [last : i64 (last-separator-index path)]
    (if (< last 0)
      path
      (substring path (+ last 1) (- n (+ last 1))))))

(define (extension [path : String]) : String
  (let
    [base : String (basename path)]
    [i : i64 0]
    [dot : i64 -1]
    [n : i64 (string-length base)]
    (begin
      (while (< i n)
        (begin
          (if (= (string-ref base i) #.')
            (set! dot i)
            (set! dot dot))
          (set! i (+ i 1))))
      (if (<= dot 0)
        ""
        (substring base (+ dot 1) (- n (+ dot 1)))))))

(define (path-helper-round [root : String] [leaf : String]) : i64
  (let
    [joined : String (path-join root leaf)]
    [dir : String (dirname joined)]
    [base : String (basename joined)]
    [ext : String (extension joined)]
    [copy-name : String (string-append "copy-" base)]
    [copy-path : String (path-join dir copy-name)]
    (+
      (string-length joined)
      (+
        (string-length dir)
        (+
          (string-length base)
          (+ (string-length ext) (string-length copy-path)))))))

(define (path-helper-repeat [root : String] [leaf : String] [rounds : i64]) : i64
  (let
    [i : i64 0]
    [acc : i64 0]
    (begin
      (while (< i rounds)
        (begin
          (set! acc (+ acc (path-helper-round root leaf)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [root : String (arg 1)]
    [leaf : String (arg 2)]
    [rounds : i64 (string->int (arg 3))]
    (begin
      (print (path-helper-repeat root leaf rounds))
      0)))