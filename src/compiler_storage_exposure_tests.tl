(import compiler_storage_exposure as exposure)
(import stdlib.iterator)
(import stdlib.test)

(test
  compiler-storage-exposure-lexical-keys
  (let
    [facts : exposure.StorageExposure (exposure.storage-exposure-new)]
    [previous : i64 (exposure.storage-exposure-enter! facts 3 9)]
    [frame : i64 (exposure.storage-exposure-current facts)]
    (for [name (array (cast 7 : i64) -9223372036854775808 9223372036854775807)]
      (for [scope (iterator.range 0 3)]
        (for [kind (iterator.range -1 3)]
          ;; Deliberately collide every key, including full-width names.
          (exposure.storage-exposure-record! facts kind scope name 0)
          (let
            [index : i64
              (exposure.storage-exposure-find facts frame kind scope name 0)]
            (test.assert-true (>= index 0) "exact key survives collisions")
            (exposure.storage-exposure-record! facts kind scope name 0)
            (test.assert-i64-eq
              (exposure.storage-exposure-find facts frame kind scope name 0)
              index
              "repeated exposure retains one record")))))
    (test.assert-i64-eq
      (exposure.storage-exposure-find facts frame 4 0 7 0)
      -1
      "different kind is unknown")
    (test.assert-i64-eq
      (exposure.storage-exposure-find facts frame 0 -1 7 0)
      -1
      "different scope is unknown")
    (test.assert-i64-eq
      (exposure.storage-exposure-find facts frame 0 0 8 0)
      -1
      "different name is unknown")
    (test.assert-true
      (not (exposure.storage-exposure-ready? facts frame))
      "in-progress body is unavailable")
    (exposure.storage-exposure-leave! facts previous true)
    (test.assert-true
      (exposure.storage-exposure-ready? facts frame)
      "completed body is available")
    (test.assert-i64-eq
      (exposure.storage-exposure-frame facts 4 9)
      -1
      "declarations sharing syntax stay distinct")))

(test
  compiler-storage-exposure-nested-and-incomplete
  (let
    [facts : exposure.StorageExposure (exposure.storage-exposure-new)]
    [outside : i64 (exposure.storage-exposure-enter! facts 3 9)]
    [outer-frame : i64 (exposure.storage-exposure-current facts)]
    [previous : i64 (exposure.storage-exposure-enter! facts 3 10)]
    [inner-frame : i64 (exposure.storage-exposure-current facts)]
    (exposure.storage-exposure-record! facts 0 -1 7 0)
    (exposure.storage-exposure-leave! facts previous true)
    (test.assert-i64-eq
      (exposure.storage-exposure-current facts)
      outer-frame
      "nested exit restores enclosing frame")
    (test.assert-i64-eq
      (exposure.storage-exposure-find facts outer-frame 0 -1 7 0)
      -1
      "nested exposure leaves enclosing slot private")
    (test.assert-true
      (>= (exposure.storage-exposure-find facts inner-frame 0 -1 7 0) 0)
      "capture owns a separate exposed slot")
    (test.assert-true
      (exposure.storage-exposure-ready? facts inner-frame)
      "nested frame completes independently")
    (exposure.storage-exposure-incomplete! facts)
    (exposure.storage-exposure-leave! facts outside true)
    (test.assert-true
      (not (exposure.storage-exposure-ready? facts outer-frame))
      "missing evidence cannot prove privacy")
    (let
      [previous : i64 (exposure.storage-exposure-enter! facts 3 9)]
      (exposure.storage-exposure-leave! facts previous true)
      (test.assert-true
        (not (exposure.storage-exposure-ready? facts outer-frame))
        "repeated checking cannot erase incomplete evidence"))
    (let
      [previous : i64 (exposure.storage-exposure-enter! facts 4 9)]
      [failed : i64 (exposure.storage-exposure-current facts)]
      (exposure.storage-exposure-leave! facts previous false)
      (test.assert-true
        (not (exposure.storage-exposure-ready? facts failed))
        "failed check stays conservative"))
    (let
      [previous : i64 (exposure.storage-exposure-enter! facts 3 -1)]
      (test.assert-i64-eq
        (exposure.storage-exposure-current facts)
        -1
        "synthetic body is unavailable")
      (test.assert-i64-eq
        (exposure.storage-exposure-find facts -1 0 0 0 0)
        -1
        "missing frame has no binding facts")
      (exposure.storage-exposure-leave! facts previous true))))

(test
  compiler-storage-exposure-frame-links-and-generations
  (let
    [facts : exposure.StorageExposure (exposure.storage-exposure-new)]
    [generation : i64 (exposure.storage-exposure-generation facts)]
    [previous : i64 (exposure.storage-exposure-enter! facts 1 2)]
    [outer-frame : i64 (exposure.storage-exposure-current facts)]
    [_outer : unit (exposure.storage-exposure-record! facts 0 5 7 0)]
    [outer-binding : i64
      (exposure.storage-exposure-find facts outer-frame 0 5 7 0)]
    (let
      [outer : i64 (exposure.storage-exposure-enter! facts 1 3)]
      [inner-frame : i64 (exposure.storage-exposure-current facts)]
      [_inner : unit (exposure.storage-exposure-record! facts 0 5 8 0)]
      [inner-binding : i64
        (exposure.storage-exposure-find facts inner-frame 0 5 8 0)]
      (test.assert-i64-eq
        (exposure.storage-exposure-frame-field facts outer-frame 2)
        outer-binding
        "outer frame keeps its own exposure list")
      (test.assert-i64-eq
        (exposure.storage-exposure-frame-field facts inner-frame 2)
        inner-binding
        "nested frame keeps its own exposure list")
      (test.assert-i64-eq
        (exposure.storage-exposure-binding-field facts inner-binding 5)
        -1
        "frame links do not cross a function boundary")
      (exposure.storage-exposure-leave! facts outer true))
    (exposure.storage-exposure-leave! facts previous true)
    (exposure.storage-exposure-reset! facts)
    (test.assert-true
      (!= (exposure.storage-exposure-generation facts) generation)
      "reset changes generation")
    (let
      [empty-generation : i64 (exposure.storage-exposure-generation facts)]
      (exposure.storage-exposure-reset! facts)
      (test.assert-true
        (!= (exposure.storage-exposure-generation facts) empty-generation)
        "an empty set also advances the generation"))
    (test.assert-i64-eq
      (exposure.storage-exposure-frame facts 1 2)
      -1
      "reset retires frame owners")))

(test
  compiler-storage-exposure-suspends-nested-queries
  (let
    [facts : exposure.StorageExposure (exposure.storage-exposure-new)]
    [previous : i64 (exposure.storage-exposure-enter! facts 1 2)]
    [frame : i64 (exposure.storage-exposure-current facts)]
    [outer : exposure.StorageExposureSuspension
      (exposure.storage-exposure-suspend! facts)]
    [_entry : i64 (exposure.storage-exposure-enter! facts 1 3)]
    [inner : exposure.StorageExposureSuspension
      (exposure.storage-exposure-suspend! facts)]
    [_nested : i64 (exposure.storage-exposure-enter! facts 1 4)]
    (test.assert-i64-eq
      (exposure.storage-exposure-frame facts 1 3)
      -1
      "suspended queries create no frames")
    (test.assert-i64-eq
      (exposure.storage-exposure-frame facts 1 4)
      -1
      "nested queries remain suspended")
    (exposure.storage-exposure-resume! facts inner)
    (test.assert-i64-eq
      (exposure.storage-exposure-current facts)
      -1
      "inner resume preserves outer suspension")
    (exposure.storage-exposure-resume! facts outer)
    (test.assert-i64-eq
      (exposure.storage-exposure-current facts)
      frame
      "outer resume restores its frame")
    (exposure.storage-exposure-leave! facts previous true)
    (let
      [stale : exposure.StorageExposureSuspension
        (exposure.storage-exposure-suspend! facts)]
      (exposure.storage-exposure-reset! facts)
      (let
        [previous : i64 (exposure.storage-exposure-enter! facts 1 5)]
        [current : i64 (exposure.storage-exposure-current facts)]
        (exposure.storage-exposure-resume! facts stale)
        (test.assert-i64-eq
          (exposure.storage-exposure-current facts)
          current
          "stale resume cannot alter a new generation")
        (exposure.storage-exposure-leave! facts previous true)))))