;; A generated nominal type can share its module with another generated macro.
;; Clone turns the reflected module-name String back into syntax; the native
;; callback must resolve it through the originating source-name session or the
;; helper lands under a distinct module identity with identical display text.
;; Refs #5262.
(defmacro (generated-clone-record [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.clone_record." (type-key T)))]
    `(begin
      (module ,module-name)
      (defstruct Record
        (value ,T))
      (defmacro (touch! [place : Expr]) : unit
        (expr-mut-call0 (expr-var "touch-ref!") place)))))

(import (generated-clone-record String) as generated)

(define (copy-record [value : generated.Record]) : generated.Record
  (clone value))

(define (main) : i64
  (let
    [value : generated.Record (generated.Record "42")]
    [copy : generated.Record (copy-record value)]
    (if (= (string-length (& copy.value)) 2)
      42
      1)))