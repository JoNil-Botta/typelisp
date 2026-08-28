(import stdlib.comptime)
(import stdlib.string)

(defstruct Owner
  (text String)
  (value i64))

(define (read-owner [owner : (& caller Owner)]) : i64
  owner.value)

;; Build a reusable `(renderer, anchors)` package. The renderer body is
;; assembled before the lambda exists, so this covers the public hygienic
;; builder path rather than the direct type-unquote template path.
(defmacro (make-anchor-package [anchors : Expr]) : Expr
  (let
    [reflected-type : Expr (comptime.expr-type anchors)]
    [parameter-name : String (comptime.syntax-name-fresh "renderer-anchors")]
    [values : Expr (comptime.expr-var parameter-name)]
    [owner : Expr (comptime.expr-tuple-ref values 0)]
    [text : Expr (comptime.expr-tuple-ref values 1)]
    [body : Expr `(+ (read-owner ,owner) (string-length ,text))]
    [renderer : Expr (comptime.expr-lambda1 parameter-name reflected-type body)]
    `(tuple ,renderer ,anchors)))

;; The rvalue path keeps the returned package inside the generated shared
;; scopes, where it may be invoked repeatedly without extending a temporary.
(defmacro (render-anchor-package-twice [anchors : Expr]) : i64
  `(let
    [arguments (make-anchor-package ,anchors)]
    (+
      ((tuple-ref arguments 0) (tuple-ref arguments 1))
      ((tuple-ref arguments 0) (tuple-ref arguments 1)))))

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
    ;; This package is returned by the macro to ordinary caller code, bound,
    ;; and invoked twice. Its anchors are shared references, so neither owner
    ;; is moved or cloned.
    [arguments (make-anchor-package (tuple (& owner) (& text)))]
    [rendered : i64
      (+
        ((tuple-ref arguments 0) (tuple-ref arguments 1))
        ((tuple-ref arguments 0) (tuple-ref arguments 1)))]
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