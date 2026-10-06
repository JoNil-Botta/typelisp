;: Borrowed-pattern binding rule (SPEC section 5.13): through a shared
;: reference a Copy part binds by value, a `(Box T)` part binds `(& T)`, and
;: any other part binds a shared reference.
(import stdlib.string)

(defstruct Small
  (a i32)
  (b i32))

(defstruct Name
  (id i64)
  (text String))

(defenum Tok
  (Ident Name i64)
  (Pair Small Name)
  (Num i64)
  (Nil))

(defenum Tree
  (Leaf i64)
  (Node (Box Tree) (Box Tree)))

(defenum Text
  (Words (Box String))
  (Blank))

(defstruct Big
  (a i64)
  (b i64)
  (c i64))

(defenum Holder
  (Hold Big i64))

(define (score [t : (& Tok)]) : i64
  (match t
    [(Tok.Ident name k) (+ name.id k (string.string-length name.text))]
    [(Tok.Pair small name)
      (+ (cast small.a : i64) (cast small.b : i64) name.id)]
    [(Tok.Num k) (* k 2)]
    [(Tok.Nil) 0]))

(define (sum [tree : (& Tree)]) : i64
  (match tree
    [(Tree.Leaf value) value]
    [(Tree.Node left right) (+ (sum left) (sum right))]))

(define (text-len [text : (& Text)]) : i64
  (match text
    [(Text.Words words) (string.string-length words)]
    [(Text.Blank) 0]))

(define (tuple-sum [t : (& (Tuple i64 Small))]) : i64
  (match t
    [(tuple n (Small a b)) (+ n (cast a : i64) (cast b : i64))]))

(define (array-sum [xs : (& (Array i64 3))]) : i64
  (match xs
    [(array a b c) (+ a b c)]))

;; A by-value binding holds no borrow, so the scrutinee may change afterwards.
(define (copied-out) : i64
  (let
    [tok : Tok (Tok.Num 5)]
    [k : i64
      (match (& tok)
        [(Tok.Num k) k]
        [_ 0])]
    (begin
      (set! tok (Tok.Num 9))
      (+ k (score (& tok))))))

;; A Copy aggregate binds a copy, not a view of the scrutinee's storage.
(define (snapshot) : i64
  (let
    [holder : Holder (Holder.Hold (Big 1 2 3) 4)]
    [big : Big
      (match (& holder)
        [(Holder.Hold big _) big])]
    (begin
      (set! holder (Holder.Hold (Big 100 200 300) 5))
      (+ big.a big.b big.c))))

(define (main) : i64
  (let
    [ident : Tok (Tok.Ident (Name 3 "abcd") 7)]
    [pair : Tok (Tok.Pair (Small 1 2) (Name 10 "z"))]
    [num : Tok (Tok.Num 11)]
    [tree : Tree (Tree.Node (box (Tree.Leaf 3)) (box (Tree.Leaf 7)))]
    [text : Text (Text.Words (box "hello"))]
    [t : (Tuple i64 Small) (tuple 1 (Small 2 3))]
    [xs : (Array i64 3) (array 1 2 3)]
    (if (and
      (= (score (& ident)) 14)
      (= (score (& pair)) 13)
      (= (score (& num)) 22)
      (= (sum (& tree)) 10)
      (= (text-len (& text)) 5)
      (= (tuple-sum (& t)) 6)
      (= (array-sum (& xs)) 6)
      (= (copied-out) 23)
      (= (snapshot) 6))
      42
      1)))