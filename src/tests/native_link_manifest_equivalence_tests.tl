(import native_link_manifest_types as n)
(import native_link_manifest as manifest)
(import native_link_manifest_core as core)
(import native_link_manifest_codec as codec)
(import tests.native_link_manifest_test_support as support)
(import stdlib.iterator)
(import stdlib.comptime)
(import stdlib.format)
(import stdlib.test)

;; Declared-set insertion order is varied without touching ordered schedules.
(defmacro (shuffle! [T : type] [items : comptime.Expr] [seed : comptime.Expr]) : unit
  `(let
    [slots ,items]
    [pick : i64 ,seed]
    [length : i64 (array-length slots)]
    (for [i (stdlib.iterator.range 0 length)]
      (let
        [j : i64 (% (+ (* i 17) pick) length)]
        [saved : ,T (clone (array-ref slots i))]
        (set! (array-ref slots i) (clone (array-ref slots j)))
        (set! (array-ref slots j) saved)))))

(test
  native-link-sealed-profile-and-all-declared-sets
  (let
    [input : n.NativeLinkSemanticInput (support.sealed-sample)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    [checked : core.NativeLinkValidation (core.validate (& input) (& limits))]
    (when
      (not checked.ok)
      (for [i (iterator.range 0 checked.count)]
        (test.assert-true
          false
          (format.format
            "{}: {}"
            (array-ref checked.diagnostics i).field
            (array-ref checked.diagnostics i).detail))))
    (match (manifest.encode (& input) (& limits))
      [(manifest.NativeCanonicalBytes baseline)
        (for [seed (iterator.range 0 8)]
          (let
            [changed : n.NativeLinkSemanticInput (clone input)]
            (shuffle! n.LogicalRoot (&mut changed.manifest.roots) seed)
            (shuffle! n.NativeOutputKind (&mut changed.profile.outputs) seed)
            (shuffle! n.LogicalRoot (&mut changed.profile.roots) seed)
            (shuffle! n.ProfileFile (&mut changed.profile.files) seed)
            (shuffle! String (&mut changed.profile.runtime-identities) seed)
            (shuffle! n.SystemImport (&mut changed.profile.imports) seed)
            (shuffle! n.CapabilityRow (&mut changed.profile.capabilities) seed)
            (shuffle! n.HardeningRow (&mut changed.profile.hardening) seed)
            (match (manifest.encode (& changed) (& limits))
              [(manifest.NativeCanonicalBytes bytes)
                (test.assert-true
                  (codec.bytes-equal? (& baseline) (& bytes))
                  "all eight declared sets ignore insertion order")]
              [_
                (test.assert-true
                  false
                  "permutation preserves semantic admission")])))]
      [_ (test.assert-true false "sealed profile fixture must be admitted")])))

(define (fresh-arena? [baseline : (& b (__tl_dyn-array u8))]) : bool
  (with-scratch
    (let
      [input : n.NativeLinkSemanticInput (support.sample true)]
      [limits : core.NativeLinkLimits (core.default-limits)]
      (match (manifest.encode (& input) (& limits))
        [(manifest.NativeCanonicalBytes bytes)
          (codec.bytes-equal? baseline (& bytes))]
        [_ false]))))

(test
  native-link-fresh-arenas-do-not-affect-bytes
  (let
    [input : n.NativeLinkSemanticInput (support.sample true)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    (match (manifest.encode (& input) (& limits))
      [(manifest.NativeCanonicalBytes bytes)
        (for [_i (iterator.range 0 3)]
          (test.assert-true
            (fresh-arena? (& bytes))
            "canonical bytes exclude arena addresses and allocation history"))]
      [_ (test.assert-true false "arena fixture encoding")])))

(test
  native-link-ordered-schedules-and-events-stay-ordered
  (let
    [input : n.NativeLinkSemanticInput (support.sealed-sample)]
    [changed : n.NativeLinkSemanticInput (clone input)]
    [limits : core.NativeLinkLimits (core.default-limits)]
    [first : n.ProfileInput (clone (array-ref changed.profile.inputs 0))]
    (set!
      (array-ref changed.profile.inputs 0)
      (clone (array-ref changed.profile.inputs 1)))
    (set! (array-ref changed.profile.inputs 1) first)
    (match (codec.encode-input-record (& input) (& limits.wire))
      [(codec.NativeBytes baseline)
        (match (codec.encode-input-record (& changed) (& limits.wire))
          [(codec.NativeBytes bytes)
            (test.assert-false
              (codec.bytes-equal? (& baseline) (& bytes))
              "startup/end schedule order is semantic")]
          [_ (test.assert-true false "ordered profile encoding")])
        (set! changed (clone input))
        (let
          [payload : n.NativeEventPayload
            (clone (array-ref changed.manifest.events 0).payload)]
          [origin : n.NativeLinkProvenance
            (clone (array-ref changed.manifest.events 0).provenance)]
          (set!
            (array-ref changed.manifest.events 0).payload
            (clone (array-ref changed.manifest.events 1).payload))
          (set!
            (array-ref changed.manifest.events 0).provenance
            (clone (array-ref changed.manifest.events 1).provenance))
          (set! (array-ref changed.manifest.events 1).payload payload)
          (set! (array-ref changed.manifest.events 1).provenance origin))
        (match (manifest.encode (& changed) (& limits))
          [(manifest.NativeCanonicalBytes bytes)
            (test.assert-false
              (codec.bytes-equal? (& baseline) (& bytes))
              "different event kinds retain exact stream order")]
          [_
            (test.assert-true
              false
              "event permutation remains structurally valid")])]
      [_ (test.assert-true false "ordered fixture encoding")])))