(import stdlib.arena)
(import stdlib.io)
(import sym_i64_env as env)

(test
  symbol-environment-copy-outlives-source-and-preserves-shadowing
  (let
    [home : arena.Arena (arena.current)]
    [copied : env.SymI64Env
      (with-scratch
        (let
          [source : env.SymI64Env
            (env.sym-i64-bind-id
              (env.sym-i64-bind-id (env.sym-i64-empty) 7 11)
              9
              23)]
          [snapshot : env.SymI64Env
            (env.sym-i64-bind-id (env.sym-i64-shared-view (& source)) 7 0)]
          [_other : env.SymI64Env (env.sym-i64-bind-id source 12 99)]
          (in-arena home (env.sym-i64-copy snapshot))))]
    (begin
      (with-scratch
        (let
          [reuse : (__tl_dyn-array i64) (__tl_make-array i64 1048576)]
          (set! (array-ref reuse 0) 7797)))
      (unless
        (and
          (= (env.sym-i64-lookup-id-or (& copied) 7 -1) 0)
          (= (env.sym-i64-lookup-id-or (& copied) 9 -1) 23)
          (= (env.sym-i64-lookup-id-or (& copied) 12 -1) -1))
        (io.panic "copied symbol environment lost snapshot or shadowing"))
      (match (env.sym-i64-view copied)
        [(env.SymI64ViewBind key value rest)
          (unless
            (and
              (= key 7)
              (= value 0)
              (= (env.sym-i64-lookup-id-or (& rest) 7 -1) 11))
            (io.panic "copied symbol environment lost older binding"))]
        [_ (io.panic "copied symbol environment was empty")]))))