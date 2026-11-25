;; A struct or enum whose field type is written through an import alias, of a
;; generated module (`opt.Option`, `svec.Vec`) or an ordinary one
;; (`provider.Tagged`), can be the element of a full-mode generated vector
;; (#8474). `contains?` calls the element's owner `eq-<kebab-name>` hook, which
;; lives in the module that declared the field, so the alias resolves there and
;; is never reflected by a generated equality module. The generated Option
;; family has no equality hook, so its holders write theirs by hand; `Fields`
;; holds a generated vector, whose `eq-vec` lets `(eq.gen Fields)` compare it.
;; Exits 42, or the number of the failed check.
(import stdlib.clone)
(import stdlib.eq)
(import stdlib.vector)
(import stdlib.option)
(import (option.option i64) as opt)
(import (vector.vector String) as svec)
(import vector_alias_field_provider as provider)

;; Hand-written equality of the generated Option family.
(define (option-eq [left : (& left opt.Option)] [right : (& right opt.Option)]) : bool
  (match left
    [(opt.Option.Some l)
      (match right
        [(opt.Option.Some r) (= l r)]
        [opt.Option.None false])]
    [opt.Option.None (opt.is-none? right)]))

;; The alias is the whole field type.
(defstruct Row
  (tag opt.Option)
  (n i64))

(define (eq-row [left : (& left Row)] [right : (& right Row)]) : bool
  (and (option-eq (& left.tag) (& right.tag)) (= left.n right.n)))

;; The alias inside a tuple field.
(defstruct Pair
  (both (Tuple opt.Option i64)))

(define (eq-pair [left : (& left Pair)] [right : (& right Pair)]) : bool
  (and
    (option-eq (& (tuple-ref left.both 0)) (& (tuple-ref right.both 0)))
    (= (tuple-ref left.both 1) (tuple-ref right.both 1))))

;; The alias as an enum payload.
(defenum Cell
  (Missing)
  (Held opt.Option))

(define (eq-cell [left : (& left Cell)] [right : (& right Cell)]) : bool
  (match left
    [(Held l)
      (match right
        [(Held r) (option-eq (& l) (& r))]
        [Missing false])]
    [Missing
      (match right
        [(Held _) false]
        [Missing true])]))

;; A field typed through an ordinary module alias; its equality dispatches to
;; the provider's owner hook.
(defstruct Wrap
  (inner provider.Tagged)
  (k i64))

(eq.gen Wrap)

;; A vector-valued field compares through the generated vector's `eq-vec`.
(defstruct Fields
  (items svec.Vec))

(clone.gen-clone Fields)

(eq.gen Fields)

(import (vector.vector Row) as row-vec)
(import (vector.vector Pair) as pair-vec)
(import (vector.vector Cell) as cell-vec)
(import (vector.vector provider.Tagged) as tagged-vec)
(import (vector.vector Wrap) as wrap-vec)
(import (vector.vector Fields) as fields-vec)

(define (rows-ok?) : bool
  (let
    [rows : row-vec.Vec (row-vec.new)]
    (row-vec.push! rows (Row (opt.some 3) 1))
    (row-vec.push! rows (Row (opt.none) 2))
    (and
      (row-vec.contains? (& rows) (& (Row (opt.some 3) 1)))
      (row-vec.contains? (& rows) (& (Row (opt.none) 2)))
      (not (row-vec.contains? (& rows) (& (Row (opt.some 4) 1))))
      (not (row-vec.contains? (& rows) (& (Row (opt.none) 1)))))))

(define (pairs-ok?) : bool
  (let
    [pairs : pair-vec.Vec (pair-vec.new)]
    (pair-vec.push! pairs (Pair (tuple (opt.some 7) 8)))
    (and
      (pair-vec.contains? (& pairs) (& (Pair (tuple (opt.some 7) 8))))
      (not (pair-vec.contains? (& pairs) (& (Pair (tuple (opt.none) 8))))))))

(define (cells-ok?) : bool
  (let
    [cells : cell-vec.Vec (cell-vec.new)]
    (cell-vec.push! cells (Cell.Held (opt.some 5)))
    (and
      (cell-vec.contains? (& cells) (& (Cell.Held (opt.some 5))))
      (not (cell-vec.contains? (& cells) (& (Cell.Held (opt.some 6)))))
      (not (cell-vec.contains? (& cells) (& (Cell.Missing)))))))

(define (tagged-ok?) : bool
  (let
    [items : tagged-vec.Vec (tagged-vec.new)]
    (tagged-vec.push! items (provider.tagged 9 1))
    (and
      (tagged-vec.contains? (& items) (& (provider.tagged 9 1)))
      (not (tagged-vec.contains? (& items) (& (provider.untagged 1)))))))

(define (wraps-ok?) : bool
  (let
    [items : wrap-vec.Vec (wrap-vec.new)]
    (wrap-vec.push! items (Wrap (provider.tagged 2 3) 4))
    (and
      (wrap-vec.contains? (& items) (& (Wrap (provider.tagged 2 3) 4)))
      (not (wrap-vec.contains? (& items) (& (Wrap (provider.untagged 3) 4)))))))

(define (fields-ok?) : bool
  (let
    [rows : fields-vec.Vec (fields-vec.new)]
    [items : svec.Vec (svec.new)]
    [same : svec.Vec (svec.new)]
    [other : svec.Vec (svec.new)]
    (svec.push! items "a")
    (svec.push! items "b")
    (svec.push! same "a")
    (svec.push! same "b")
    (svec.push! other "a")
    (let
      [count : i64 (svec.len (& items))]
      [probe : Fields (Fields same)]
      [missing : Fields (Fields other)]
      (fields-vec.push! rows (Fields items))
      (and
        (= count 2)
        (= (fields-vec.len (& rows)) 1)
        (fields-vec.contains? (& rows) (& probe))
        (not (fields-vec.contains? (& rows) (& missing)))))))

(define (main) : i64
  (cond
    [(not (rows-ok?)) 1]
    [(not (pairs-ok?)) 2]
    [(not (cells-ok?)) 3]
    [(not (tagged-ok?)) 4]
    [(not (wraps-ok?)) 5]
    [(not (fields-ok?)) 6]
    [else 42]))