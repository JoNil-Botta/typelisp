(module sealed_handle_dep)

;; Sealed handle types (#9783). Outside this module family only unsafe code may
;; construct them or mutate their fields; the rest of the corpus checks that.
(defstruct Storage
  (:opaque)
  (fd i64))

;; Sealed: a field holds a pointer to an opaque aggregate.
(defstruct Handle
  (storage (MutPtr Storage))
  (generation i64))

(unsafe
  (define (raw-close [fd : i64]) : unit
    unit))

(define (handle-close [handle : Handle]) : unit
  unit)

;; Sealed: a field names an unsafe cleanup hook.
(defstruct Hooked
  (:cleanup close-hooked)
  (fd i64 (:cleanup raw-close)))

;; Sealed: a field embeds the sealed Handle, here through a safe hook.
(defstruct Owner
  (:cleanup close-owner)
  (handle Handle (:cleanup handle-close)))

;; Not sealed: the field owns a sealed type through `(:owned)`.
(defstruct Wrapper
  (:cleanup close-wrapper)
  (owner Owner (:owned)))

(define (null-handle) : Handle
  (Handle (ptr-null : (MutPtr Storage)) 7))

(define (make-owner) : Owner
  (Owner (null-handle)))

(define (make-hooked [fd : i64]) : Hooked
  (Hooked fd))

;; Sealed: unsealed parts nested in a sealed handle are its storage too.
(defstruct Meta
  (gen i64))

(defstruct Nested
  (storage (MutPtr Storage))
  (meta Meta)
  (buf (Array i64 4))
  (pair (Tuple i64 i64)))

(define (null-nested) : Nested
  (Nested (ptr-null : (MutPtr Storage)) (Meta 0) (make-array i64 4) (tuple 0 0)))

;; Sealed: a payload names an unsafe cleanup hook.
(defenum Res
  (:cleanup close-res)
  (Open i64 (:cleanup raw-close))
  (Closed))

;; Sealed: a field holds a dynamic array. Growing or shrinking it writes the
;; handle's storage, so it takes the same admission as a field write.
(defstruct Vecs
  (storage (MutPtr Storage))
  (items (__tl_dyn-array i64)))

;; Not sealed on its own: the dynamic array is one field deeper.
(defstruct VecMeta
  (items (__tl_dyn-array i64)))

;; Sealed through `storage`; the dynamic array sits a field deeper.
(defstruct VecOwner
  (storage (MutPtr Storage))
  (meta VecMeta))

(define (null-vecs) : Vecs
  (Vecs (ptr-null : (MutPtr Storage)) (__tl_make-array i64 1)))

(define (null-vec-owner) : VecOwner
  (VecOwner (ptr-null : (MutPtr Storage)) (VecMeta (__tl_make-array i64 3))))