;; `comptime.current-module` names the module a macro call expands into, in
;; `type-nominal-module`'s form: `""` for the root file, the canonical identity
;; for a named module. A macro defined elsewhere reports its call site, for
;; both expression and `: Decls` macros (#8102).
(import stdlib.string)
(import comptime_current.provider)
(import comptime_current.user)

(defstruct RootThing
  (x i64))

(provider.declare-where root-declared)

(define (main) : i64
  (let
    [root-expr : String (provider.where)]
    [root-decl : String (root-declared)]
    [provider-expr : String (provider.provider-where)]
    [provider-decl : String (provider.provider-declared)]
    [user-expr : String (user.where)]
    [user-decl : String (user.declared)]
    (cond
      [(not (string.eq root-expr "")) 1]
      [(not (string.eq root-decl "")) 2]
      [(not (string.eq provider-expr "comptime_current.provider")) 3]
      [(not (string.eq provider-decl "comptime_current.provider")) 4]
      [(not (string.eq user-expr "comptime_current.user")) 5]
      [(not (string.eq user-decl "comptime_current.user")) 6]
      [(not (user.owns?)) 7]
      [(provider.owned-here? user.UserThing) 8]
      [(not (provider.owned-here? RootThing)) 9]
      [else 42])))