; sym_i64_env module - Persistent scoped interned-symbol -> i64 table.
; Bindings live in a per-environment append-only arena and refer to their
; parent by index. Snapshots share dense storage but retain independent heads,
; so binding a child cannot change the parent view.
(import stdlib.option)
(import (option.option i64) as option_i64)
(import stdlib.arena)

(defstruct SymI64Binding
  (key i64)
  (value i64)
  (parent i64))

; A child may be appended while a shorter-lived scratch arena is active.
; Retaining the store's allocation arena keeps growth from making an older
; snapshot point into that scratch arena.
(defstruct SymI64Store
  (slots (__tl_dyn-array SymI64Binding))
  (len i64)
  (arena i64))

(defenum SymI64Env
  (SymI64Nil)
  (SymI64Dense (Box SymI64Store) i64))

(defenum SymI64View
  (SymI64ViewNil)
  (SymI64ViewBind i64 i64 SymI64Env))

(define (sym-i64-store-new) : SymI64Store
  (let
    [slots : (__tl_dyn-array SymI64Binding) (__tl_make-array SymI64Binding 8)]
    [owner : i64 (arena.tl_arena_current)]
    (SymI64Store slots 0 owner)))

(define (sym-i64-store-copy-range
  [dst : (&mut dst (__tl_dyn-array SymI64Binding))]
  [src : (& src (__tl_dyn-array SymI64Binding))]
  [index : i64]
  [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (set! (array-ref dst index) (array-ref src index))
      (sym-i64-store-copy-range dst src (+ index 1) count))))

(define (sym-i64-store-grow! [store : (&mut store SymI64Store)]) : unit
  (let
    [len : i64 store.len]
    [capacity : i64 (array-length store.slots)]
    [owner : i64 store.arena]
    (in-arena
      (arena.Arena owner)
      (let
        [bigger : (__tl_dyn-array SymI64Binding)
          (__tl_make-array
            SymI64Binding
            (if (< capacity 1)
              8
              (* capacity 2)))]
        (begin
          (sym-i64-store-copy-range (&mut bigger) (& store.slots) 0 len)
          (set! store.slots bigger))))))

(define (sym-i64-store-push!
  [store : (&mut store SymI64Store)]
  [binding : SymI64Binding]) : i64
  (begin
    (if (< store.len (array-length store.slots))
      unit
      (sym-i64-store-grow! store))
    (let
      [index : i64 store.len]
      (begin
        (set! (array-ref store.slots index) binding)
        (set! store.len (+ index 1))
        index))))

(define (sym-i64-empty) : SymI64Env
  SymI64Nil)

(define (sym-i64-bind-id [e : SymI64Env] [k : i64] [v : i64]) : SymI64Env
  (match e
    [(SymI64Nil)
      (let
        [store : (Box SymI64Store) (box (sym-i64-store-new))]
        [head : i64
          (sym-i64-store-push!
            (&mut (__tl-box-place store))
            (SymI64Binding k v -1))]
        (SymI64Dense store head))]
    [(SymI64Dense store parent)
      (let
        [head : i64
          (sym-i64-store-push!
            (&mut (__tl-box-place store))
            (SymI64Binding k v parent))]
        (SymI64Dense store head))]))

(define (sym-i64-view [e : SymI64Env]) : SymI64View
  (match e
    [(SymI64Nil) SymI64ViewNil]
    [(SymI64Dense store head)
      (let
        [slots : (__tl_dyn-array SymI64Binding)
          (__tl-project-field (__tl-box-place store) slots)]
        ; Heads and parent indices are returned only by sym-i64-store-push!.
        [binding : SymI64Binding
          (unsafe
            (ptr-read (ptr-offset (array-data slots) head)))]
        (SymI64ViewBind
          binding.key
          binding.value
          (let
            [parent : i64 binding.parent]
            (if (< parent 0)
              SymI64Nil
              (SymI64Dense store parent)))))]))

; Store mutation checks every appended index against array capacity. Lookups
; then follow only those stored head/parent indices, so their raw reads retain
; the same bounds invariant without paying a dynamic check on every parent hop.
(define (sym-i64-lookup-id [e : SymI64Env] [k : i64]) : option_i64.Option
  (match e
    [(SymI64Nil) option_i64.None]
    [(SymI64Dense store head)
      (let
        [cursor : i64 head]
        [slots : (__tl_dyn-array SymI64Binding)
          (__tl-project-field (__tl-box-place store) slots)]
        [bindings : (Ptr SymI64Binding)
          (unsafe
            (ptr-cast (array-data slots) : (Ptr SymI64Binding)))]
        (begin
          (while (>= cursor 0)
            (let
              [binding : SymI64Binding
                (unsafe
                  (ptr-read (ptr-offset bindings cursor)))]
              (if (= binding.key k)
                (return (option_i64.Some binding.value))
                (set! cursor binding.parent))))
          option_i64.None))]))

(define (sym-i64-lookup-id-or [e : SymI64Env] [k : i64] [fallback : i64]) : i64
  (match e
    [(SymI64Nil) fallback]
    [(SymI64Dense store head)
      (let
        [cursor : i64 head]
        [slots : (__tl_dyn-array SymI64Binding)
          (__tl-project-field (__tl-box-place store) slots)]
        [bindings : (Ptr SymI64Binding)
          (unsafe
            (ptr-cast (array-data slots) : (Ptr SymI64Binding)))]
        (begin
          (while (>= cursor 0)
            (let
              [binding : SymI64Binding
                (unsafe
                  (ptr-read (ptr-offset bindings cursor)))]
              (if (= binding.key k)
                (return binding.value)
                (set! cursor binding.parent))))
          fallback))]))

(define (sym-i64-contains-id [e : SymI64Env] [k : i64]) : bool
  (match e
    [(SymI64Nil) false]
    [(SymI64Dense store head)
      (let
        [cursor : i64 head]
        [slots : (__tl_dyn-array SymI64Binding)
          (__tl-project-field (__tl-box-place store) slots)]
        [bindings : (Ptr SymI64Binding)
          (unsafe
            (ptr-cast (array-data slots) : (Ptr SymI64Binding)))]
        (begin
          (while (>= cursor 0)
            (let
              [binding : SymI64Binding
                (unsafe
                  (ptr-read (ptr-offset bindings cursor)))]
              (if (= binding.key k)
                (return true)
                (set! cursor binding.parent))))
          false))]))