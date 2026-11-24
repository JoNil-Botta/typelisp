(defstruct Item
  (a i64)
  (b i64))

(defstruct Holder
  (:lifetimes a b)
  (prefix i64)
  (item (& a Item))
  (slice (& b (Slice i64)))
  (inline Item))

(define (sum-item [item : (& Item)]) : i64
  (+ item.a item.b))

(define (sum-slice [items : (& (Slice i64))]) : i64
  (+ (length items) (array-ref items 1)))

(define (sum-struct [view : (& v (Holder a b))]) : i64
  (+
    (sum-item (& view.item))
    (+ (sum-slice (& view.slice)) (sum-item (& view.inline)))))

(define (sum-other [item : (& a Item)]) : i64
  (let
    [pair (tuple 0 item)]
    [items (array (Item 0 6) (Item 5 1))]
    [cell (box (Item 4 2))]
    (+
      (sum-item (& (tuple-ref pair 1)))
      (+ (sum-item (& (array-ref items 1))) (sum-item (& (deref cell)))))))

(define (main) : i64
  (let
    [item (Item 1 5)]
    [items : (Array i64 2) (array 9 14)]
    [holder (Holder 99 (& item) (slice-view items 0 2) (Item 0 2))]
    (if (= (sum-item (& holder.item)) 6)
      (+ (sum-other (& item)) (sum-struct (& holder)))
      1)))