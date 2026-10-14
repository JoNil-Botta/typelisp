;; Native subprocess cases: each invalid input reaches its real table guard.
(import compiler_intern as ci)
(import compiler_intern_state as cis)
(import compiler_optimize as opt)
(import compiler_ast_types as ast)
(import token)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (if (< (io.arg-count) 2)
    2
    (let
      [operation : String (io.arg 1)]
      (cond
        [(string.eq operation "intern")
          (ci.intern-id-from-renderable -1)
          0]
        [(string.eq operation "session")
          (cis.intern-structural-session-key
            (cis.InternStructuralSessionHandle 0)
            0
            0
            0
            0)
          0]
        [(string.eq operation "optimizer")
          (opt.opt-ssa-env-rollback (opt.opt-ssa-env-with-capacity 1 1 1) -1)
          0]
        [(string.eq operation "token")
          (let
            [wrong : token.Token (token.Token.End)]
            (token.sym-id (& wrong))
            0)]
        [(string.eq operation "revision")
          ;; Deliberately exhaust the process-lifetime identity allocator.
          (unsafe
            (ptr-write!
              (ptr-addr-of ast.ast-type-pool-next-revision)
              9223372036854775807))
          (ast.ast-type-pool-revision-fresh!)
          0]
        [(string.eq operation "retired")
          (let
            [pools : ast.AstNodePoolContext
              (ast.ast-node-pool-context-new-with-capacities 1 1)]
            (ast.ast-node-pool-context-type-retire! (& pools))
            (ast.ast-node-pool-context-type-push pools (ast.AstType.I64))
            0)]
        [(string.eq operation "valid")
          (let
            [env : opt.OptSsaRenameEnv
              (opt.opt-ssa-env-register (opt.opt-ssa-env-with-capacity 1 1 1) 0)]
            [bound : opt.OptSsaRenameEnv (opt.opt-ssa-env-bind env 0 42)]
            [restored : opt.OptSsaRenameEnv (opt.opt-ssa-env-rollback bound 0)]
            (if (= (opt.opt-ssa-env-checkpoint (& restored)) 0)
              42
              1))]
        [else 3]))))