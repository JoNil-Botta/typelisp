;; Checked lexical storage facts. Handles and numeric source keys belong to
;; one checker job; no expression/type payload survives function scratch here.
(import stdlib.arena)
(import stdlib.iterator)
(import stdlib.vector)
(import (vector.vector i64) as words)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as index_map)

(defstruct StorageExposureData
  ;; Frame: declaration, body, first binding, next same-body frame, complete,
  ;; ready. Binding: frame, kind, scope, name, exposed, next hash, next frame.
  (frames words.Vec)
  (bindings words.Vec)
  (by-body index_map.Map)
  (by-hash index_map.Map)
  (current i64)
  (base i64)
  (arena i64))

(defstruct StorageExposure
  (address u64))

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
          0
          (arena.tl_arena_current)))]
    (StorageExposure
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of cell) : (Ptr u64)))))))

(define (storage-exposure-reset! [state : StorageExposure]) : unit
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    (unsafe
      ;; IDs from a retired generation cannot select a new record at its index.
      (set!
        (deref data).base
        (+ (deref data).base (/ (deref data).bindings.len 7)))
      (set! (deref data).frames (storage-exposure-empty-words))
      (set! (deref data).bindings (storage-exposure-empty-words))
      (set! (deref data).by-body (index_map.with-capacity 0))
      (set! (deref data).by-hash (index_map.with-capacity 0))
      (set! (deref data).current -1)
      (set! (deref data).arena (arena.tl_arena_current)))))

(define (storage-exposure-current [state : StorageExposure]) : i64
  (unsafe
    (deref (storage-exposure-ptr state)).current))

(define (storage-exposure-current-swap! [state : StorageExposure] [next : i64]) : i64
  (let
    [previous : i64 (storage-exposure-current state)]
    (unsafe
      (set! (deref (storage-exposure-ptr state)).current next))
    previous))

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
      (+ (* binding 7) field))))

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

(define (storage-exposure-ready? [state : StorageExposure] [frame : i64]) : bool
  (and
    (>= frame 0)
    (= (storage-exposure-frame-field state frame 4) 1)
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
      (set! index (storage-exposure-binding-field state index 5)))
    -1))

(define (storage-exposure-bind!
  [state : StorageExposure]
  [kind : i64]
  [scope : i64]
  [name : i64]
  [hash : i64]) : i64
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
        (set! index (/ bindings.len 7))
        (in-arena
          (arena.Arena (deref data).arena)
          (let
            [next-hash : i64 (index_map.get-value-or (& by-hash) hash -1)]
            [next-frame : i64 (storage-exposure-frame-field state frame 2)]
            (for [word
              (array frame kind scope name (cast 0 : i64) next-hash next-frame)]
              (words.push-ref! (&mut bindings) word))
            (index_map.insert-ref! (&mut by-hash) hash index)
            (set! (array-ref (deref data).frames.slots (+ (* frame 6) 2)) index)))))
    (unsafe
      (set! (deref data).bindings bindings)
      (set! (deref data).by-hash by-hash))
    (if (>= index 0)
      (unsafe
        (+ (deref data).base index))
      -1)))

(define (storage-exposure-index [state : StorageExposure] [identity : i64]) : i64
  (let
    [data : (MutPtr StorageExposureData) (storage-exposure-ptr state)]
    [index : i64
      (unsafe
        (- identity (deref data).base))]
    (if (and
      (>= index 0)
      (unsafe
        (< index (/ (deref data).bindings.len 7))))
      index
      -1)))

(define (storage-exposure-mark! [state : StorageExposure] [identity : i64]) : unit
  (let
    [index : i64 (storage-exposure-index state identity)]
    (if (>= index 0)
      (unsafe
        (set!
          (array-ref
            (deref (storage-exposure-ptr state)).bindings.slots
            (+ (* index 7) 4))
          1))
      (storage-exposure-incomplete! state))))