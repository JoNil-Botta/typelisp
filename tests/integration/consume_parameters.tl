;; Opt-in consuming parameters are a static callable effect with unchanged ABI.
;; lint-allow: unused-import
(import stdlib.string)
(import "consume_parameters_helper.tl" module consume.parameters.helper as helper)

(defmacro (generated-consumer-module) : Module
  `(begin
    (module generated.consume.parameters)
    (import stdlib.string)
    (defstruct GeneratedPayload
      (value i64))
    (define (consume-length [text : String (:consume)]) : i64
      (string-length text))
    (define (consume-payload [payload : GeneratedPayload (:consume)]) : i64
      (struct-get payload value))))

(import (generated-consumer-module) as generated)

(defstruct LocalPayload
  (value i64))

(define (consume-length [text : String (:consume)]) : i64
  (string-length text))

(define (ordinary-length [text : String]) : i64
  (string-length text))

(define (consume-copy [value : i64 (:consume)]) : i64
  (+ value 1))

(define (consume-payload [payload : LocalPayload (:consume)]) : i64
  (struct-get payload value))

(define (ordinary-payload [payload : LocalPayload]) : i64
  (struct-get payload value))

(define (call-consumer
  [f : (-> (:consume String) i64)]
  [text : String (:consume)]) : i64
  (f text))

(define (main) : i64
  (let
    [direct : String "abc"]
    [qualified : String "de"]
    [generated-value : String "fghi"]
    [through-value : String "jklmn"]
    [through-lambda : String "opqrst"]
    [compatible : String "uv"]
    [copyable : i64 7]
    [local-payload : LocalPayload (LocalPayload 10)]
    [ordinary-struct : LocalPayload (LocalPayload 13)]
    [qualified-payload : helper.HelperPayload (helper.HelperPayload 11)]
    [generated-payload : generated.GeneratedPayload
      (generated.GeneratedPayload 12)]
    [consumer : (-> (:consume String) i64) consume-length]
    [lambda-consumer : (-> (:consume String) i64)
      (lambda ([text : String (:consume)]) : i64
        (string-length text))]
    [score : i64
      (+
        (consume-length direct)
        (+
          (helper.consume-length qualified)
          (+
            (generated.consume-length generated-value)
            (+
              (call-consumer consumer through-value)
              (+
                (call-consumer lambda-consumer through-lambda)
                (+
                  (ordinary-length compatible)
                  (+
                    (string-length compatible)
                    (+
                      (consume-copy copyable)
                      (+
                        copyable
                        (+
                          (consume-payload local-payload)
                          (+
                            (helper.consume-payload qualified-payload)
                            (+
                              (generated.consume-payload generated-payload)
                              (+
                                (ordinary-payload ordinary-struct)
                                (struct-get ordinary-struct value))))))))))))))]
    (if (= score 98)
      0
      1)))