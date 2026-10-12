;; Copy payloads are snapshots even when their source is overwritten in the arm.
(defenum Token
  (Num i64)
  (Other i64)
  (Nil))

(defstruct Holder
  (token Token))

(defstruct Label
  (text String)
  (code i64))

(define (enum-copy [choice : bool]) : i64
  (let
    [tok : Token
      (if choice
        (Token.Num 3)
        (Token.Other 3))]
    (match (& tok)
      [(or (Token.Num value) (Token.Other value))
        (if choice
          (begin
            (set! tok (Token.Nil))
            value)
          (begin
            (set! tok (Token.Num 100))
            value))]
      [_ 0])))

(define (tuple-copy) : i64
  (let
    [pair : (Tuple i64 i64) (tuple 2 5)]
    (match (& pair)
      [(tuple left right)
        (begin
          (set! pair (tuple 100 200))
          (+ left right))])))

(define (array-copy) : i64
  (let
    [items : (Array i64 2) (array 4 5)]
    (match (& items)
      [(array first second)
        (begin
          (set! (array-ref items 0) 100)
          (+ first second))])))

(define (projected-copy) : i64
  (let
    [holder : Holder (Holder (Token.Num 11))]
    (match (& holder.token)
      [(Token.Num value)
        (begin
          (set! holder.token (Token.Nil))
          value)]
      [_ 0])))

(define (dynamic-copy [index : i64]) : i64
  (let
    [items : (Array Token 2) (array (Token.Num 23) (Token.Num 29))]
    (match (& (array-ref items index))
      [(Token.Num value)
        (begin
          (set! (array-ref items index) (Token.Nil))
          value)]
      [_ 0])))

(define (unused-reference) : i64
  (let
    [label : Label (Label "before" 13)]
    (match (& label)
      [(Label _text code)
        (begin
          (set! label (Label "after" 100))
          code)])))

(define (reference-last-use) : i64
  (let
    [label : Label (Label "before" 13)]
    [length : i64 0]
    (match (& label)
      [(Label text code)
        (begin
          (set! length (__tl_string_length text))
          (set! label (Label "after" 100))
          (+ length code))])))

(define (loop-copy) : i64
  (let
    [tok : Token (Token.Num 1)]
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index 2)
        (begin
          (match (& tok)
            [(Token.Num value)
              (begin
                (set! tok (Token.Num 100))
                (set! total (+ total value)))]
            [_ unit])
          (set! index (+ index 1))))
      total)))

(define (nested-copy) : i64
  (let
    [left : Token (Token.Num 17)]
    [right : Token (Token.Num 19)]
    (match (& left)
      [(Token.Num value)
        (+
          value
          (match (& right)
            [(Token.Num value)
              (begin
                (set! left (Token.Nil))
                (set! right (Token.Nil))
                value)]
            [_ 0]))]
      [_ 0])))

(define (main) : i64
  (if (and
    (= (enum-copy true) 3)
    (= (enum-copy false) 3)
    (= (tuple-copy) 7)
    (= (array-copy) 9)
    (= (projected-copy) 11)
    (= (dynamic-copy 0) 23)
    (= (dynamic-copy 1) 29)
    (= (unused-reference) 13)
    (= (reference-last-use) 19)
    (= (loop-copy) 101)
    (= (nested-copy) 36))
    42
    1))