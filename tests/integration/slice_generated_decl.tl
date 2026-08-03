;; Generated declarations may carry a borrowed Slice in their signatures when
;; the module macro's type parameter is constrained by the stable slice kind.
(import stdlib.comptime)

(defmacro (slice-generated [S : type (:kind slice)]) : Module
  (let
    [module-name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "generated.slice." (type-key S)))]
    (match (type-info S)
      [(comptime.TypeInfo.Slice _)
        `(begin
          (module ,module-name)
          (define (identity [view : (& fixed ,S)]) : (& fixed ,S)
            view)
          (define (observe [view : (& fixed ,S)]) : i64
            (+ (array-length view) (array-ref view 0))))]
      [_
        `(begin
          (module ,module-name)
          (define (identity [view : (& fixed ,S)]) : (& fixed ,S)
            view)
          (define (observe [view : (& fixed ,S)]) : i64
            0))])))

(import (slice-generated (Slice i64)) as generated)

(define (main) : i64
  (let
    [fixed : (Array i64 4) (array 38 1 2 3)]
    [view : (& fixed (Slice i64)) (generated.identity (& fixed))]
    (generated.observe view)))