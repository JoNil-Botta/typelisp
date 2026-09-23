(module foreign_global_dep)

;; Globals that importers may read but only this module may write (#7976).
(defstruct ForeignPair
  (left i64)
  (right i64))

(define counter : i64
  1)
(define pair : ForeignPair
  (ForeignPair 1 2))
(define slots : (Array i64 4)
  (make-array i64 4))
(define boxed : (Box i64)
  (box 5))
(define tup : (Tuple i64 i64)
  (tuple 1 2))

(define (set-counter! [value : i64]) : unit
  (set! counter value))

;; Expanded in an importer, this write is checked as the importer's code.
(defmacro (foreign-global-bump!) : Expr
  `(set! counter 77))

;; Expanded in an importer, calling this module's writer stays valid.
(defmacro (foreign-global-bump-via-writer! [value : Expr]) : Expr
  `(set-counter! ,value))

;; A place the caller passes in carries no authority from this module.
(defmacro (foreign-global-assign! [place : Expr] [value : Expr]) : Expr
  `(set! ,place ,value))

;; Expanded here, the same macros write this module's own globals.
(define (bump-inside-owner!) : i64
  (begin
    (foreign-global-bump!)
    (foreign-global-assign! pair.right 40)
    counter))