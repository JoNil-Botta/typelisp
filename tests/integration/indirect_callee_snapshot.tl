(extern (first) : (CFunc non-null (-> String i64)) (:symbol "tl_callee_first"))
(extern (second) : (CFunc non-null (-> String i64)) (:symbol "tl_callee_second"))
(extern (calls) : i64 (:symbol "tl_callee_calls"))
(extern (gets) : i64 (:symbol "tl_callee_gets"))

(define (inc [x : i64]) : i64
  (+ x 1))

(define (dec [x : i64]) : i64
  (- x 1))

(define selected : (-> i64 i64)
  inc)
(define language-gets : i64
  0)

(define (factory) : (-> i64 i64)
  (set! language-gets (+ language-gets 1))
  inc)

(define (change-global!) : i64
  (set! selected dec)
  41)

(define c-selected : (CFunc non-null (-> String i64))
  (first))

(define (change-c-global!) : String
  (set! c-selected (second))
  "answer")

(defstruct Language
  (callback (-> i64 i64)))

(defstruct Foreign
  (callback (CFunc non-null (-> String i64))))

(define (parameter [callback : (-> i64 i64)]) : i64
  (callback
    (begin
      (set! callback dec)
      41)))

(define (c-parameter [callback : (CFunc non-null (-> String i64))]) : i64
  (callback
    (begin
      (set! callback (second))
      "answer")))

(define (main) : i64
  (let
    [local : i64
      (let
        [f inc]
        (f
          (begin
            (set! f dec)
            41)))]
    [raw : i64
      (let
        [f inc]
        (f
          (begin
            (unsafe
              (ptr-write! (ptr-addr-of f) dec))
            41)))]
    [param : i64 (parameter inc)]
    [global : i64 (selected (change-global!))]
    [closure : i64
      (let
        [k : i64 40]
        [f
          (lambda ([x : i64]) : i64
            (+ x k))]
        (f
          (begin
            (set!
              f
              (lambda ([x : i64]) : i64
                (- x k)))
            (set! k 0)
            2)))]
    [conditional : i64
      (let
        [f inc]
        ((if true
            f
            dec)
          (begin
            (set! f dec)
            41)))]
    [wrapped : i64
      (let
        [f inc]
        ((begin
            unit
            f)
          (begin
            (set! f dec)
            41)))]
    [made : i64 ((factory) 41)]
    [field : i64
      (let
        [holder (Language inc)]
        (holder.callback
          (begin
            (set! holder.callback dec)
            41)))]
    [stable : i64
      (let
        [f inc]
        (f 41))]
    [c-local : i64
      (let
        [f (first)]
        (f
          (begin
            (set! f (second))
            "answer")))]
    [c-raw : i64
      (let
        [f (first)]
        (f
          (begin
            (unsafe
              (ptr-write! (ptr-addr-of f) (second)))
            "answer")))]
    [c-param : i64 (c-parameter (first))]
    [c-global : i64 (c-selected (change-c-global!))]
    [c-field : i64
      (let
        [holder (Foreign (first))]
        (holder.callback
          (begin
            (set! holder.callback (second))
            "answer")))]
    [c-made : i64 ((first) "answer")]
    [c-stable : i64
      (let
        [f (first)]
        (f "answer"))]
    (if (and
      (= local 42)
      (= raw 42)
      (= param 42)
      (= global 42)
      (= closure 42)
      (= conditional 42)
      (= wrapped 42)
      (= made 42)
      (= field 42)
      (= stable 42)
      (= c-local 42)
      (= c-raw 42)
      (= c-param 42)
      (= c-global 42)
      (= c-field 42)
      (= c-made 42)
      (= c-stable 42)
      (= language-gets 1)
      (= (calls) 7)
      (= (gets) 12))
      42
      1)))