(import stdlib.comptime)
(import stdlib.string)

(defstruct Owner
  (text String)
  (value i64))

(define (read-owner [owner : (& caller Owner)]) : i64
  owner.value)

;; Keep the renderer capture-free: its opaque parameter type is the exact
;; reflected type of the heterogeneous shared-reference tuple.
(defmacro (render-anchor-package-twice [anchors : Expr]) : i64
  (let
    ;; lint-allow: unused-variable -- consumed in generated type positions.
    [reflected-type : Expr (comptime.expr-type anchors)]
    [renderer : Expr
      `(lambda ([values : ,reflected-type]) : i64
        (+
          (read-owner (tuple-ref values 0))
          (string-length (tuple-ref values 1))))]
    `(let
      [renderer : (-> ,reflected-type i64) ,renderer]
      [anchors : ,reflected-type ,anchors]
      [arguments : (Tuple (-> ,reflected-type i64) ,reflected-type)
        (tuple renderer anchors)]
      (+
        ((tuple-ref arguments 0) (tuple-ref arguments 1))
        ((tuple-ref arguments 0) (tuple-ref arguments 1))))))

(defmacro (render-values-twice [owner : Expr] [text : Expr]) : i64
  (let
    [owner-name : String (comptime.syntax-name-fresh "render-owner")]
    [text-name : String (comptime.syntax-name-fresh "render-text")]
    [owner-var : Expr (comptime.expr-var owner-name)]
    [text-var : Expr (comptime.expr-var text-name)]
    [body : Expr `(render-anchor-package-twice (tuple ,owner-var ,text-var))]
    (comptime.expr-shared-let-scope
      owner-name
      owner
      (comptime.expr-shared-let-scope text-name text body))))

;; Also pin the direct generated reference-capture path which previously could
;; crash while the macro-expansion wrapper was being unspanned.
(defmacro (make-reader [borrowed : Expr]) : Expr
  `(lambda () : i64
    (string-length ,borrowed)))

(define (next-owner [counter : (&mut counter (Array i64 1))]) : Owner
  (begin
    (set! (array-ref counter 0) (+ (array-ref counter 0) 1))
    (Owner "kept" 24)))

(define (next-text [counter : (&mut counter (Array i64 1))]) : String
  (begin
    (set! (array-ref counter 0) (+ (array-ref counter 0) 1))
    "123456789"))

(define (lvalue-case) : i64
  (let
    [owner : Owner (Owner "not-moved" 24)]
    [text : String "123456789"]
    [rendered : i64 (render-values-twice owner text)]
    (if (= rendered 66)
      (+ owner.value (string-length (& text)))
      0)))

(define (rvalue-case) : i64
  (let
    [counter : (Array i64 1) (array 0)]
    [rendered : i64
      (render-values-twice
        (next-owner (&mut counter))
        (next-text (&mut counter)))]
    (if (= rendered 66)
      (array-ref counter 0)
      0)))

(define (direct-generated-capture-case) : i64
  (let
    [owner : String "forty-two"]
    [borrowed : (& owner str) (& owner)]
    [reader : (-> i64) (make-reader borrowed)]
    (+ (reader) (reader))))

(define (main) : i64
  (begin
    (unless (= (lvalue-case) 33) (return 1))
    (unless (= (rvalue-case) 2) (return 2))
    (unless (= (direct-generated-capture-case) 18) (return 3))
    42))