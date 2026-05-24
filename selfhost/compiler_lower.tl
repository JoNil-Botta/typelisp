;; compiler_lower.tl - First selfhost compiler AST-to-IR lowering slice (#446).
;;
;; This pass intentionally stops at a deterministic IR summary. It defines and
;; walks the same scalar shapes the first real backend slice needs, while
;; keeping aggregate and closure lowering as explicit future work.

(import "compiler_typecheck.tl")
(import "compiler_ir_types.tl")

(defenum LowerState
  (LowerState i64 i64 i64))

(defenum LowerAlloc
  (LowerAlloc LowerState i64))

(defenum LowerExpr
  (LowerExpr LowerState CompilerIrValue))

(defenum ResultLowerExpr
  (OkLowerExpr LowerExpr)
  (ErrLowerExpr String))

(defenum ResultLowerArgs
  (OkLowerArgs LowerState CompilerIrValueList)
  (ErrLowerArgs String))

(defenum ResultLowerEnv
  (OkLowerEnv LowerState SymI64Env)
  (ErrLowerEnv String))

(defenum LowerFunctionSummary
  (LowerFunctionSummary i64 i64 i64))

(defenum ResultLowerFunction
  (OkLowerFunction LowerFunctionSummary)
  (ErrLowerFunction String))

(defenum ResultCompilerLower
  (OkCompilerLower CompilerIrSummary)
  (ErrCompilerLower String))

(define (lower-state-next-var [state : LowerState]) : i64
  (match state
    [(LowerState next-var _ _) next-var]))

(define (lower-state-blocks [state : LowerState]) : i64
  (match state
    [(LowerState _ blocks _) blocks]))

(define (lower-state-instructions [state : LowerState]) : i64
  (match state
    [(LowerState _ _ instructions) instructions]))

(define (lower-state-add-instr [state : LowerState]) : LowerState
  (match state
    [(LowerState next-var blocks instructions)
     (LowerState next-var blocks (+ instructions 1))]))

(define (lower-state-add-blocks [state : LowerState] [n : i64]) : LowerState
  (match state
    [(LowerState next-var blocks instructions)
     (LowerState next-var (+ blocks n) instructions)]))

(define (lower-state-alloc-var [state : LowerState]) : LowerAlloc
  (match state
    [(LowerState next-var blocks instructions)
     (LowerAlloc (LowerState (+ next-var 1) blocks instructions) next-var)]))

(define (lower-materialize [state : LowerState] [value : CompilerIrValue]) : ResultLowerExpr
  (match (lower-state-alloc-var state)
    [(LowerAlloc allocated var-id)
     (OkLowerExpr (LowerExpr (lower-state-add-instr allocated) (IrValueVar var-id)))]))

(define (lower-literal-value [lit : AstLiteral]) : CompilerIrValue
  (match lit
    [(AstLitInt n) (IrValueI64 n)]
    [(AstLitFloat n) (IrValueF64 n)]
    [(AstLitBool b) (IrValueBool b)]
    [(AstLitChar c) (IrValueChar c)]
    [(AstLitString s) (IrValueString s)]
    [(AstLitUnit) IrValueUnit]))

(define (lower-binop [op : AstBinOp]) : CompilerIrBinOp
  (match op
    [(AstBinAdd) IrBinAdd]
    [(AstBinSub) IrBinSub]
    [(AstBinMul) IrBinMul]
    [(AstBinDiv) IrBinDiv]
    [(AstBinMod) IrBinMod]
    [(AstBinEq) IrBinEq]
    [(AstBinNe) IrBinNe]
    [(AstBinLt) IrBinLt]
    [(AstBinLe) IrBinLe]
    [(AstBinGt) IrBinGt]
    [(AstBinGe) IrBinGe]
    [(AstBinAnd) IrBinAnd]
    [(AstBinOr) IrBinOr]
    [(AstBinBitAnd) IrBinBitAnd]
    [(AstBinBitOr) IrBinBitOr]
    [(AstBinBitXor) IrBinBitXor]
    [(AstBinShl) IrBinShl]
    [(AstBinShr) IrBinShr]))

(define (lower-unop [op : AstUnOp]) : CompilerIrUnOp
  (match op
    [(AstUnNeg) IrUnNeg]
    [(AstUnNot) IrUnNot]
    [(AstUnBitNot) IrUnBitNot]))

(define (lower-var [state : LowerState] [env : SymI64Env] [name : String]) : ResultLowerExpr
  (match (sym-i64-lookup env name)
    [(SomeI64 id) (lower-materialize state (IrValueVar id))]
    [(NoneI64) (lower-materialize state (IrValueGlobal name))]))

(define (lower-value-var-id [value : CompilerIrValue]) : MaybeI64
  (match value
    [(IrValueVar id) (SomeI64 id)]
    [_ NoneI64]))

(define (lower-expr [state : LowerState] [env : SymI64Env] [expr : AstExpr]) : ResultLowerExpr
  (match expr
    [(AstExprSpanned inner _) (lower-expr state env inner)]
    [(AstExprLiteral lit) (lower-materialize state (lower-literal-value lit))]
    [(AstExprVar name) (lower-var state env name)]
    [(AstExprAnn inner _) (lower-expr state env inner)]
    [(AstExprCast inner _)
     (match (lower-expr state env inner)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state _)
           (lower-materialize inner-state (IrValueUnit))])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprUnary op inner)
     (match (lower-expr state env inner)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr inner-state _)
           (lower-materialize inner-state (IrValueUnit))])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprBinary op left right)
     (match (lower-expr state env left)
       [(OkLowerExpr left-lowered)
        (match left-lowered
          [(LowerExpr left-state _)
           (match (lower-expr left-state env right)
             [(OkLowerExpr right-lowered)
              (match right-lowered
                [(LowerExpr right-state _)
                 (lower-materialize right-state (IrValueUnit))])]
             [(ErrLowerExpr message) (ErrLowerExpr message)])])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprCall func args) (lower-call state env func args)]
    [(AstExprLet bindings body)
     (match (lower-let-bindings state env bindings)
       [(OkLowerEnv binding-state body-env) (lower-expr binding-state body-env body)]
       [(ErrLowerEnv message) (ErrLowerExpr message)])]
    [(AstExprBegin exprs) (lower-begin state env exprs)]
    [(AstExprSet name value)
     (match (sym-i64-lookup env name)
       [(SomeI64 _)
        (match (lower-expr state env value)
          [(OkLowerExpr lowered)
           (match lowered
             [(LowerExpr value-state _)
              (OkLowerExpr (LowerExpr (lower-state-add-instr value-state) IrValueUnit))])]
          [(ErrLowerExpr message) (ErrLowerExpr message)])]
       [(NoneI64) (ErrLowerExpr (string-append "lower: assignment to unknown local " name))])]
    [(AstExprIf cond then-branch else-branch)
     (match (lower-expr state env cond)
       [(OkLowerExpr cond-lowered)
        (match cond-lowered
          [(LowerExpr cond-state _)
           (let ([branch-state : LowerState (lower-state-add-instr (lower-state-add-blocks cond-state 3))])
             (match (lower-expr branch-state env then-branch)
               [(OkLowerExpr then-lowered)
                (match then-lowered
                  [(LowerExpr then-state _)
                   (let ([then-jump-state : LowerState (lower-state-add-instr then-state)])
                     (match (lower-expr then-jump-state env else-branch)
                       [(OkLowerExpr else-lowered)
                        (match else-lowered
                          [(LowerExpr else-state _)
                           (lower-materialize (lower-state-add-instr else-state) IrValueUnit)])]
                       [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
               [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
       [(ErrLowerExpr message) (ErrLowerExpr message)])]
    [(AstExprWhile cond body)
     (let ([loop-state : LowerState (lower-state-add-instr (lower-state-add-blocks state 3))])
       (match (lower-expr loop-state env cond)
         [(OkLowerExpr cond-lowered)
          (match cond-lowered
            [(LowerExpr cond-state _)
             (let ([body-start : LowerState (lower-state-add-instr cond-state)])
               (match (lower-expr body-start env body)
                 [(OkLowerExpr body-lowered)
                  (match body-lowered
                    [(LowerExpr body-state _)
                     (OkLowerExpr (LowerExpr (lower-state-add-instr body-state) IrValueUnit))])]
                 [(ErrLowerExpr message) (ErrLowerExpr message)]))])]
         [(ErrLowerExpr message) (ErrLowerExpr message)]))]
    [_ (ErrLowerExpr "lower: unsupported expression")]))

(define (lower-call [state : LowerState] [env : SymI64Env] [func : AstExpr] [args : AstExprList]) : ResultLowerExpr
  (match func
    [(AstExprVar name)
     (match (lower-args state env args)
       [(OkLowerArgs args-state _)
        (lower-materialize args-state (IrValueUnit))]
       [(ErrLowerArgs message) (ErrLowerExpr message)])]
    [_ (ErrLowerExpr "lower: only direct calls are supported")]))

(define (lower-args [state : LowerState] [env : SymI64Env] [args : AstExprList]) : ResultLowerArgs
  (match args
    [(AstExprNil) (OkLowerArgs state IrValueNil)]
    [(AstExprCons arg rest)
     (match (lower-expr state env arg)
       [(OkLowerExpr lowered)
        (match lowered
          [(LowerExpr arg-state value)
           (match (lower-args arg-state env rest)
             [(OkLowerArgs rest-state rest-values)
              (OkLowerArgs rest-state (IrValueCons value rest-values))]
             [(ErrLowerArgs message) (ErrLowerArgs message)])])]
       [(ErrLowerExpr message) (ErrLowerArgs message)])]))

(define (lower-let-bindings [state : LowerState] [env : SymI64Env] [bindings : AstLetBindingList]) : ResultLowerEnv
  (match bindings
    [(AstLetBindingNil) (OkLowerEnv state env)]
    [(AstLetBindingCons binding rest)
     (match binding
       [(AstLetBinding name _ init)
        (match (lower-expr state env init)
          [(OkLowerExpr lowered)
           (match lowered
             [(LowerExpr init-state value)
              (match (lower-value-var-id value)
                [(SomeI64 id) (lower-let-bindings init-state (sym-i64-bind env name id) rest)]
                [(NoneI64) (ErrLowerEnv "lower: let binding did not produce a value")])])]
          [(ErrLowerExpr message) (ErrLowerEnv message)])])]))

(define (lower-begin [state : LowerState] [env : SymI64Env] [exprs : AstExprList]) : ResultLowerExpr
  (match exprs
    [(AstExprNil) (OkLowerExpr (LowerExpr state IrValueUnit))]
    [(AstExprCons expr rest)
     (match rest
       [(AstExprNil) (lower-expr state env expr)]
       [_ (match (lower-expr state env expr)
            [(OkLowerExpr lowered)
             (match lowered
               [(LowerExpr next-state _) (lower-begin next-state env rest)])]
            [(ErrLowerExpr message) (ErrLowerExpr message)])])]))

(define (lower-param-count [params : AstParamList]) : i64
  (match params
    [(AstParamNil) 0]
    [(AstParamCons _ rest) (+ 1 (lower-param-count rest))]))

(define (lower-bind-params [params : AstParamList] [idx : i64] [env : SymI64Env]) : SymI64Env
  (match params
    [(AstParamNil) env]
    [(AstParamCons param rest)
     (match param
       [(AstParam name _) (lower-bind-params rest (+ idx 1) (sym-i64-bind env name idx))])]))

(define (lower-function [name : String] [params : AstParamList] [body : AstExpr]) : ResultLowerFunction
  (let ([param-count : i64 (lower-param-count params)])
    (let ([env : SymI64Env (lower-bind-params params 0 (sym-i64-empty))]
          [state : LowerState (LowerState param-count 1 0)])
      (match (lower-expr state env body)
        [(OkLowerExpr lowered)
         (match lowered
           [(LowerExpr body-state _)
            (let ([final-state : LowerState (lower-state-add-instr body-state)])
              (OkLowerFunction
                (LowerFunctionSummary
                  (lower-state-blocks final-state)
                  (lower-state-instructions final-state)
                  (lower-state-next-var final-state))))])]
        [(ErrLowerExpr message) (ErrLowerFunction message)]))))

(define (lower-summary-empty) : CompilerIrSummary
  (CompilerIrSummary 0 0 0 0 0 0))

(define (lower-summary-add-global [summary : CompilerIrSummary]) : CompilerIrSummary
  (match summary
    [(CompilerIrSummary globals functions externs blocks instructions vars)
     (CompilerIrSummary (+ globals 1) functions externs blocks instructions vars)]))

(define (lower-summary-add-extern [summary : CompilerIrSummary]) : CompilerIrSummary
  (match summary
    [(CompilerIrSummary globals functions externs blocks instructions vars)
     (CompilerIrSummary globals functions (+ externs 1) blocks instructions vars)]))

(define (lower-summary-add-function [summary : CompilerIrSummary] [fn-summary : LowerFunctionSummary]) : CompilerIrSummary
  (match summary
    [(CompilerIrSummary globals functions externs blocks instructions vars)
     (match fn-summary
       [(LowerFunctionSummary fn-blocks fn-instructions fn-vars)
        (CompilerIrSummary
          globals
          (+ functions 1)
          externs
          (+ blocks fn-blocks)
          (+ instructions fn-instructions)
          (+ vars fn-vars))])]))

(define (lower-decls [decls : AstDeclList] [summary : CompilerIrSummary]) : ResultCompilerLower
  (match decls
    [(AstDeclNil) (OkCompilerLower summary)]
    [(AstDeclCons decl rest)
     (match decl
       [(AstDeclDef _ _ _) (lower-decls rest (lower-summary-add-global summary))]
       [(AstDeclExtern _ _) (lower-decls rest (lower-summary-add-extern summary))]
       [(AstDeclDefFn name params _ body)
        (match (lower-function name params body)
          [(OkLowerFunction fn-summary)
           (lower-decls rest (lower-summary-add-function summary fn-summary))]
          [(ErrLowerFunction message) (ErrCompilerLower message)])]
       [(AstDeclImport _) (lower-decls rest summary)]
       [(AstDeclDefEnum _ _) (lower-decls rest summary)]
       [(AstDeclDefStruct _ _) (lower-decls rest summary)])]))

(define (lower-compiler-program-checked [program : AstProgram]) : ResultCompilerLower
  (match program
    [(AstProgram decls) (lower-decls decls (lower-summary-empty))]))

(define (lower-compiler-program [program : AstProgram]) : ResultCompilerLower
  (match (typecheck-compiler-program program)
    [(OkCompilerTypecheck _) (lower-compiler-program-checked program)]
    [(ErrCompilerTypecheck message) (ErrCompilerLower message)]))

(define (lower-compiler-source [src : String]) : ResultCompilerLower
  (match (parse-ast-source src)
    [(OkAstProgram program) (lower-compiler-program program)]
    [(ErrAstProgram message) (ErrCompilerLower message)]))

(define (compiler-lower-smoke-source) : String
  "(extern print-i64 : (-> i64 unit))
(define answer : i64 40)
(define (inc [x : i64]) : i64 (+ x 1))
(define (main [flag : bool]) : i64
  (let ([x : i64 (inc answer)])
    (begin
      (set! x (+ x 1))
      (while (< x 45)
        (set! x (+ x 1)))
      (if flag x 0))))")

(define (compiler-lower-unsupported-source) : String
  "(define (main) : (Tuple i64 bool)
  (tuple 1 true))")

(define (compiler-lower-error-ok? [src : String] [want : String]) : bool
  (match (lower-compiler-source src)
    [(ErrCompilerLower message) (string-eq message want)]
    [(OkCompilerLower _) false]))

(define (compiler-lower-ok-summary? [src : String]) : bool
  (match (lower-compiler-source src)
    [(OkCompilerLower summary)
     (and (= (compiler-ir-summary-globals summary) 1)
          (and (= (compiler-ir-summary-functions summary) 2)
               (and (= (compiler-ir-summary-externs summary) 1)
                    (and (= (compiler-ir-summary-blocks summary) 8)
                         (and (= (compiler-ir-summary-instructions summary) 28)
                              (= (compiler-ir-summary-vars summary) 20))))))]
    [(ErrCompilerLower _) false]))

(define (compiler-lower-self-test) : i64
  (if (and (compiler-lower-ok-summary? (compiler-lower-smoke-source))
           (and (compiler-lower-error-ok? (compiler-typecheck-branch-mismatch-source)
                                          "typecheck: if branches must match")
                (compiler-lower-error-ok? (compiler-lower-unsupported-source)
                                          "lower: unsupported expression")))
      42
      (begin
        (panic "lower: smoke score mismatch")
        0)))
