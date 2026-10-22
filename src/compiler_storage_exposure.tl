;; Checked lexical storage facts. Handles and numeric source keys belong to
;; one checker job; no expression/type payload survives function scratch here.
(import stdlib.arena)
(import stdlib.vector)
(import (vector.vector i64 core) as words)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as index_map)

(defstruct StorageExposureData
  ;; Frame: declaration, body, first binding, next same-body frame, complete,
  ;; ready. Exposure: frame, kind, scope, name, next hash, next frame.
  (frames words.Vec)
  (bindings words.Vec)
  (by-body index_map.Map)
  (by-hash index_map.Map)
  (current i64)
  (generation i64)
  (suspension-depth i64)
  (arena i64))

(defstruct StorageExposure
  (address u64))

;; Checker creation is serialized with the compiler's other mutable state.
;; A fresh stamp also distinguishes owners allocated at a recycled address.
(define storage-exposure-generation-serial : i64
  0)

(define (storage-exposure-generation-successor [serial : i64]) : i64
  (if (< serial 9223372036854775807)
    (+ serial 1)
    -1))

(define (storage-exposure-fresh-generation) : i64
  (let
    [next : i64
      (storage-exposure-generation-successor storage-exposure-generation-serial)]
    (when (>= next 0) (set! storage-exposure-generation-serial next))
    next))

(define (storage-exposure-ptr [state : StorageExposure]) : (MutPtr
    StorageExposureData)
  (unsafe
    (int->ptr state.address : (MutPtr StorageExposureData))))

(define (storage-exposure-empty-words) : words.Vec
  (words.Vec (__tl_make-array i64 0) 0))

(define (storage-exposure-new) : StorageExposure
  (let
    [cell : (Box StorageExposureData)
      (box
        (StorageExposureData
          (storage-exposure-empty-words)
          (storage-exposure-empty-words)
          (index_map.with-capacity 0)
          (index_map.with-capacity 0)
          -1
          (storage-exposure-fresh-generation)
          0
          (arena.tl_arena_current)))]
    (StorageExposure
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64)))))))

(define (storage-exposure-reset! [state : StorageExposure]) : unit
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    (unsafe
      (set! (deref data).frames (storage-exposure-empty-words))
      (set! (deref data).bindings (storage-exposure-empty-words))
      (set! (deref data).generation (storage-exposure-fresh-generation))
      (set! (deref data).by-body (index_map.with-capacity 0))
      (set! (deref data).by-hash (index_map.with-capacity 0))
      (set! (deref data).current -1)
      (set! (deref data).suspension-depth 0)
      (set! (deref data).arena (arena.tl_arena_current)))))

(define (storage-exposure-current [state : StorageExposure]) : i64
  (unsafe
    (deref (storage-exposure-ptr state)).current))

(defstruct StorageExposureSuspension
  (frame i64)
  (generation i64))

(define (storage-exposure-suspend! [state : StorageExposure]) : StorageExposureSuspension
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    [token : StorageExposureSuspension
      (unsafe
        (StorageExposureSuspension (deref data).current (deref data).generation))]
    (unsafe
      (set! (deref data).current -1)
      (set! (deref data).suspension-depth (+ (deref data).suspension-depth 1)))
    token))

(define (storage-exposure-resume!
  [state : StorageExposure]
  [token : StorageExposureSuspension]) : unit
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    ;; A retired generation cannot restore one of its frame indices.
    (unsafe
      (when
        (and
          (>= token.generation 0)
          (= token.generation (deref data).generation)
          (> (deref data).suspension-depth 0))
        (set! (deref data).suspension-depth (- (deref data).suspension-depth 1))
        (set! (deref data).current token.frame)))))

(define (storage-exposure-frame-field
  [state : StorageExposure]
  [frame : i64]
  [field : i64]) : i64
  (unsafe
    (array-ref
      (deref (storage-exposure-ptr state)).frames.slots
      (+ (* frame 6) field))))

(define (storage-exposure-binding-field
  [state : StorageExposure]
  [binding : i64]
  [field : i64]) : i64
  (unsafe
    (array-ref
      (deref (storage-exposure-ptr state)).bindings.slots
      (+ (* binding 6) field))))

(define (storage-exposure-frame
  [state : StorageExposure]
  [declaration : i64]
  [body : i64]) : i64
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    [by-body : index_map.Map
      (unsafe
        (deref data).by-body)]
    [frame : i64 (index_map.get-value-or (& by-body) body -1)]
    (while (>= frame 0)
      (when
        (= (storage-exposure-frame-field state frame 0) declaration)
        (return frame))
      (set! frame (storage-exposure-frame-field state frame 3)))
    -1))

(define (storage-exposure-enter!
  [state : StorageExposure]
  [declaration : i64]
  [body : i64]) : i64
  (when
    (unsafe
      (let
        [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
        (or (> (deref data).suspension-depth 0) (< (deref data).generation 0))))
    (return (storage-exposure-current state)))
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    [previous : i64
      (unsafe
        (deref data).current)]
    [frames : words.Vec
      (unsafe
        (deref data).frames)]
    [by-body : index_map.Map
      (unsafe
        (deref data).by-body)]
    [frame : i64
      (if (>= body 0)
        (storage-exposure-frame state declaration body)
        -1)]
    (when
      (and (>= body 0) (< frame 0))
      (unsafe
        (set! frame (/ frames.len 6))
        (in-arena
          (arena.Arena (deref data).arena)
          (let
            [next : i64 (index_map.get-value-or (& by-body) body -1)]
            (for [word (array declaration body -1 next 1 0)]
              (words.push-ref! (&mut frames) word))
            (index_map.insert-ref! (&mut by-body) body frame)))))
    (unsafe
      (set! (deref data).frames frames)
      (set! (deref data).by-body by-body)
      (set! (deref data).current frame)
      (when
        (>= frame 0)
        (set! (array-ref (deref data).frames.slots (+ (* frame 6) 5)) 0)))
    previous))

(define (storage-exposure-incomplete! [state : StorageExposure]) : unit
  (let
    [frame : i64 (storage-exposure-current state)]
    (when
      (>= frame 0)
      (unsafe
        (set!
          (array-ref
            (deref (storage-exposure-ptr state)).frames.slots
            (+ (* frame 6) 4))
          0)))))

(define (storage-exposure-leave!
  [state : StorageExposure]
  [previous : i64]
  [success : bool]) : unit
  (let
    [frame : i64 (storage-exposure-current state)]
    (unless success (storage-exposure-incomplete! state))
    (unsafe
      (when
        (>= frame 0)
        (set!
          (array-ref
            (deref (storage-exposure-ptr state)).frames.slots
            (+ (* frame 6) 5))
          1))
      (set! (deref (storage-exposure-ptr state)).current previous))))

(define (storage-exposure-complete? [state : StorageExposure] [frame : i64]) : bool
  (and (>= frame 0) (= (storage-exposure-frame-field state frame 4) 1)))

(define (storage-exposure-ready? [state : StorageExposure] [frame : i64]) : bool
  (and
    (storage-exposure-complete? state frame)
    (= (storage-exposure-frame-field state frame 5) 1)))

(define (storage-exposure-find
  [state : StorageExposure]
  [frame : i64]
  [kind : i64]
  [scope : i64]
  [name : i64]
  [hash : i64]) : i64
  (when (< frame 0) (return -1))
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    [by-hash : index_map.Map
      (unsafe
        (deref data).by-hash)]
    [index : i64 (index_map.get-value-or (& by-hash) hash -1)]
    (while (>= index 0)
      (when
        (and
          (= (storage-exposure-binding-field state index 0) frame)
          (= (storage-exposure-binding-field state index 1) kind)
          (= (storage-exposure-binding-field state index 2) scope)
          (= (storage-exposure-binding-field state index 3) name))
        (return index))
      (set! index (storage-exposure-binding-field state index 4)))
    -1))

(define (storage-exposure-record!
  [state : StorageExposure]
  [kind : i64]
  [scope : i64]
  [name : i64]
  [hash : i64]) : unit
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    [frame : i64 (storage-exposure-current state)]
    [bindings : words.Vec
      (unsafe
        (deref data).bindings)]
    [by-hash : index_map.Map
      (unsafe
        (deref data).by-hash)]
    [index : i64
      (if (>= frame 0)
        (storage-exposure-find state frame kind scope name hash)
        -1)]
    (when
      (and (>= frame 0) (< index 0))
      (unsafe
        (set! index (/ bindings.len 6))
        (in-arena
          (arena.Arena (deref data).arena)
          (let
            [next-hash : i64 (index_map.get-value-or (& by-hash) hash -1)]
            [next-frame : i64 (storage-exposure-frame-field state frame 2)]
            (for [word (array frame kind scope name next-hash next-frame)]
              (words.push-ref! (&mut bindings) word))
            (index_map.insert-ref! (&mut by-hash) hash index)
            (set! (array-ref (deref data).frames.slots (+ (* frame 6) 2)) index)))))
    (unsafe
      (set! (deref data).bindings bindings)
      (set! (deref data).by-hash by-hash))))

(define (storage-exposure-generation [state : StorageExposure]) : i64
  (unsafe
    (deref (storage-exposure-ptr state)).generation))

(define (storage-exposure-key
  [frame : i64]
  [kind : i64]
  [scope : i64]
  [name : i64]) : i64
  ;; This is a bucket hint; lookup compares every full-width field.
  (bit-xor (bit-xor (* frame 16777619) (* scope 131)) (bit-xor kind name)))