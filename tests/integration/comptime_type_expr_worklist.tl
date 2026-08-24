(import stdlib.comptime)

(defstruct Leaf
  (value i64))

(defstruct Node
  (value Leaf)
  (next (Box Node)))

(defenum Choice
  (None)
  (One Leaf)
  (Many (Array u8 16)))

;; A direct-self cycle, a mutual Box cycle, and a diamond all feed the reflected
;; graph walk below. The walker owns deduplication by type-key; `type-expr` only
;; turns each newly discovered child back into dense worklist syntax.
(defstruct WorklistSelf
  (value i64)
  (next (Box WorklistSelf)))

(defstruct WorklistMutualLeft
  (right (Box WorklistMutualRight)))

(defstruct WorklistMutualRight
  (left (Box WorklistMutualLeft)))

(defstruct WorklistDiamondLeaf
  (value i64))

(defstruct WorklistDiamondLeft
  (leaf WorklistDiamondLeaf))

(defstruct WorklistDiamondRight
  (leaf WorklistDiamondLeaf))

(defenum WorklistChoice
  (Empty)
  (Recursive (Box WorklistSelf))
  (Diamond WorklistDiamondLeft WorklistDiamondRight))

(defstruct WorklistRoot
  (left WorklistDiamondLeft)
  (right WorklistDiamondRight)
  (cycle WorklistMutualLeft)
  (self (Box WorklistSelf))
  (choice WorklistChoice)
  (items (Array WorklistDiamondLeaf 4))
  (pair (Tuple WorklistDiamondLeft WorklistDiamondRight)))

;; Discover the public child shapes recursively. `work` is scanned from its
;; tail while new unique children are consed at the head, so every key is
;; processed exactly once without needing an append primitive.
(defmacro (type-expr-reachable-count [root : type]) : i64
  (let
    [work : ExprList
      (comptime.expr-list-cons
        (comptime.type-expr root)
        (comptime.expr-list-empty))]
    [processed : i64 0]
    (begin
      (while (< processed (comptime.expr-list-length work))
        (let
          [work-len : i64 (comptime.expr-list-length work)]
          [current : Expr
            (comptime.expr-list-type-nth work (- (- work-len processed) 1))]
          [kind : String (type-kind current)]
          [children : ExprList (comptime.expr-list-empty)]
          [index : i64 0]
          [variant-index : i64 0]
          [payload-index : i64 0]
          (begin
            (match kind
              ["struct"
                (begin
                  (while (< index (struct-field-count current))
                    (begin
                      (set!
                        children
                        (comptime.expr-list-cons
                          (comptime.type-expr (struct-field-type current index))
                          children))
                      (set! index (+ index 1)))))]
              ["enum"
                (begin
                  (while (< variant-index (enum-variant-count current))
                    (begin
                      (set! payload-index 0)
                      (while (<
                        payload-index
                        (enum-variant-payload-count current variant-index))
                        (begin
                          (set!
                            children
                            (comptime.expr-list-cons
                              (comptime.type-expr
                                (enum-variant-payload-type
                                  current
                                  variant-index
                                  payload-index))
                              children))
                          (set! payload-index (+ payload-index 1))))
                      (set! variant-index (+ variant-index 1)))))]
              ["tuple"
                (begin
                  (while (< index (tuple-element-count current))
                    (begin
                      (set!
                        children
                        (comptime.expr-list-cons
                          (comptime.type-expr
                            (tuple-element-type current index))
                          children))
                      (set! index (+ index 1)))))]
              ["function"
                (begin
                  (while (< index (function-param-count current))
                    (begin
                      (set!
                        children
                        (comptime.expr-list-cons
                          (comptime.type-expr
                            (function-param-type current index))
                          children))
                      (set! index (+ index 1))))
                  (set!
                    children
                    (comptime.expr-list-cons
                      (comptime.type-expr (function-return-type current))
                      children)))]
              ["array"
                (set!
                  children
                  (comptime.expr-list-cons
                    (comptime.type-expr (array-element-type current))
                    children))]
              ["dyn-array"
                (set!
                  children
                  (comptime.expr-list-cons
                    (comptime.type-expr (array-element-type current))
                    children))]
              ["slice"
                (set!
                  children
                  (comptime.expr-list-cons
                    (comptime.type-expr (array-element-type current))
                    children))]
              ["box"
                (set!
                  children
                  (comptime.expr-list-cons
                    (comptime.type-expr (box-element-type current))
                    children))]
              ["ref"
                (set!
                  children
                  (comptime.expr-list-cons
                    (comptime.type-expr (reference-element-type current))
                    children))]
              ["mut-ref"
                (set!
                  children
                  (comptime.expr-list-cons
                    (comptime.type-expr (reference-element-type current))
                    children))]
              [_ unit])
            (set! index 0)
            (while (< index (comptime.expr-list-length children))
              (let
                [child : Expr (comptime.expr-list-type-nth children index)]
                [child-key : String (type-key child)]
                [scan : i64 0]
                [known : bool false]
                (begin
                  (while (< scan (comptime.expr-list-length work))
                    (begin
                      (if (__tl_string_eq
                        (type-key (comptime.expr-list-type-nth work scan))
                        child-key)
                        (set! known true)
                        unit)
                      (set! scan (+ scan 1))))
                  (if known
                    unit
                    (set!
                      work
                      (comptime.expr-list-cons (comptime.type-expr child) work)))
                  (set! index (+ index 1)))))
            (set! processed (+ processed 1)))))
      (comptime.expr-int (comptime.expr-list-length work)))))

;; Store 100 reflected roots as newly constructed opaque type expressions,
;; reverse their order through ExprList cons, then recover and compare every
;; type. Repeated roots deliberately model the caller-selected dedup layer of a
;; graph walk without making `type-expr` itself responsible for policy.
(defmacro (type-expr-worklist [roots : Expr ...]) : i64
  (let
    [count : i64 (comptime.expr-list-length roots)]
    [work : ExprList (comptime.expr-list-empty)]
    [index : i64 0]
    [ok : bool true]
    [failure : i64 -1]
    (begin
      (while (< index count)
        (begin
          (set!
            work
            (comptime.expr-list-cons
              (comptime.type-expr (comptime.expr-list-type-nth roots index))
              work))
          (set! index (+ index 1))))
      (set! index 0)
      (while (< index count)
        (begin
          (if (=
            (comptime.expr-list-type-nth work index)
            (comptime.expr-list-type-nth roots (- (- count index) 1)))
            unit
            (begin
              (set! ok false)
              (if (< failure 0)
                (set! failure index)
                unit)))
          (set! index (+ index 1))))
      (comptime.expr-int
        (if ok
          (if (= count 100)
            42
            0)
          (+ failure 1))))))

(define (main) : i64
  (let
    [flat : i64
      (type-expr-worklist
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice)
        (type i64)
        (type (Array u8 16))
        (type (Slice Leaf))
        (type (Tuple i64 bool String))
        (type (-> i64 bool String))
        (type (Box Node))
        (type (Ptr Leaf))
        (type (MutPtr Choice))
        (type Leaf)
        (type Choice))]
    [reachable : i64 (type-expr-reachable-count WorklistRoot)]
    (if (= reachable 14)
      flat
      0)))