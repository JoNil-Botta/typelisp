;; The typechecker's aggregate caches clear in proportion to what a program
;; cached (#8520). Each clear must leave the table exactly as a full clear
;; does: after logged fills, after its log overflowed, and on a fresh table.
(import compiler_typecheck_core as tc_core)
(import stdlib.arena)
(import stdlib.test)

(define (scalar-table-empty? [slots : (& slots (__tl_dyn-array i64))]) : bool
  (let
    [empty : bool (= (array-ref slots tc_core.tc-agg-scalar-cache-capacity) 0)]
    [index : i64 0]
    (while (and empty (< index tc_core.tc-agg-scalar-cache-capacity))
      (unless (= (array-ref slots index) 0) (set! empty false))
      (set! index (+ index 1)))
    empty))

;; Fill COUNT keys from FIRST in steps of STRIDE, as the cached queries do.
(define (scalar-fill!
  [slots : (&mut slots (__tl_dyn-array i64))]
  [first : i64]
  [count : i64]
  [stride : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (let
        [key : i64
          (% (+ first (* index stride)) tc_core.tc-agg-scalar-cache-capacity)]
        (set! (array-ref slots key) (+ index 1))
        (tc_core.tc-agg-scalar-cache-note-filled! slots key))
      (set! index (+ index 1)))))

(test
  tc-agg-scalar-cache-logged-clear
  (let
    [slots : (__tl_dyn-array i64) (tc_core.tc-agg-scalar-cache-new)]
    [last : i64 (- tc_core.tc-agg-scalar-cache-capacity 1)]
    ;; A fresh array's contents are unknown, so its first clear is full.
    (set! (array-ref slots 7) 3)
    (set! (array-ref slots last) 5)
    (tc_core.tc-agg-scalar-cache-clear! (&mut slots))
    (test.assert-true
      (scalar-table-empty? (& slots))
      "a fresh scalar cache clears in full")
    (scalar-fill! (&mut slots) 0 300 1337)
    (scalar-fill! (&mut slots) last 1 1)
    (tc_core.tc-agg-scalar-cache-clear! (&mut slots))
    (test.assert-true
      (scalar-table-empty? (& slots))
      "a logged clear empties every filled scalar slot")
    (scalar-fill!
      (&mut slots)
      11
      (+ tc_core.tc-agg-scalar-cache-log-capacity 10)
      7)
    (tc_core.tc-agg-scalar-cache-clear! (&mut slots))
    (test.assert-true
      (scalar-table-empty? (& slots))
      "an overflowed scalar log clears in full")))

(define (layout-table-empty? [state : tc_core.TcAggLayoutCacheState]) : bool
  (let
    [slots : (__tl_dyn-array tc_core.TcAggLayoutCacheSlot)
      (tc_core.tc-agg-layout-cache-slots state)]
    [empty : bool (= (array-length slots) tc_core.tc-agg-layout-cache-capacity)]
    [index : i64 0]
    (while (and empty (< index (array-length slots)))
      (match (tc_core.tc-global-array-element-shared-view slots index)
        [(Empty) unit]
        [(Full _ _) (set! empty false)])
      (set! index (+ index 1)))
    empty))

(define (small-layout) : tc_core.TcInlineAggregateLayout
  (tc_core.TcInlineAggregateLayout.Struct
    8
    8
    (tc_core.TcInlineFieldLayoutList
      (__tl_make-array tc_core.TcInlineFieldLayout 0))))

;; Store COUNT layouts from slot FIRST in steps of STRIDE.
(define (layout-store-many!
  [state : tc_core.TcAggLayoutCacheState]
  [first : i64]
  [count : i64]
  [stride : i64]) : unit
  (let
    [index : i64 0]
    (while (< index count)
      (tc_core.tc-agg-layout-cache-store-for-state!
        state
        (bit-and
          (+ first (* index stride))
          (- tc_core.tc-agg-layout-cache-capacity 1))
        (+ index 1)
        (small-layout))
      (set! index (+ index 1)))))

(test
  tc-agg-layout-cache-logged-reset
  (let
    [owner : arena.Arena (arena.make)]
    [job-address : i64
      (in-arena owner (__tl-project-field (tc_core.tc-job-state-new) address))]
    [state : tc_core.TcAggLayoutCacheState
      (tc_core.tc-job-state-agg-layout-cache (tc_core.TcJobState job-address))]
    (tc_core.tc-agg-layout-cache-table-storage-ensure-for-state! state)
    ;; A fresh table holds no valid slots, so its first reset is full.
    (tc_core.tc-agg-layout-cache-storage-reset-for-state! state)
    (test.assert-true
      (layout-table-empty? state)
      "a fresh layout cache resets in full")
    (layout-store-many! state 0 300 1337)
    (layout-store-many! state (- tc_core.tc-agg-layout-cache-capacity 1) 1 1)
    (tc_core.tc-agg-layout-cache-storage-reset-for-state! state)
    (test.assert-true
      (layout-table-empty? state)
      "a logged reset empties every filled layout slot")
    (layout-store-many!
      state
      5
      (+ tc_core.tc-agg-layout-cache-log-capacity 10)
      3)
    (tc_core.tc-agg-layout-cache-storage-reset-for-state! state)
    (test.assert-true
      (layout-table-empty? state)
      "an overflowed layout log resets in full")))