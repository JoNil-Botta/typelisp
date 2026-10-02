(import stdlib.comptime)
(import stdlib.string)

(defstruct SelectPayload
  (mask i64)
  (dst i64)
  (name String))

(defstruct Span
  (start i64)
  (end i64))

(defenum Kind
  (Small)
  (Large))

(defenum Instr
  (Load i64 i64 i64)
  (EntryArgc i64)
  (Select (Box SelectPayload))
  (Move i64 Kind)
  (Label String)
  (Nop)
  (Halt))

;; Every alternative jumps to one shared body; each binds `dst`, from a
;; positional payload or by name through a boxed payload struct.
(define (instr-dst [instr : Instr]) : i64
  (match instr
    [(or (Load dst _ _) (EntryArgc dst) (Select (box (fields dst)))) dst]
    [(Move dst (or (Small) (Large))) (+ dst 100)]
    [(or (Nop) (Halt)) -1]
    [_ -2]))

;; Nullary variants and a final or arm whose last alternative is not tested.
(define (instr-class [instr : Instr]) : i64
  (match instr
    [(or Nop Halt) 1]
    [(Move _ (Small)) 2]
    [(or (Load _ _ _) (EntryArgc _)) 3]
    [(or (Select _) (Move _ _) (Label _)) 4]))

;; A binding of an owned String payload moves out of either alternative.
(define (instr-text [instr : Instr]) : String
  (match instr
    [(or (Label text) (Select (box (fields [text name])))) text]
    [_ "none"]))

;; A borrowed scrutinee binds references from whichever alternative matched.
(define (borrowed-dst [instr : (& i Instr)]) : i64
  (match instr
    [(or (Load dst _ _) (EntryArgc dst)) (deref dst)]
    [_ 0]))

;; Scalar or-patterns compare each literal in turn.
(define (digit-class [n : i64]) : i64
  (match n
    [(or 0 2 4 6 8) 0]
    [(or 1 3 5 7 9) 1]
    [_ 2]))

(define (flag-score [flag : bool]) : i64
  (match flag
    [(or true false) 7]))

(define (word-score [word : String]) : i64
  (match word
    [(or "alpha" "beta") 1]
    [_ 0]))

;; By-name fields on a struct scrutinee and in a payload; unnamed fields are
;; ignored and a `[pattern field]` entry can nest a pattern.
(defenum Located
  (At Span i64))

(define (span-width [span : Span]) : i64
  (match span
    [(fields end start) (- end start)]))

(define (located-score [value : Located]) : i64
  (match value
    [(At (fields [last end]) weight) (+ last weight)]))

;; A borrowed match binds field references through `(fields ...)`.
(define (located-borrowed [value : Located]) : i64
  (match (& value)
    [(At (fields start) weight) (+ (deref start) (deref weight))]))

(defstruct Outer
  (inner Span)
  (tag i64))

(define (outer-score [outer : Outer]) : i64
  (match outer
    [(fields [(fields start) inner]) start]))

;; Tail position: each arm returns.
(define (tail-dst [instr : Instr]) : i64
  (match instr
    [(or (Load dst _ _) (EntryArgc dst)) (+ dst 1)]
    [_ 0]))

(defenum Inner
  (Num i64)
  (Flag bool)
  (Blank))

(defenum Pair
  (Left Inner)
  (Right Inner)
  (Empty))

(define (inner-value [inner : Inner]) : i64
  (match inner
    [(Num n) n]
    [(Flag set)
      (if set
        1
        0)]
    [Blank 0]))

;; Each alternative binds a two-word enum payload.
(define (pair-value [pair : Pair]) : i64
  (match pair
    [(or (Left inner) (Right inner)) (inner-value inner)]
    [Empty 0]))

;; A value-position match; a refutable nested payload in one alternative
;; falls through to the next one, and a nested or-pattern binds through both
;; of its alternatives.
(define (pair-sum [pair : Pair]) : i64
  (+
    1
    (match pair
      [(or (Left (Num n)) (Right (Num n))) n]
      [(Left (or (Flag _) (Blank))) 100]
      [_ 0])))

(define (pair-nested [pair : Pair]) : i64
  (match pair
    [(Right (or (Num n) (Num n))) n]
    [_ -1]))

;; Borrowed string payloads bind `(& str)` references.
(defenum Named
  (First String)
  (Second String)
  (Other))

(define (name-length [named : Named]) : i64
  (match (& named)
    [(or (First text) (Second text)) (string.string-length text)]
    [Other 0]))

;; A binding in each alternative shadows the comptime parameter of the same
;; name in the shared body.
(define (shadowed [comptime dst : i64] [instr : Instr]) : i64
  (match instr
    [(or (Load dst _ _) (EntryArgc dst)) dst]
    [_ dst]))

;; A two-word enum lives in registers; owned and borrowed alternatives read
;; their payloads from the register group or through the borrow.
(defenum Small
  (Low i64)
  (High i64)
  (Neither))

(define (small-value [small : Small]) : i64
  (match small
    [(or (Low n) (High n)) n]
    [Neither 0]))

(define (small-borrowed [small : Small]) : i64
  (match (& small)
    [(or (Low n) (High n)) (deref n)]
    [Neither 0]))

;; Literal alternatives in a payload expand into whole-arm alternatives.
(define (small-literal [small : Small]) : i64
  (match small
    [(Low (or 1 2)) 10]
    [(or (Low 3) (High 3)) 20]
    [_ 30]))

;; A diverging shared body leaves the match without a merge input.
(define (small-early [small : Small]) : i64
  (begin
    (match small
      [(or (Low n) (High n)) (return (+ n 1))]
      [Neither unit])
    5))

;; Macro output spells `or` and `fields` heads through template syntax.
(defmacro (generated-dst [instr : Expr]) : Expr
  `(match ,instr
    [(or (Load dst _ _) (EntryArgc dst)) dst]
    [_ 0]))

(defmacro (generated-start [value : Expr]) : Expr
  `(match ,value
    [(At (fields [first start]) _) first]))

;; Comptime `match` tries the alternatives in order too.
(defmacro (syntax-weight [value : Expr]) : Expr
  (match value
    [(or (comptime.Expr.Int _) (comptime.Expr.Bool _)) (comptime.expr-int 1)]
    [(comptime.Expr.Var _) (comptime.expr-int 2)]
    [_ (comptime.expr-int 3)]))

(define (main) : i64
  (let
    [select : Instr (Select (box (SelectPayload 0 38 "sel")))]
    [load : Instr (Load 3 4 5)]
    [argc : Instr (EntryArgc 9)]
    (begin
      (unless (= (instr-dst (Load 3 4 5)) 3) (return 1))
      (unless (= (instr-dst (EntryArgc 9)) 9) (return 2))
      (unless
        (= (instr-dst (Select (box (SelectPayload 0 38 "sel")))) 38)
        (return 3))
      (unless (= (instr-dst (Move 5 Small)) 105) (return 4))
      (unless (= (instr-dst (Move 6 Large)) 106) (return 5))
      (unless (= (instr-dst Nop) -1) (return 6))
      (unless (= (instr-dst Halt) -1) (return 7))
      (unless (= (instr-dst (Label "x")) -2) (return 8))
      (unless (= (instr-class Halt) 1) (return 9))
      (unless (= (instr-class (Move 1 Small)) 2) (return 10))
      (unless (= (instr-class (Move 1 Large)) 4) (return 11))
      (unless (= (instr-class (EntryArgc 1)) 3) (return 12))
      (unless (= (instr-class (Label "l")) 4) (return 13))
      (unless
        (= (string.string-length (instr-text (Label "four"))) 4)
        (return 14))
      (unless (= (string.string-length (instr-text select)) 3) (return 15))
      (unless (= (borrowed-dst (& load)) 3) (return 16))
      (unless (= (borrowed-dst (& argc)) 9) (return 17))
      (unless (= (digit-class 4) 0) (return 18))
      (unless (= (digit-class 7) 1) (return 19))
      (unless (= (digit-class 12) 2) (return 20))
      (unless (= (flag-score false) 7) (return 21))
      (unless (= (word-score "beta") 1) (return 22))
      (unless (= (word-score "gamma") 0) (return 23))
      (unless (= (span-width (Span 10 25)) 15) (return 24))
      (unless (= (located-score (At (Span 1 30) 2)) 32) (return 25))
      (unless (= (outer-score (Outer (Span 41 50) 0)) 41) (return 26))
      (unless (= (tail-dst (EntryArgc 41)) 42) (return 27))
      (unless (= (pair-value (Right (Num 6))) 6) (return 28))
      (unless (= (pair-value (Left (Flag true))) 1) (return 29))
      (unless (= (pair-sum (Right (Num 6))) 7) (return 30))
      (unless (= (pair-sum (Left (Blank))) 101) (return 31))
      (unless (= (pair-sum (Right (Flag true))) 1) (return 32))
      (unless (= (pair-nested (Right (Num 8))) 8) (return 33))
      (unless (= (name-length (Second "three")) 5) (return 34))
      (unless (= (shadowed 7 (Load 3 4 5)) 3) (return 35))
      (unless (= (shadowed 7 Nop) 7) (return 36))
      (unless (= (syntax-weight 5) 1) (return 37))
      (unless (= (syntax-weight true) 1) (return 38))
      (unless (= (syntax-weight load) 2) (return 39))
      (unless (= (syntax-weight (tail-dst Nop)) 3) (return 40))
      (unless (= (small-value (High 7)) 7) (return 41))
      (unless (= (small-borrowed (Low 8)) 8) (return 42))
      (unless (= (small-literal (Low 2)) 10) (return 43))
      (unless (= (small-literal (High 3)) 20) (return 44))
      (unless (= (small-literal (Low 4)) 30) (return 45))
      (unless (= (small-early (Low 1)) 2) (return 46))
      (unless (= (small-early Neither) 5) (return 47))
      (unless (= (located-borrowed (At (Span 40 50) 2)) 42) (return 48))
      (unless (= (generated-dst (EntryArgc 5)) 5) (return 49))
      (unless (= (generated-start (At (Span 6 9) 1)) 6) (return 50))
      42)))