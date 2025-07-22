;; Title: BitVault Pro - Advanced Bitcoin Collateralization Protocol
;; 
;; Summary: Enterprise-grade Bitcoin-backed stablecoin protocol with dynamic risk management
;;          and automated liquidation mechanisms for institutional DeFi applications.
;; 
;; Description: BitVault Pro revolutionizes Bitcoin utility by enabling users to unlock
;;              liquidity from their BTC holdings without selling. Users deposit Bitcoin
;;              as collateral to mint dollar-pegged stablecoins with intelligent risk
;;              assessment, real-time price feeds, and sophisticated interest calculations.
;;              
;;              Key innovations include adaptive collateral ratios, multi-tier liquidation
;;              protection, compound interest mechanics, and governance-driven protocol
;;              optimization. Built for scalability and security on Stacks Layer 2,
;;              enabling seamless Bitcoin DeFi experiences with institutional-grade
;;              risk management and capital efficiency.
;; 

;; ERROR CODES & CONSTANTS

(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u1001))
(define-constant ERR-POSITION-NOT-FOUND (err u1002))
(define-constant ERR-UNDERCOLLATERALIZED (err u1003))
(define-constant ERR-MINIMUM-LOAN-REQUIRED (err u1004))
(define-constant ERR-INSUFFICIENT-DEBT (err u1005))
(define-constant ERR-PRICE-EXPIRED (err u1006))
(define-constant ERR-PROTOCOL-PAUSED (err u1007))
(define-constant ERR-INVALID-AMOUNT (err u1008))
(define-constant ERR-NO-PRICE-DATA (err u1009))

;; PROTOCOL CONFIGURATION PARAMETERS

;; Risk Management Parameters
(define-constant COLLATERAL-RATIO u150)           ;; 150% minimum collateral ratio (1.5x)
(define-constant LIQUIDATION-THRESHOLD u120)      ;; 120% liquidation threshold
(define-constant LIQUIDATION-PENALTY u10)         ;; 10% liquidation penalty

;; Financial Parameters
(define-constant MINIMUM_LOAN_AMOUNT u100000000)  ;; 100 stablecoins (with 8 decimals)
(define-constant PRICE_EXPIRY u86400)             ;; Price feed valid for 24 hours (in seconds)

;; Interest Rate Configuration
(define-constant INTEREST_RATE_PER_BLOCK u5)      ;; 0.0005% interest per block (~10% APR)
(define-constant INTEREST_RATE_DENOMINATOR u1000000) ;; Interest rate precision

;; PROTOCOL STATE VARIABLES

;; Administrative Controls
(define-data-var protocol-owner principal tx-sender)
(define-data-var protocol-paused bool false)

;; System Financial Metrics
(define-data-var total-debt uint u0)              ;; Total debt in the system
(define-data-var total-collateral uint u0)        ;; Total BTC collateral in the system
(define-data-var stability-fee uint u0)           ;; Accumulated protocol fees
(define-data-var last-accrual-block uint stacks-block-height) ;; Last interest accrual block

;; Price Oracle Integration
(define-data-var btc-price-in-usd 
  (optional {price: uint, timestamp: uint}) none) ;; BTC/USD price from oracle

;; Testing Utilities
(define-data-var current-time uint u0)            ;; Mock time for testing

;; DATA STRUCTURES

;; User Collateralized Debt Position
(define-map positions principal {
  collateral: uint,        ;; Amount of BTC collateral (in satoshis)
  debt: uint,             ;; Amount of stablecoin debt
  last-update-block: uint ;; Last block when position was updated (for interest calculation)
})

;; Protocol Stablecoin Token
(define-fungible-token stable-usd)

;; ADMINISTRATIVE FUNCTIONS

;; Transfer Protocol Ownership
(define-public (set-protocol-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR-NOT-AUTHORIZED)
    (ok (var-set protocol-owner new-owner))
  )
)

;; Emergency Protocol Controls
(define-public (pause-protocol (paused bool))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR-NOT-AUTHORIZED)
    (ok (var-set protocol-paused paused))
  )
)

;; Oracle Price Feed Updates
(define-public (update-btc-price (price uint) (timestamp uint))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (> price u0) ERR-INVALID-AMOUNT)
    (var-set btc-price-in-usd (some {price: price, timestamp: timestamp}))
    (ok true)
  )
)

;; Testing Time Controls
(define-public (set-current-time (time uint))
  (begin
    (asserts! (is-eq tx-sender (var-get protocol-owner)) ERR-NOT-AUTHORIZED)
    (ok (var-set current-time time))
  )
)

;; CORE UTILITY FUNCTIONS

;; Calculate USD Value of BTC Collateral
(define-private (collateral-value (collateral-amount uint) (price uint))
  (* collateral-amount price)
)

;; Calculate Required Collateral for Debt Amount
(define-private (required-collateral (debt-amount uint) (price uint))
  (/ (* debt-amount COLLATERAL-RATIO) (/ price u100))
)

;; Position Safety Validation
(define-private (is-position-safe (user principal) (btc-price uint))
  (let (
    (position (unwrap! (map-get? positions user) false))
    (debt (get debt position))
    (collateral (get collateral position))
    (collateral-value-usd (collateral-value collateral btc-price))
    (min-collateral-value-usd (/ (* debt COLLATERAL-RATIO) u100))
  )
    (>= collateral-value-usd min-collateral-value-usd)
  )
)

;; Compound Interest Calculation
(define-private (calculate-interest (debt uint) (blocks-passed uint))
  (/ (* debt (* blocks-passed INTEREST_RATE_PER_BLOCK)) INTEREST_RATE_DENOMINATOR)
)

;; INTEREST ACCRUAL SYSTEM

;; Global Interest Accrual Across All Positions
(define-private (accrue-global-interest)
  (let (
    (current-block stacks-block-height)
    (last-block (var-get last-accrual-block))
    (blocks-passed (- current-block last-block))
    (total-system-debt (var-get total-debt))
    (interest-accrued (calculate-interest total-system-debt blocks-passed))
  )
    (begin
      (if (> blocks-passed u0)
        (begin
          (var-set stability-fee (+ (var-get stability-fee) interest-accrued))
          (var-set total-debt (+ total-system-debt interest-accrued))
          (var-set last-accrual-block current-block)
        )
        false
      )
      true
    )
  )
)

;; Individual Position Interest Accrual
(define-private (accrue-position-interest (user principal))
  (let (
    (position (unwrap! (map-get? positions user) 
                      {debt: u0, collateral: u0, last-update-block: stacks-block-height}))
    (debt (get debt position))
    (collateral (get collateral position))
    (last-update (get last-update-block position))
    (blocks-passed (- stacks-block-height last-update))
    (interest-accrued (calculate-interest debt blocks-passed))
    (new-debt (+ debt interest-accrued))
    (updated-position {
      collateral: collateral,
      debt: new-debt,
      last-update-block: stacks-block-height
    })
  )
    (begin
      (if (> blocks-passed u0)
        (map-set positions user updated-position)
        false
      )
      updated-position
    )
  )
)

;; PRICE ORACLE INTEGRATION

;; Real-time Price Feed with Expiry Validation
(define-read-only (get-current-price)
  (match (var-get btc-price-in-usd)
    price-data (let (
      (price (get price price-data))
      (timestamp (get timestamp price-data))
      (current-timestamp (var-get current-time))
    )
      (if (>= (- current-timestamp timestamp) PRICE_EXPIRY)
        ERR-PRICE-EXPIRED
        (if (<= price u0)
          ERR-PRICE-EXPIRED
          (ok price)
        )
      ))
    ERR-NO-PRICE-DATA)
)

;; CORE PROTOCOL OPERATIONS

;; Create or Expand Collateralized Debt Position
(define-public (create-position (btc-amount uint) (stable-amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (>= btc-amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= stable-amount MINIMUM_LOAN_AMOUNT) ERR-MINIMUM-LOAN-REQUIRED)
    
    ;; Retrieve Current Market Price
    (let (
      (btc-price (try! (get-current-price)))
      (user tx-sender)
      (existing-position (map-get? positions user))
    )
      (begin
        ;; Update Global Interest Calculations
        (accrue-global-interest)
        
        ;; Process Existing or Initialize New Position
        (let (
          (current-position 
            (if (is-some existing-position)
              (accrue-position-interest user)
              {collateral: u0, debt: u0, last-update-block: stacks-block-height}
            )
          )
        )
          ;; Calculate Updated Position Metrics
          (let (
            (old-collateral (get collateral current-position))
            (old-debt (get debt current-position))
            (new-collateral (+ old-collateral btc-amount))
            (new-debt (+ old-debt stable-amount))
            (min-required-collateral (required-collateral new-debt btc-price))
          )
            (begin
              ;; Validate Collateralization Requirements
              (asserts! (>= (collateral-value new-collateral btc-price) min-required-collateral) 
                       ERR-INSUFFICIENT-COLLATERAL)
              
              ;; Update User Position Record
              (map-set positions user {
                collateral: new-collateral,
                debt: new-debt,
                last-update-block: stacks-block-height
              })
              
              ;; Update Protocol-wide Metrics
              (var-set total-collateral (+ (var-get total-collateral) btc-amount))
              (var-set total-debt (+ (var-get total-debt) stable-amount))
              
              ;; Mint Stablecoins to User
              (ft-mint? stable-usd stable-amount user)
            )
          )
        )
      )
    )
  )
)

;; Add Additional Collateral to Existing Position
(define-public (add-collateral (btc-amount uint))
  (let (
    (user tx-sender)
    (position (unwrap! (map-get? positions user) ERR-POSITION-NOT-FOUND))
  )
    (begin
      (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
      (asserts! (> btc-amount u0) ERR-INVALID-AMOUNT)
      
      ;; Process Interest Accruals
      (accrue-global-interest)
      
      ;; Update Position with Accrued Interest
      (let (
        (updated-position (accrue-position-interest user))
        (new-debt (get debt updated-position))
        (current-collateral (get collateral updated-position))
        (new-collateral (+ current-collateral btc-amount))
      )
        (begin
          ;; Record Enhanced Collateral Position
          (map-set positions user {
            collateral: new-collateral,
            debt: new-debt,
            last-update-block: stacks-block-height
          })
          
          ;; Update System Collateral Totals
          (var-set total-collateral (+ (var-get total-collateral) btc-amount))
          
          (ok true)
        )
      )
    )
  )
)