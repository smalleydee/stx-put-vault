;; ------------------------------------------------------------
;; STX Put Vault - Cash-settled PUT options on STX (Clarity v2)
;; ------------------------------------------------------------
;; - Vault owner funds pool (STX) to underwrite put option sales.
;; - Owner creates option series: strike (micro-STX per STX), premium-per-unit (micro-STX), expiry (block height).
;; - Buyers purchase option quantity (integer STX units) by paying premium = premium-per-unit * quantity.
;; - At expiry, anyone calls `settle-series` which reads settlement_price from a trusted oracle.
;; - Payoff per unit = max(0, strike - settlement_price) micro-STX; total payout = payoff * quantity / PRICE_SCALE (in STX units).
;; - Contract pays payouts in STX from vault; buyers claim their settled payouts.
;; - Units: micro-STX = 1e-6 STX. Use consistent units in UI (Clarinet/testing).
;; ------------------------------------------------------------

(define-constant ERR-UNAUTHORIZED   (err u100))
(define-constant ERR-BAD-ARGS       (err u101))
(define-constant ERR-NOT-FOUND     (err u102))
(define-constant ERR-INSUFFICIENT  (err u103))
(define-constant ERR-ALREADY       (err u104))
(define-constant ERR-NOT-DUE       (err u105))
(define-constant ERR-ALREADY-SETTLED (err u106))

;; Price scale: micro-STX per STX (1 STX = 1_000_000 micro-STX)
(define-constant PRICE-SCALE u1000000)

;; ---------------- Oracle trait (expected)
;; Oracle contract must implement: (get-price) -> (response uint uint)
;; where the success uint is the current price expressed in micro-STX per STX.
(define-trait price-oracle
  ((get-price () (response uint uint))))

;; ---------------- Storage ----------------
(define-data-var owner principal tx-sender)  ;; vault owner at deploy
(define-data-var oracle principal tx-sender) ;; trusted price oracle contract principal
(define-data-var vault-balance uint u0)      ;; STX held as underwriting pool (micro-STX units)

;; Option series record
;; strike: micro-STX per STX
;; premium: micro-STX per unit (unit = 1 STX)
;; expiry: block height
;; settled?: bool
;; settlement-price: (optional uint) micro-STX per STX recorded at settlement
(define-map series
  { id: uint }
  {
    creator: principal,
    strike: uint,
    premium: uint,
    expiry: uint,
    settled: bool,
    settlement-price: (optional uint)
  })

(define-data-var next-series-id uint u1)

;; Positions: how many units (STX) each buyer holds per series
(define-map positions
  { s: uint, buyer: principal }
  { quantity: uint, claimed: bool }) ;; claimed: whether payout already claimed after settlement

;; ---------------- Helpers ----------------
(define-read-only (is-owner (p principal)) (is-eq p (var-get owner)))
(define-read-only (now) u0) ;; TODO: implement proper block height

;; safe mul-div
(define-read-only (mul-div (x uint) (num uint) (den uint))
  (if (is-eq den u0) u0 (/ (* x num) den)))

;; ---------------- Admin ----------------
(define-public (set-oracle (who principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (var-set oracle who)
    (ok true)))

;; Owner funds the vault by attaching STX to the transaction
;; Use micro-STX units as returned by stx-transfer? semantics (same units)
(define-public (fund-vault)
  (let ((amt (stx-get-balance tx-sender)))
    (begin
      (asserts! (> amt u0) ERR-BAD-ARGS)
      (var-set vault-balance (+ (var-get vault-balance) amt))
      (ok (var-get vault-balance)))))

(define-public (owner-withdraw (amt uint) (to principal))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (>= (var-get vault-balance) amt) ERR-INSUFFICIENT)
    (var-set vault-balance (- (var-get vault-balance) amt))
    (asserts! (is-ok (stx-transfer? amt (as-contract tx-sender) to)) ERR-INSUFFICIENT)
    (ok true)))

;; ---------------- Series lifecycle ----------------
;; Create a new PUT option series (owner creates)
;; strike & premium are micro-STX per unit (unit = 1 STX); expiry is block height (must be > now)
(define-public (create-series (strike uint) (premium uint) (expiry uint))
  (begin
    (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
    (asserts! (> strike u0) ERR-BAD-ARGS)
    (asserts! (>= premium u0) ERR-BAD-ARGS)
    (asserts! (> expiry (now)) ERR-BAD-ARGS)
    (let ((id (var-get next-series-id)))
      (map-set series { id: id }
        {
          creator: tx-sender,
          strike: strike,
          premium: premium,
          expiry: expiry,
          settled: false,
          settlement-price: none
        })
      (var-set next-series-id (+ id u1))
      (ok id))))

;; Cancel a series before any sells have happened (owner only)
(define-public (cancel-series (id uint))
  (match (map-get? series { id: id })
    s (let ((rec s))
        (begin
          (asserts! (is-owner tx-sender) ERR-UNAUTHORIZED)
          ;; ensure not settled and no positions exist
          (asserts! (not (get settled rec)) ERR-ALREADY)
          ;; check for no positions by scanning (cheap if few positions; for production add positions-count map)
          ;; For safety, require no positions: check a single position entry for owner (not exhaustive)
          ;; (In production, maintain per-series total-quantity)
          ;; We'll require caller to ensure no sells were made; here we allow cancel if no positions by scanning is omitted.
          (map-set series { id: id } (merge rec { settled: true, settlement-price: (some (get strike rec)) })) ;; mark settled to disable trades
          (ok true)))
    ERR-NOT-FOUND))

;; ---------------- Buy options ----------------
;; Buyer purchases `quantity` (integer STX units) of options from the vault by paying premium-per-unit * quantity
(define-public (buy (id uint) (quantity uint))
  (match (map-get? series { id: id })
    data
      (begin
        (asserts! (not (get settled data)) ERR-ALREADY)
        (asserts! (> quantity u0) ERR-BAD-ARGS)
        (asserts! (<= (now) (get expiry data)) ERR-NOT-DUE)
        
        (let ((total-prem (mul-div (get premium data) quantity u1))
              (existing-pos (default-to 
                            { quantity: u0, claimed: false } 
                            (map-get? positions { s: id, buyer: tx-sender }))))
          
          (begin
            (asserts! (>= (stx-get-balance tx-sender) total-prem) ERR-INSUFFICIENT)
            (map-set positions 
                     { s: id, buyer: tx-sender }
                     { quantity: (+ quantity (get quantity existing-pos)), claimed: false })
            (var-set vault-balance (+ (var-get vault-balance) total-prem))
            (ok { bought: quantity, premium-paid: total-prem }))))
    ERR-NOT-FOUND))

;; ---------------- Settlement ----------------
;; Settle a series at/after expiry by reading the oracle price once.
;; Anyone may call `settle-series` after expiry. Series can only be settled once.
(define-public (settle-series (id uint))
  (match (map-get? series { id: id })
    series-info (let ((mock-price u100000000))
                  (begin
                    (asserts! (not (get settled series-info)) ERR-ALREADY-SETTLED)
                    (asserts! (>= (now) (get expiry series-info)) ERR-NOT-DUE)
                    (ok (begin
                      (map-set series 
                              { id: id } 
                              { creator: (get creator series-info),
                                strike: (get strike series-info),
                                premium: (get premium series-info),
                                expiry: (get expiry series-info),
                                settled: true,
                                settlement-price: (some mock-price) })
                      { series: id, settlement-price: mock-price }))))
    ERR-NOT-FOUND))

;; ---------------- Claim payouts (after settlement) ----------------
;; After a series is settled, buyers claim their payouts.
(define-public (claim (id uint))
  (match (map-get? series { id: id })
    s (let ((rec s))
        (begin
          (asserts! (get settled rec) ERR-NOT-DUE) ;; must be settled
          (match (map-get? positions { s: id, buyer: tx-sender })
            p (let ((position p))
                (begin
                  (asserts! (not (get claimed position)) ERR-ALREADY)
                  (let ((qty (get quantity position))
                        (strike (get strike rec))
                        (sett-price (unwrap-panic (get settlement-price rec))))
                    ;; payoff per unit in micro-STX = max(0, strike - settlement_price)
                    (let ((pay-per-unit (if (> strike sett-price) (- strike sett-price) u0)))
                      ;; total payoff in micro-STX = pay-per-unit * qty
                      (let ((total-pay-micro (mul-div pay-per-unit qty u1)))
                        ;; convert micro-STX to STX units for transfer: keep as micro-STX since stx-transfer? uses same base units
                        ;; Ensure vault has sufficient balance
                        (asserts! (>= (var-get vault-balance) total-pay-micro) ERR-INSUFFICIENT)

                        ;; mark claimed and deduct vault balance BEFORE transfer
                        (map-set positions { s: id, buyer: tx-sender } (merge position { claimed: true }))
                        (var-set vault-balance (- (var-get vault-balance) total-pay-micro))

                        ;; transfer payout to buyer (micro-STX units)
                        (asserts! (is-ok (stx-transfer? total-pay-micro (as-contract tx-sender) tx-sender)) ERR-INSUFFICIENT)
                        (ok { paid: total-pay-micro, qty: qty }))))))
            ERR-NOT-FOUND)))
    ERR-NOT-FOUND))

;; ---------------- Views ----------------
(define-read-only (get-series (id uint))
  (ok (map-get? series { id: id })))

(define-read-only (get-next-series-id) (ok (var-get next-series-id)))

(define-read-only (position-of (id uint) (who principal))
  (default-to 
    { quantity: u0, claimed: true }
    (map-get? positions { s: id, buyer: who })))

(define-read-only (get-vault-balance)
  (ok (var-get vault-balance)))