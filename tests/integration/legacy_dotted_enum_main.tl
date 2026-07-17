;; Legacy path imports flatten both modules, while the bridge refers to the
;; provider through a dotted alias. Both views must resolve one enum identity.
(import "legacy_dotted_enum_provider.tl")
(import "legacy_dotted_enum_bridge.tl")

(define (main) : i64
  (match (legacy-dotted-enum-roundtrip (LegacyDottedEnum.Value 42))
    [(LegacyDottedEnum.Value value) value]))