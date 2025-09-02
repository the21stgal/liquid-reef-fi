;; Liquid Reef Fi - Revolutionary Dynamic Liquidity Reefs Derivatives Protocol

;; Error Constants
(define-constant ERR-UNAUTHORIZED (err u1001))
(define-constant ERR-INVALID-AMOUNT (err u1002))
(define-constant ERR-INVALID-DURATION (err u1003))
(define-constant ERR-REEF-NOT-FOUND (err u1004))
(define-constant ERR-INSUFFICIENT-REEF (err u1005))
(define-constant ERR-SYNTHESIS-NOT-FOUND (err u1006))
(define-constant ERR-REBALANCING-CLOSED (err u1007))
(define-constant ERR-ALREADY-POSITIONED (err u1008))
(define-constant ERR-INVALID-SYNTHESIS (err u1009))
(define-constant ERR-CONSENSUS-NOT-MET (err u1010))
(define-constant ERR-INVALID-TIMELOCK (err u1011))
(define-constant ERR-MIGRATION-FAILED (err u1012))
(define-constant ERR-INSURANCE-INSUFFICIENT (err u1013))
(define-constant ERR-INVALID-CATEGORY (err u1014))

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-REEF-DURATION u365) ;; 365 days
(define-constant MIN-REEF-DURATION u7)   ;; 7 days
(define-constant BASE-YIELD-WEIGHT u100)
(define-constant DYNAMIC-MULTIPLIER u150)
(define-constant GUARDIAN-THRESHOLD u1000)

;; Data Variables
(define-data-var next-synthesis-id uint u1)
(define-data-var insurance-balance uint u0)
(define-data-var base-consensus uint u10) ;; 10%
(define-data-var reef-token principal .reef-token)
(define-data-var protocol-active bool true)
(define-data-var total-reefs uint u0)
(define-data-var yield-decay-rate uint u95) ;; 95% retention per period

;; Data Maps
(define-map reef-positions 
  { guardian: principal } 
  { 
    amount: uint, 
    duration: uint, 
    start-block: uint, 
    yield-score: uint,
    rebalance-count: uint,
    last-activity: uint
  })

(define-map position-synthesis 
  { id: uint } 
  { 
    creator: principal, 
    title: (string-ascii 100), 
    description: (string-ascii 500),
    category: uint, ;; 1=insurance, 2=rebalancing, 3=derivatives
    votes-for: uint, 
    votes-against: uint, 
    start-block: uint, 
    end-block: uint,
    executed: bool,
    consensus-required: uint,
    insurance-amount: uint
  })

(define-map guardian-positions 
  { synthesis-id: uint, guardian: principal } 
  { 
    weight: uint, 
    support: bool, 
    timestamp: uint 
  })

(define-map liquidity-migration 
  { migrator: principal } 
  { 
    delegate: principal, 
    migrated-weight: uint, 
    active: bool 
  })

(define-map yield-history 
  { guardian: principal, period: uint } 
  { 
    score: uint, 
    participation: uint, 
    consistency: uint 
  })

(define-map reef-configurations 
  { reef-id: principal } 
  { 
    rebalancing-period: uint, 
    execution-delay: uint, 
    custom-consensus: uint, 
    features-enabled: uint 
  })

(define-map insurance-allocations 
  { synthesis-id: uint } 
  { 
    recipient: principal, 
    amount: uint, 
    category: uint, 
    executed: bool 
  })

(define-map guardian-reputation 
  { guardian: principal } 
  { 
    base-score: uint, 
    reef-rating: uint, 
    synthesis-success-rate: uint, 
    rebalancing-activity: uint 
  })

;; Helper Functions
(define-private (calculate-dynamic-yield-weight (amount uint) (yield uint))
  (let (
    (base-weight (/ (* amount BASE-YIELD-WEIGHT) u1000000)) ;; Normalize amount
    (yield-bonus (/ (* yield DYNAMIC-MULTIPLIER) u10000))
    (total-weight (+ base-weight yield-bonus))
  )
    ;; Apply quadratic formula: sqrt(weight) * multiplier
    (/ (* (sqrti total-weight) u100) u10)))

(define-private (calculate-adaptive-consensus (category uint))
  (let (
    (base (var-get base-consensus))
  )
    (if (is-eq category u1) ;; Insurance synthesis need higher consensus
      (+ base u10)
      (if (is-eq category u2) ;; Rebalancing synthesis
        (+ base u5)
        base)))) ;; Derivatives synthesis use base consensus

(define-private (update-yield-score (guardian principal))
  (let (
    (current-reef (unwrap! (map-get? reef-positions { guardian: guardian }) ERR-REEF-NOT-FOUND))
    (blocks-passed (- block-height (get last-activity current-reef)))
    (decay-factor (if (> blocks-passed u1440) ;; ~10 days
      (var-get yield-decay-rate)
      u100))
    (new-yield (/ (* (get yield-score current-reef) decay-factor) u100))
  )
    (ok new-yield)))

;; Admin Functions
(define-public (set-reef-token (new-token principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set reef-token new-token)
    (ok true)))

(define-public (update-protocol-status (active bool))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set protocol-active active)
    (ok true)))

(define-public (adjust-base-consensus (new-consensus uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (<= new-consensus u50) ERR-INVALID-AMOUNT) ;; Max 50%
    (var-set base-consensus new-consensus)
    (ok true)))

(define-public (fund-insurance (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (var-set insurance-balance (+ (var-get insurance-balance) amount))
    (ok true)))

;; Core Reef Functions
(define-public (deposit-reef-tokens (amount uint) (duration uint))
  (let (
    (current-block block-height)
    (existing-reef (default-to 
      { amount: u0, duration: u0, start-block: u0, yield-score: u0, rebalance-count: u0, last-activity: u0 }
      (map-get? reef-positions { guardian: tx-sender })))
  )
    (asserts! (var-get protocol-active) ERR-UNAUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (and (>= duration MIN-REEF-DURATION) (<= duration MAX-REEF-DURATION)) ERR-INVALID-DURATION)
    
    ;; Calculate yield score based on amount, duration, and history
    (let (
      (base-yield (/ (* amount duration) u100))
      (time-multiplier (if (> duration u30) u120 u100))
      (new-yield (/ (* base-yield time-multiplier) u100))
      (updated-reef {
        amount: (+ (get amount existing-reef) amount),
        duration: duration,
        start-block: current-block,
        yield-score: (+ (get yield-score existing-reef) new-yield),
        rebalance-count: (get rebalance-count existing-reef),
        last-activity: current-block
      })
    )
      (map-set reef-positions { guardian: tx-sender } updated-reef)
      (var-set total-reefs (+ (var-get total-reefs) amount))
      (ok new-yield))))

(define-public (withdraw-reef-tokens (amount uint))
  (let (
    (guardian-reef (unwrap! (map-get? reef-positions { guardian: tx-sender }) ERR-REEF-NOT-FOUND))
    (reef-end (+ (get start-block guardian-reef) (get duration guardian-reef)))
  )
    (asserts! (>= block-height reef-end) ERR-INVALID-DURATION)
    (asserts! (>= (get amount guardian-reef) amount) ERR-INSUFFICIENT-REEF)
    
    (let (
      (updated-reef (merge guardian-reef { 
        amount: (- (get amount guardian-reef) amount),
        yield-score: (/ (* (get yield-score guardian-reef) (- (get amount guardian-reef) amount)) (get amount guardian-reef))
      }))
    )
      (map-set reef-positions { guardian: tx-sender } updated-reef)
      (var-set total-reefs (- (var-get total-reefs) amount))
      (ok amount))))

(define-public (create-synthesis (title (string-ascii 100)) (description (string-ascii 500)) (category uint) (insurance-amount uint))
  (let (
    (synthesis-id (var-get next-synthesis-id))
    (guardian-reef (unwrap! (map-get? reef-positions { guardian: tx-sender }) ERR-REEF-NOT-FOUND))
    (rebalancing-period u1440) ;; ~10 days in blocks
    (adaptive-consensus (calculate-adaptive-consensus category))
  )
    (asserts! (var-get protocol-active) ERR-UNAUTHORIZED)
    (asserts! (> (get yield-score guardian-reef) GUARDIAN-THRESHOLD) ERR-INSUFFICIENT-REEF)
    (asserts! (and (>= category u1) (<= category u3)) ERR-INVALID-CATEGORY)
    (asserts! (or (is-eq insurance-amount u0) (<= insurance-amount (var-get insurance-balance))) ERR-INSURANCE-INSUFFICIENT)
    
    (map-set position-synthesis 
      { id: synthesis-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        category: category,
        votes-for: u0,
        votes-against: u0,
        start-block: block-height,
        end-block: (+ block-height rebalancing-period),
        executed: false,
        consensus-required: adaptive-consensus,
        insurance-amount: insurance-amount
      })
    
    (var-set next-synthesis-id (+ synthesis-id u1))
    (ok synthesis-id)))

(define-public (position-on-synthesis (synthesis-id uint) (support bool))
  (let (
    (synthesis (unwrap! (map-get? position-synthesis { id: synthesis-id }) ERR-SYNTHESIS-NOT-FOUND))
    (guardian-reef (unwrap! (map-get? reef-positions { guardian: tx-sender }) ERR-REEF-NOT-FOUND))
    (existing-position (map-get? guardian-positions { synthesis-id: synthesis-id, guardian: tx-sender }))
    (yield-weight (calculate-dynamic-yield-weight (get amount guardian-reef) (get yield-score guardian-reef)))
  )
    (asserts! (is-none existing-position) ERR-ALREADY-POSITIONED)
    (asserts! (<= block-height (get end-block synthesis)) ERR-REBALANCING-CLOSED)
    (asserts! (not (get executed synthesis)) ERR-REBALANCING-CLOSED)
    
    ;; Record position
    (map-set guardian-positions 
      { synthesis-id: synthesis-id, guardian: tx-sender }
      { weight: yield-weight, support: support, timestamp: block-height })
    
    ;; Update synthesis position counts
    (let (
      (updated-synthesis (merge synthesis {
        votes-for: (if support (+ (get votes-for synthesis) yield-weight) (get votes-for synthesis)),
        votes-against: (if support (get votes-against synthesis) (+ (get votes-against synthesis) yield-weight))
      }))
    )
      (map-set position-synthesis { id: synthesis-id } updated-synthesis)
      
      ;; Update guardian participation
      (map-set reef-positions 
        { guardian: tx-sender } 
        (merge guardian-reef { 
          rebalance-count: (+ (get rebalance-count guardian-reef) u1),
          last-activity: block-height 
        }))
      
      (ok yield-weight))))

(define-public (execute-synthesis (synthesis-id uint))
  (let (
    (synthesis (unwrap! (map-get? position-synthesis { id: synthesis-id }) ERR-SYNTHESIS-NOT-FOUND))
    (total-positions (+ (get votes-for synthesis) (get votes-against synthesis)))
    (total-supply (var-get total-reefs))
    (consensus-met (>= (* total-positions u100) (* total-supply (get consensus-required synthesis))))
  )
    (asserts! (> block-height (get end-block synthesis)) ERR-REBALANCING-CLOSED)
    (asserts! (not (get executed synthesis)) ERR-ALREADY-POSITIONED)
    (asserts! consensus-met ERR-CONSENSUS-NOT-MET)
    (asserts! (> (get votes-for synthesis) (get votes-against synthesis)) ERR-INVALID-SYNTHESIS)
    
    ;; Mark as executed
    (map-set position-synthesis { id: synthesis-id } (merge synthesis { executed: true }))
    
    ;; Handle insurance allocation if needed
    (if (> (get insurance-amount synthesis) u0)
      (begin
        (map-set insurance-allocations 
          { synthesis-id: synthesis-id }
          { 
            recipient: (get creator synthesis), 
            amount: (get insurance-amount synthesis), 
            category: (get category synthesis), 
            executed: true 
          })
        (var-set insurance-balance (- (var-get insurance-balance) (get insurance-amount synthesis))))
      true)
    
    (ok true)))

(define-public (migrate-liquidity-power (delegate principal))
  (let (
    (guardian-reef (unwrap! (map-get? reef-positions { guardian: tx-sender }) ERR-REEF-NOT-FOUND))
    (migrated-weight (get yield-score guardian-reef))
  )
    (asserts! (not (is-eq tx-sender delegate)) ERR-MIGRATION-FAILED)
    (asserts! (> migrated-weight u0) ERR-INSUFFICIENT-REEF)
    
    (map-set liquidity-migration 
      { migrator: tx-sender }
      { 
        delegate: delegate, 
        migrated-weight: migrated-weight, 
        active: true 
      })
    
    (ok migrated-weight)))

(define-public (revoke-migration)
  (begin
    (asserts! (is-some (map-get? liquidity-migration { migrator: tx-sender })) ERR-MIGRATION-FAILED)
    
    (map-delete liquidity-migration { migrator: tx-sender })
    (ok true)))

;; Read-only Functions
(define-read-only (get-reef-position (guardian principal))
  (map