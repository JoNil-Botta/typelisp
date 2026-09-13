(import stdlib.test)
(import global_field_owner_lib as imported)

(defstruct Leaf
  (value i64))

(defstruct Owner
  (leaf Leaf))

(define seed : i64
  40)
(define owner : Owner
  (Owner (Leaf (+ seed 2))))

(define (read-field) : i64
  owner.leaf.value)

(defmacro (field-type-code [place : Expr]) : i64
  (if (__tl_string_eq (type-kind (expr-type place)) "i64")
    (expr-int 42)
    (expr-int 0)))

(test
  nested-global-field-keeps-initializer-dependencies
  (test.assert-i64-eq (read-field) 42 "nested global initializer"))

(test
  imported-global-field-keeps-owner
  (let
    [snapshot : imported.ImportedOwner imported.imported-owner]
    (begin
      (test.assert-i64-eq snapshot.leaf.value 42 "aliased global owner")
      (test.assert-i64-eq
        (imported.read-imported-field)
        42
        "imported field helper"))))

(define macro-owner : Owner
  (Owner (Leaf 42)))

(defmacro (read-macro-owner) : Expr
  `macro-owner.leaf.value)

(test
  hygienic-global-field-keeps-owner
  (test.assert-i64-eq (read-macro-owner) 42 "hygienic global field"))

(test
  global-field-macro-type-query
  (test.assert-i64-eq (field-type-code owner.leaf.value) 42 "field type query"))

(define (main) : i64
  (read-field))