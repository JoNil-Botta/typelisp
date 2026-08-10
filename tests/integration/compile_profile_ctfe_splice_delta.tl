;; CTFE metadata must follow reflection-relevant splices additively. This covers
;; ordinary Decls, a generated Module, a generated source-file materialization,
;; owner-arena vector growth, and import-identity invalidation.
(import stdlib.comptime)

(defmacro (reflection-score [T : type]) : i64
  (match (type-info T)
    [(comptime.TypeInfo.Struct _ _) (comptime.expr-int 10)]
    [_ (comptime.expr-int 0)]))

(defmacro (emit-ordinary-delta) : Decls
  `(defstruct OrdinaryDelta
    (value i64)))

(emit-ordinary-delta)

(define (ordinary-delta-read [item : OrdinaryDelta]) : i64
  item.value)

(define ordinary-delta-score : i64
  (+ (reflection-score OrdinaryDelta) (ordinary-delta-read (OrdinaryDelta 0))))

(defmacro (emit-module-delta) : Module
  `(begin
    (module generated.ctfe_module_delta)
    (defstruct ModuleDelta
      (value i64))))

(import (emit-module-delta) as module_delta)

(define (module-delta-read [item : module_delta.ModuleDelta]) : i64
  item.value)

(define module-delta-score : i64
  (+
    (reflection-score module_delta.ModuleDelta)
    (module-delta-read (module_delta.ModuleDelta 0))))

(defmacro (emit-file-delta) : Module
  `(begin
    (module generated.ctfe_file_delta)
    (import compile_profile_ctfe_splice_delta_dep as dep)
    (define (file-read [item : dep.FileDelta]) : i64
      item.value)
    (define (file-score) : i64
      (+ (reflection-score dep.FileDelta) (file-read (dep.FileDelta 0))))))

(import (emit-file-delta) as file_delta)

(define file-delta-score : i64
  (file_delta.file-score))

;; This ordinary Decls splice precedes the checked-in module at the end of the
;; file. Its canonical key is fresh, while the unqualified Collision alias must
;; still preserve first-visible source order on the additive path.
(defmacro (emit-collision-delta) : Decls
  `(begin
    (module generated.ctfe_collision_delta)
    (defstruct Collision
      (other i64))
    (define collision-delta-score : i64
      (reflection-score Collision))))

(define (main) : i64
  (+ 12 (+ ordinary-delta-score (+ module-delta-score file-delta-score))))

(emit-collision-delta)

(module source.ctfe_collision_tail)

(defstruct Collision
  (value i64))