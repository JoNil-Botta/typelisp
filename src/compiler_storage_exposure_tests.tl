(import compiler_storage_exposure as exposure)
(import stdlib.iterator)
(import stdlib.test)

(test
  compiler-storage-exposure-lexical-keys
  (let
    [facts : exposure.StorageExposure (exposure.storage-exposure-new)]
    [previous : i64 (exposure.storage-exposure-enter! facts 3 9)]
    [frame : i64 (exposure.storage-exposure-current facts)]
    [first : i64 -1]
    (for [name (array (cast 7 : i64) -9223372036854775808 9223372036854775807)]
      (for [scope (iterator.range 0 3)]
        (for [kind (iterator.range -1 3)]
          (let
            ;; Deliberately collide every key, including full-width names.
            [identity : i64
              (exposure.storage-exposure-bind! facts kind scope name 0)]
            [index : i64
              (exposure.storage-exposure-find facts frame kind scope name 0)]
            (when (= first -1) (set! first identity))
            (test.assert-i64-eq
              (exposure.storage-exposure-index facts identity)
              index
              "exact key survives collisions")
            (test.assert-i64-eq
              (exposure.storage-exposure-binding-field facts index 4)
              0
              "new binding is private")
            (exposure.storage-exposure-mark! facts identity)
            (test.assert-i64-eq
              (exposure.storage-exposure-bind! facts kind scope name 0)
              identity
              "duplicate has one identity")
            (test.assert-i64-eq
              (exposure.storage-exposure-binding-field facts index 4)
              1
              "exposure is monotone")))))
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
      "declarations sharing syntax stay distinct")
    (exposure.storage-exposure-reset! facts)
    (test.assert-i64-eq
      (exposure.storage-exposure-index facts first)
      -1
      "reset rejects stale binding identities")
    (let
      [outer : i64 (exposure.storage-exposure-enter! facts 3 9)]
      [fresh : i64 (exposure.storage-exposure-bind! facts 0 0 7 0)]
      (test.assert-true
        (!= first fresh)
        "new generation cannot reuse a source identity")
      (exposure.storage-exposure-leave! facts outer true))))

(test
  compiler-storage-exposure-nested-and-incomplete
  (let
    [facts : exposure.StorageExposure (exposure.storage-exposure-new)]
    [outside : i64 (exposure.storage-exposure-enter! facts 3 9)]
    [outer-frame : i64 (exposure.storage-exposure-current facts)]
    [outer : i64 (exposure.storage-exposure-bind! facts 0 -1 7 0)]
    [previous : i64 (exposure.storage-exposure-enter! facts 3 10)]
    [inner-frame : i64 (exposure.storage-exposure-current facts)]
    [inner : i64 (exposure.storage-exposure-bind! facts 0 -1 7 0)]
    (test.assert-true (!= outer inner) "capture owns a separate slot")
    (exposure.storage-exposure-mark! facts inner)
    (exposure.storage-exposure-leave! facts previous true)
    (test.assert-i64-eq
      (exposure.storage-exposure-current facts)
      outer-frame
      "nested exit restores enclosing frame")
    (test.assert-i64-eq
      (exposure.storage-exposure-binding-field
        facts
        (exposure.storage-exposure-index facts outer)
        4)
      0
      "nested exposure leaves enclosing slot private")
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
    [outer-binding : i64 (exposure.storage-exposure-bind! facts 0 5 7 0)]
    (exposure.storage-exposure-mark! facts outer-binding)
    (let
      [outer : i64 (exposure.storage-exposure-enter! facts 1 3)]
      [inner-frame : i64 (exposure.storage-exposure-current facts)]
      [inner-binding : i64 (exposure.storage-exposure-bind! facts 0 5 8 0)]
      (exposure.storage-exposure-mark! facts inner-binding)
      (test.assert-i64-eq
        (exposure.storage-exposure-frame-field facts outer-frame 2)
        (exposure.storage-exposure-index facts outer-binding)
        "outer frame keeps its own exposure list")
      (test.assert-i64-eq
        (exposure.storage-exposure-frame-field facts inner-frame 2)
        (exposure.storage-exposure-index facts inner-binding)
        "nested frame keeps its own exposure list")
      (test.assert-i64-eq
        (exposure.storage-exposure-binding-field
          facts
          (exposure.storage-exposure-index facts inner-binding)
          6)
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