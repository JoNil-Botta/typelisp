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
  ;; Nonnegative frame, -1 inactive, or -2-body for a checked acyclic scope.
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

(define (storage-exposure-box [state : StorageExposure]) : (Box
    StorageExposureData)
  ;; The handle is the Box word created by storage-exposure-new. Its owner
  ;; remains the checker arena; this local view never escapes an operation.
  (unsafe
    (ptr-read
      (ptr-cast (ptr-addr-of state.address) : (Ptr (Box StorageExposureData))))))

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
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    (__tl-project-set-field
      (__tl-box-place data)
      frames
      (storage-exposure-empty-words))
    (__tl-project-set-field
      (__tl-box-place data)
      bindings
      (storage-exposure-empty-words))
    (__tl-project-set-field
      (__tl-box-place data)
      generation
      (storage-exposure-fresh-generation))
    (__tl-project-set-field
      (__tl-box-place data)
      by-body
      (index_map.with-capacity 0))
    (__tl-project-set-field
      (__tl-box-place data)
      by-hash
      (index_map.with-capacity 0))
    (__tl-project-set-field (__tl-box-place data) current -1)
    (__tl-project-set-field (__tl-box-place data) suspension-depth 0)
    (__tl-project-set-field
      (__tl-box-place data)
      arena
      (arena.tl_arena_current))))

(define (storage-exposure-current [state : StorageExposure]) : i64
  (deref (storage-exposure-box state)).current)

(defstruct StorageExposureSuspension
  (frame i64)
  (generation i64))

(define (storage-exposure-suspend! [state : StorageExposure]) : StorageExposureSuspension
  (let
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    [token : StorageExposureSuspension
      (StorageExposureSuspension
        (__tl-project-field (__tl-box-place data) current)
        (__tl-project-field (__tl-box-place data) generation))]
    (__tl-project-set-field (__tl-box-place data) current -1)
    (__tl-project-set-field
      (__tl-box-place data)
      suspension-depth
      (+ (__tl-project-field (__tl-box-place data) suspension-depth) 1))
    token))

(define (storage-exposure-resume!
  [state : StorageExposure]
  [token : StorageExposureSuspension]) : unit
  (let
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    ;; A retired generation cannot restore one of its frame indices.
    (when
      (and
        (>= token.generation 0)
        (=
          token.generation
          (__tl-project-field (__tl-box-place data) generation))
        (> (__tl-project-field (__tl-box-place data) suspension-depth) 0))
      (__tl-project-set-field
        (__tl-box-place data)
        suspension-depth
        (- (__tl-project-field (__tl-box-place data) suspension-depth) 1))
      (__tl-project-set-field (__tl-box-place data) current token.frame))))

(define (storage-exposure-acyclic-body [state : StorageExposure]) : i64
  (let
    [current : i64 (storage-exposure-current state)]
    (if (<= current -2)
      (- 0 (+ current 2))
      -1)))

(define (storage-exposure-frame-field
  [state : StorageExposure]
  [frame : i64]
  [field : i64]) : i64
  (array-ref
    (deref (storage-exposure-box state)).frames.slots
    (+ (* frame 6) field)))

(define (storage-exposure-binding-field
  [state : StorageExposure]
  [binding : i64]
  [field : i64]) : i64
  (array-ref
    (deref (storage-exposure-box state)).bindings.slots
    (+ (* binding 6) field)))

(define (storage-exposure-frame
  [state : StorageExposure]
  [declaration : i64]
  [body : i64]) : i64
  (let
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    [frame : i64
      (index_map.get-value-or
        (& (__tl-project-field (__tl-box-place data) by-body))
        body
        -1)]
    (while (>= frame 0)
      (when
        (= (storage-exposure-frame-field state frame 0) declaration)
        (return frame))
      (set! frame (storage-exposure-frame-field state frame 3)))
    -1))

(define (storage-exposure-enter!
  [state : StorageExposure]
  [declaration : i64]
  [body : i64]
  [acyclic? : bool]) : i64
  (let
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    [previous : i64 (__tl-project-field (__tl-box-place data) current)]
    (when
      (or
        (> (__tl-project-field (__tl-box-place data) suspension-depth) 0)
        (< (__tl-project-field (__tl-box-place data) generation) 0))
      (return previous))
    (when
      (and acyclic? (>= body 0) (<= body 9223372036854775805))
      (__tl-project-set-field (__tl-box-place data) current (- -2 body))
      (return previous))
    (let
      [frame : i64
        (if (>= body 0)
          (storage-exposure-frame state declaration body)
          -1)]
      (when
        (and (>= body 0) (< frame 0))
        (set! frame (/ (__tl-project-field (__tl-box-place data) frames).len 6))
        (in-arena
          (arena.Arena (__tl-project-field (__tl-box-place data) arena))
          (let
            [next : i64
              (index_map.get-value-or
                (& (__tl-project-field (__tl-box-place data) by-body))
                body
                -1)]
            (for [word (array declaration body -1 next 1 0)]
              (words.push-ref!
                (&mut (__tl-project-field (__tl-box-place data) frames))
                word))
            (index_map.insert-ref!
              (&mut (__tl-project-field (__tl-box-place data) by-body))
              body
              frame))))
      (__tl-project-set-field (__tl-box-place data) current frame)
      (when
        (>= frame 0)
        (set!
          (array-ref
            (__tl-project-field (__tl-box-place data) frames).slots
            (+ (* frame 6) 5))
          0)))
    previous))

(define (storage-exposure-incomplete! [state : StorageExposure]) : unit
  (let
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    [frame : i64 (__tl-project-field (__tl-box-place data) current)]
    (when
      (>= frame 0)
      (set!
        (array-ref
          (__tl-project-field (__tl-box-place data) frames).slots
          (+ (* frame 6) 4))
        0))))

(define (storage-exposure-invalidate-body!
  [state : StorageExposure]
  [body : i64]) : unit
  (let
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    [frame : i64
      (index_map.get-value-or
        (& (__tl-project-field (__tl-box-place data) by-body))
        body
        -1)]
    (while (>= frame 0)
      (set!
        (array-ref
          (__tl-project-field (__tl-box-place data) frames).slots
          (+ (* frame 6) 4))
        0)
      (set! frame (storage-exposure-frame-field state frame 3)))))

(define (storage-exposure-leave!
  [state : StorageExposure]
  [previous : i64]
  [success : bool]) : unit
  (let
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    [frame : i64 (__tl-project-field (__tl-box-place data) current)]
    (unless success (storage-exposure-incomplete! state))
    (when
      (>= frame 0)
      (set!
        (array-ref
          (__tl-project-field (__tl-box-place data) frames).slots
          (+ (* frame 6) 5))
        1))
    (__tl-project-set-field (__tl-box-place data) current previous)))

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
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    [index : i64
      (index_map.get-value-or
        (& (__tl-project-field (__tl-box-place data) by-hash))
        hash
        -1)]
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
    [data : (Box StorageExposureData) (storage-exposure-box state)]
    [frame : i64 (__tl-project-field (__tl-box-place data) current)]
    [index : i64
      (if (>= frame 0)
        (storage-exposure-find state frame kind scope name hash)
        -1)]
    (when
      (and (>= frame 0) (< index 0))
      (set! index (/ (__tl-project-field (__tl-box-place data) bindings).len 6))
      (in-arena
        (arena.Arena (__tl-project-field (__tl-box-place data) arena))
        (let
          [next-hash : i64
            (index_map.get-value-or
              (& (__tl-project-field (__tl-box-place data) by-hash))
              hash
              -1)]
          [next-frame : i64 (storage-exposure-frame-field state frame 2)]
          (for [word (array frame kind scope name next-hash next-frame)]
            (words.push-ref!
              (&mut (__tl-project-field (__tl-box-place data) bindings))
              word))
          (index_map.insert-ref!
            (&mut (__tl-project-field (__tl-box-place data) by-hash))
            hash
            index)
          (set!
            (array-ref
              (__tl-project-field (__tl-box-place data) frames).slots
              (+ (* frame 6) 2))
            index))))))

(define (storage-exposure-generation [state : StorageExposure]) : i64
  (deref (storage-exposure-box state)).generation)

(define (storage-exposure-key
  [frame : i64]
  [kind : i64]
  [scope : i64]
  [name : i64]) : i64
  ;; This is a bucket hint; lookup compares every full-width field.
  (bit-xor (bit-xor (* frame 16777619) (* scope 131)) (bit-xor kind name)))