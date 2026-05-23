;; tl_ast.tl - Milestone 1 self-hosting compiler AST + parser.
;;
;; This is the front-end half of the first self-hosted compiler slice (#154):
;; it defines the compiler's own M1 AST as TypeLisp `defenum`s and provides a
;; parser from the generic `Sexpr` tree (built by `tl_read.tl`) into that AST.
;; The sibling codegen slice (`tl_emit.tl`) imports and reuses these definitions.
;;
;; This module is `main`-less so that importer programs carry their own `main`.
;; It imports the shared `tl_read.tl` reader (which transitively pulls in the
;; lexer and token model) for the `Sexpr` enum and the `read-form` cursor API.

(import "tl_read.tl")

;; --------------------------------------------------------------------------
;; The M1 AST: typed s-expressions the emitter lowers to x86_64 assembly.
;; --------------------------------------------------------------------------
;; `BinOp` is the arithmetic operator repertoire for the first self-hosting
;; slice: addition, subtraction, and multiplication.  Expanded operators are
;; deferred to later milestones.
(defenum BinOp
  (OpAdd)
  (OpSub)
  (OpMul))

;; `Expr` is an expression node in the typed AST.
;;   (EInt n)          integer literal
;;   (EVar name)       variable reference
;;   (EBin op l r)     binary operator application
;;   (ECall name args) function call
(defenum Expr
  (EInt i64)
  (EVar String)
  (EBin BinOp Expr Expr)
  (ECall String ExprList))

;; Monomorphic list of Expr nodes.  TypeLisp has no generic type parameters,
;; so each element type gets its own cons-list enum.
;;   (ELNil)           empty list
;;   (ELCons head tail) prepend a head Expr and a tail ExprList
(defenum ExprList
  (ELNil)
  (ELCons Expr ExprList))

;; Monomorphic list of String parameter names.
;;   (SLNil)           empty list
;;   (SLCons head tail) prepend a head String and a tail StrList
(defenum StrList
  (SLNil)
  (SLCons String StrList))

;; A top-level program item.
;;   (IDefFn name params body)  a function definition
(defenum Item
  (IDefFn String StrList Expr))

;; --------------------------------------------------------------------------
;; Helper: extract the SSym name from an Sexpr, or panic.
;; --------------------------------------------------------------------------
(define (expect-sym [e : Sexpr]) : String
  (match e
    [(SSym name) name]
    [_ (begin (panic "ast: expected symbol") "")]))

;; --------------------------------------------------------------------------
;; sexpr-head / sexpr-tail: safe car/cdr for SCons cells, panic otherwise.
;; --------------------------------------------------------------------------
;; These shadow the reader's sexpr-head / sexpr-tail accessors (imported from
;; tl_read.tl) with the same shape — the module loader resolves the duplicate
;; names in importer order, so this module's definitions take precedence.
(define (sexpr-head [e : Sexpr]) : Sexpr
  (match e
    [(SCons h _) h]
    [_ (begin (panic "ast: expected cons cell") SNil)]))

(define (sexpr-tail [e : Sexpr]) : Sexpr
  (match e
    [(SCons _ t) t]
    [_ (begin (panic "ast: expected cons cell") SNil)]))

;; --------------------------------------------------------------------------
;; parse-expr-list: convert a list-shaped Sexpr spine into an ExprList.
;; --------------------------------------------------------------------------
;; Reads forms from the Sexpr spine until SNil.
(define (parse-expr-list [e : Sexpr]) : ExprList
  (match e
    [(SNil) ELNil]
    [(SCons head tail)
     (ELCons (parse-expr head) (parse-expr-list tail))]
    [_ (begin (panic "ast: malformed expression list") ELNil)]))

;; --------------------------------------------------------------------------
;; parse-expr: convert one Sexpr into an Expr.
;; --------------------------------------------------------------------------
;; Integer atom -> EInt
;; Symbol atom  -> EVar
;; List-shaped: (op lhs rhs) where op is + - * -> EBin
;;              (name args...)                -> ECall
(define (parse-expr [e : Sexpr]) : Expr
  (match e
    [(SInt n) (EInt n)]
    [(SSym name) (EVar name)]
    [(SCons head tail)
     (match head
       [(SSym op)
        (if (string-eq op "+")
            (EBin (OpAdd)
              (parse-expr (sexpr-head tail))
              (parse-expr (sexpr-head (sexpr-tail tail))))
            (if (string-eq op "-")
                (EBin (OpSub)
                  (parse-expr (sexpr-head tail))
                  (parse-expr (sexpr-head (sexpr-tail tail))))
                (if (string-eq op "*")
                    (EBin (OpMul)
                      (parse-expr (sexpr-head tail))
                      (parse-expr (sexpr-head (sexpr-tail tail))))
                    (ECall op (parse-expr-list tail)))))]
       [_ (begin (panic "ast: call head must be symbol") (EInt 0))])]
    [_ (begin (panic "ast: malformed expression") (EInt 0))]))

;; --------------------------------------------------------------------------
;; parse-str-list: convert a list of symbol Sexprs into a StrList of names.
;; --------------------------------------------------------------------------
;; Each element must be an SSym; anything else panics.
(define (parse-str-list [e : Sexpr]) : StrList
  (match e
    [(SNil) SLNil]
    [(SCons head tail)
     (SLCons (expect-sym head) (parse-str-list tail))]
    [_ (begin (panic "ast: malformed string list") SLNil)]))

;; --------------------------------------------------------------------------
;; parse-item: convert a top-level Sexpr into an Item.
;; --------------------------------------------------------------------------
;; Expects a `(define (name params...) body)` shape.
;;   head is (SSym "define")
;;   tail is ((name params ...) body)
;; We destructure through the nested cons cells:
;;   tail     = (SCons (SCons (SSym name) params) body-cons)
;;   params   = the rest of the inner SCons (as Sexpr list of symbols)
;;   body-cons = (SCons body SNil)
(define (parse-item [e : Sexpr]) : Item
  (match e
    [(SCons (SSym define-sym) tail)
     (if (string-eq define-sym "define")
         (match tail
           [(SCons inner rest)
            (match inner
              [(SCons (SSym name) params)
               (match rest
                 [(SCons body SNil)
                  (IDefFn name (parse-str-list params) (parse-expr body))]
                 [_ (begin (panic "ast: define must have exactly one body")
                           (IDefFn "" SLNil (EInt 0)))])]
              [_ (begin (panic "ast: define must name a function")
                        (IDefFn "" SLNil (EInt 0)))])]
           [_ (begin (panic "ast: malformed define")
                     (IDefFn "" SLNil (EInt 0)))])
         (begin (panic "ast: expected define form") (IDefFn "" SLNil (EInt 0))))]
    [_ (begin (panic "ast: expected define form") (IDefFn "" SLNil (EInt 0)))]))
