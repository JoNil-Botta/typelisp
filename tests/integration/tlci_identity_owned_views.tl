;; Focused semantic witnesses for the shallow-view helpers introduced by the
;; by-value ownership migration. These remaining macros are part of the
;; embedded stdlib TLCI inventory, but ordinary discovery does not reach every
;; path together.
(import stdlib.msvc)
(import stdlib.process)
(import stdlib.process_runtime)

(defstruct TlciIdentityMsvcWitness
  (value i64))

(define (main) : i64
  (let
    [place : TlciIdentityMsvcWitness (TlciIdentityMsvcWitness 7)]
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [boxed : (Box i64) (box 29)]
    [text : String "core"]
    [core-view : String
      (__tl-compiler-owned-shared-view-dyn-ref-as (& text) String)]
    [place-view : TlciIdentityMsvcWitness (msvc.msvc-shared-view place)]
    [item-view : i64 (msvc.msvc-array-element-shared-view items 0)]
    [box-view : i64 (msvc.msvc-box-shared-view boxed)]
    [process-place-view : TlciIdentityMsvcWitness
      (process.process-place-shared-view place)]
    [runtime-place-view : TlciIdentityMsvcWitness
      (process_runtime.process-runtime-place-shared-view place)]
    (cond
      [(not (= (string-length core-view) 4)) 2]
      [(not (= place-view.value 7)) 3]
      [(not (= item-view 0)) 4]
      [(not (= box-view 29)) 5]
      [(not (= process-place-view.value 7)) 6]
      [(not (= runtime-place-view.value 7)) 7]
      [else 42])))