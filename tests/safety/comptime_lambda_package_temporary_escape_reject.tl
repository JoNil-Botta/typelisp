(import stdlib.comptime)
(import stdlib.string)

;; A capture-free renderer may travel with borrowed anchors, but the package
;; itself cannot extend an anchor created for a temporary beyond its generated
;; shared scope.
(defmacro (make-reference-package [anchors : Expr]) : Expr
  (let
    [T : Expr (comptime.expr-type anchors)]
    [name : String (comptime.syntax-name-fresh "temporary-anchors")]
    [values : Expr (comptime.expr-var name)]
    [text : Expr (comptime.expr-tuple-ref values 0)]
    [body : Expr `(string-length ,text)]
    [renderer : Expr (comptime.expr-lambda1 name T body)]
    `(tuple ,renderer ,anchors)))

(defmacro (make-scoped-package [value : Expr]) : Expr
  (let
    [name : String (comptime.syntax-name-fresh "temporary-owner")]
    [borrowed : Expr (comptime.expr-var name)]
    [body : Expr `(make-reference-package (tuple ,borrowed))]
    (comptime.expr-shared-let-scope name value body)))

(define (main) : i64
  (let
    [arguments (make-scoped-package "temporary")]
    ((tuple-ref arguments 0) (tuple-ref arguments 1))))