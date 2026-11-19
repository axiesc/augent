// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AugentToken — AUGENT (project v9), ticker AUGENT
/// @notice ERC-20 token with a built-in Agent-ID-gated fair launch, built
///         for the Binance Agent ID Hackathon. The base pattern is the
///         proven single-contract token+sale template of ONEBOT (project
///         v8, itself derived from SAMOINU v6 / TEGONG MIAO v7): Agent ID
///         gating via the SPACE ID registry, the "pool always opens, owner
///         always gets paid" model (every paid purchase split instantly
///         75% LP escrow / 15% treasury / 10% referral), shares recorded
///         during the sale and claimed as tokens via claim() after the
///         pool opens, transfer lock until the pool opens, pair-detected
///         buy/sell tax, LP minted to the burn address, and undistributed
///         tokens burned at finalize.
///
///         DELIBERATE DIFFERENCES FROM THE v8 BASIS (all driven by the
///         user-approved v9 spec, SPEK-V9-DRAFT.md, approved 2026-11-18):
///         1. FIXED SUPPLY / EXPLICIT BUCKETS. v8 derived its supply as
///            2x the sale allocation with the owner allocation carved from
///            the LP half. AUGENT instead has a hard total supply of
///            10,000,000,000 with explicit allocation buckets that must
///            sum to it exactly (enforced in the constructor):
///              paid sale    6,000,000,000  (60.000%) = 3,000 x 2,000,000
///              free sale      599,800,000  ( 5.998%) = 2,999 x   200,000
///              pool (LP)    3,000,000,000  (30.000%)
///              reserve        300,200,000  ( 3.002%)  <- balancing figure
///              owner          100,000,000  ( 1.000%)
///              TOTAL       10,000,000,000  (100%)
///            The reserve is the balancing figure (nominal 3% = 300,000,000
///            plus the 200,000 left over because 2,999 free shares x
///            200,000 is 200,000 short of a full 6%). Owner allocation and
///            reserve are both minted to the treasury at deploy, as two
///            separate, separately reported amounts.
///         2. REFERRAL VALIDITY. v9 spec section 4.2: a referrer is valid
///            iff the referrer holds an Agent ID (registry balanceOf > 0),
///            is not the buyer, and is not the zero address. The buyer is
///            always an Agent ID holder because the paid mint itself is
///            Agent-ID gated, so "both hold Agent ID" holds by
///            construction. (v8 additionally required the referrer to own
///            >= 1 paid share; that ONEBOT-specific amendment is NOT
///            carried into v9.)
///         3. PRE-DEADLINE REFUND (new; v8 had no refund at all). While
///            the sale is live and before the deadline, a paid buyer can
///            exit ALL of their paid shares with refund(): they receive
///            back 80% of the ESCROW portion of their purchases — i.e.
///            80% x 75% = 60% of the price per share (0.0006 BNB at the
///            0.001 BNB price). The treasury 15% and any referral 10% were
///            already paid out instantly at purchase time and cannot be
///            clawed back; the remaining 20% of the escrow portion stays
///            in the escrow for the pool. After the deadline there is NO
///            refund ever: the pool always opens. The free share record
///            is not affected by a refund.
///         4. TAX AUTO-SWAP (the only wholly novel logic vs the basis).
///            v8 sent the 3% buy / 3% sell tax to the treasury as TOKENS.
///            AUGENT accrues the tax to this contract instead, and once
///            at least TAX_SWAP_THRESHOLD tax tokens have accumulated, the
///            next sell triggers an automatic swap of the whole accrued
///            amount to BNB through the PancakeSwap V2 router
///            (swapExactTokensForETHSupportingFeeOnTransferTokens, path
///            AUGENT -> WBNB), with the BNB sent directly to the
///            treasury. A failed swap never blocks trading: the accrued
///            tax is restored and retried on a later sell.
///
///         Free shares: 2,999, 1 per Agent ID wallet, recorded in ONE
///         on-chain step by checking the SPACE ID Agent ID registry
///         directly (balanceOf > 0). No voucher, no attestor, no backend.
///         Paid shares: 3,000 at 0.001 BNB, cap 10 PAID shares per wallet;
///         the free share does NOT count toward the paid cap, so one
///         wallet can hold at most 1 free + 10 paid shares. Paid mint is
///         Agent-ID gated as well: the whole launch is Agent-ID-only.
///         Sale duration: 3 days from deployment. A full sellout (all
///         free claimed AND all paid sold) opens the pool immediately,
///         in the completing transaction; otherwise anyone can call
///         finalize() after the deadline — the pool ALWAYS opens from
///         whatever escrow accumulated.
///
///         Owner powers (disclosed, hackathon requirement): the owner can
///         ONLY pause/unpause the sale-phase entry points (claimFree,
///         mint) via setPaused. There is no mint function after deploy,
///         no tax setter, no blacklist, no withdrawal function, and no
///         way to move escrow, user shares, or accrued tax other than
///         the automatic flows described above. LP tokens are minted to
///         the burn address and can never be retrieved.
/// @dev    Self-contained, no imports, so the source verifies as a single file.

interface IAgentIdRegistry {
    function balanceOf(address owner) external view returns (uint256);
}

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakePair {
    function mint(address to) external returns (uint256 liquidity);
}

interface IPancakeRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IWBNB {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

contract AugentToken {
    // ------------------------------------------------------------------ ERC-20
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------- launch data
    address public immutable owner;
    address public immutable treasury;
    IAgentIdRegistry public immutable agentIdRegistry;

    uint256 public immutable price;             // wei per paid share
    uint256 public immutable freeShares;        // number of free shares (1 per Agent ID wallet)
    uint256 public immutable paidShares;        // number of paid shares for sale
    uint256 public immutable maxPaidPerWallet;  // max PAID shares per wallet (free is extra)
    uint256 public immutable freeTokensPerShare; // tokens for 1 free share (200,000)
    uint256 public immutable paidTokensPerShare; // tokens for 1 paid share (2,000,000)
    uint256 public immutable buyTaxBps;
    uint256 public immutable sellTaxBps;
    uint256 public immutable startedAt;
    uint256 public immutable deadline;

    // Split of every paid purchase, in bps of the purchase cost.
    uint256 public constant ESCROW_BPS = 7500;   // 75% to LP escrow
    uint256 public constant TREASURY_BPS = 1500; // 15% to treasury, paid immediately
    uint256 public constant REFERRAL_BPS = 1000; // 10% to a valid referrer, paid immediately

    // Refund = this percent OF THE ESCROW PORTION of a purchase, i.e.
    // 80% x 75% = 60% of the share price, payable only before the deadline.
    uint256 public constant REFUND_PCT_OF_ESCROW = 80;

    // Auto-swap of accrued tax tokens triggers on a sell once at least
    // this many tax tokens have accumulated in the contract.
    uint256 public constant TAX_SWAP_THRESHOLD = 1_000_000 * 1e18; // 1,000,000 AUGENT

    uint256 public constant TOTAL_SUPPLY = 10_000_000_000 * 1e18; // exactly 10B, enforced in constructor

    address public immutable wbnb;
    address public immutable pancakeFactory;
    address public immutable pancakeRouter;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;

    uint8 public phase; // 1 = sale, 3 = pool open (numbering kept from the v6/v7/v8 template)
    bool public paused;
    address public pair;

    uint256 public sold;        // paid shares sold (net of refunds)
    uint256 public freeClaimed; // free shares claimed (recorded)
    uint256 public raised;      // total wei raised from paid shares (gross, refunds do not reduce it)
    uint256 public escrow;      // wei currently held for the LP seed
    uint256 public taxAccumulated; // tax tokens accrued in this contract, not yet auto-swapped

    mapping(address => bool) public freeClaimedByWallet;
    mapping(address => uint256) public paidSharesOf;
    mapping(address => bool) public tokensClaimed; // post-open token claim done

    uint256 public immutable saleAllocation;   // tokens reserved for share holders (paid + free)
    uint256 public immutable poolAllocation;   // LP-side inventory (30% of supply); seeded proportionally at finalize
    uint256 public immutable reserveAllocation; // referral/ecosystem reserve (balancing figure, ~3%), minted to treasury at deploy
    uint256 public immutable ownerAllocation;  // tokens minted to the treasury at deploy (exactly 1% of supply)

    event FreeClaimed(address indexed user, uint256 tokenAmount);
    event Minted(address indexed user, uint256 shares, uint256 cost);
    event ReferralPaid(address indexed referrer, address indexed buyer, uint256 amount);
    event TreasuryPaid(address indexed treasury, uint256 amount);
    event Refunded(address indexed user, uint256 shares, uint256 amount);
    event TokensClaimed(address indexed user, uint256 tokenAmount);
    event TaxSwapped(uint256 tokensIn, uint256 bnbToTreasury);
    event TaxSwapFailed(uint256 tokensIn);
    event PoolOpened(address indexed pair, uint256 bnbSeeded, uint256 tokensSeeded, uint256 tokensBurned);
    event Finalized(address indexed pair, uint256 bnbSeeded, uint256 tokensSeeded, uint256 tokensBurned);
    event PhaseChanged(uint8 phase);

    error NoAgentId();
    error AlreadyClaimed();
    error FreeSoldOut();
    error SoldOutError();
    error BadQuantity();
    error QuotaExceeded();
    error WrongPhase();
    error AfterDeadline();
    error BeforeDeadline();
    error TradingLocked();
    error PausedError();
    error NotOwner();
    error NothingToClaim();
    error NothingToRefund();
    error TokensAlreadyClaimed();
    error TransferFailed();

    bool private _entered;
    modifier nonReentrant() {
        require(!_entered, "REENTRANCY");
        _entered = true;
        _;
        _entered = false;
    }
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    bool private _inTaxSwap;

    /// @param _agentIdRegistry   SPACE ID Agent ID registry, BSC mainnet:
    ///                           0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
    /// @param _wbnb              mainnet BSC: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c
    /// @param _pancakeFactory    mainnet BSC: 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73
    /// @param _pancakeRouter     PancakeSwap V2 Router02, mainnet BSC:
    ///                           0x10ED43C718714eb63d5aA57B78B54704E256024E
    /// @param _poolTokens        LP-side inventory, exactly 3,000,000,000
    ///                           tokens (30% of the 10B supply).
    /// @param _reserveTokens     referral/ecosystem reserve, exactly
    ///                           300,200,000 tokens — the balancing figure
    ///                           that makes the buckets sum to exactly 10B.
    /// @param _ownerTokens       owner allocation, exactly 100,000,000
    ///                           tokens = exactly 1% of the total supply.
    ///                           The constructor rejects any combination
    ///                           whose buckets do not sum to TOTAL_SUPPLY.
    constructor(
        string memory _name,
        string memory _symbol,
        address _agentIdRegistry,
        address _wbnb,
        address _pancakeFactory,
        address _pancakeRouter,
        uint256 _priceWeiPerShare,
        uint256 _freeShares,
        uint256 _paidShares,
        uint256 _maxPaidPerWallet,
        uint256 _freeTokensPerShare,
        uint256 _paidTokensPerShare,
        uint256 _buyTaxBps,
        uint256 _sellTaxBps,
        uint256 _saleDurationSeconds,
        uint256 _poolTokens,
        uint256 _reserveTokens,
        uint256 _ownerTokens,
        address _owner,
        address _treasury
    ) {
        name = _name;
        symbol = _symbol;
        owner = _owner;
        treasury = _treasury;
        agentIdRegistry = IAgentIdRegistry(_agentIdRegistry);
        wbnb = _wbnb;
        pancakeFactory = _pancakeFactory;
        pancakeRouter = _pancakeRouter;

        price = _priceWeiPerShare;
        freeShares = _freeShares;
        paidShares = _paidShares;
        maxPaidPerWallet = _maxPaidPerWallet;
        freeTokensPerShare = _freeTokensPerShare;
        paidTokensPerShare = _paidTokensPerShare;
        buyTaxBps = _buyTaxBps;
        sellTaxBps = _sellTaxBps;
        startedAt = block.timestamp;
        deadline = block.timestamp + _saleDurationSeconds;

        saleAllocation = _freeShares * _freeTokensPerShare + _paidShares * _paidTokensPerShare;
        poolAllocation = _poolTokens;
        reserveAllocation = _reserveTokens;
        ownerAllocation = _ownerTokens;
        // The four buckets must sum to exactly the 10B total supply, and
        // the owner allocation must be exactly 1% of it.
        require(saleAllocation + poolAllocation + reserveAllocation + ownerAllocation == TOTAL_SUPPLY, "SUPPLY_MISMATCH");
        require(_ownerTokens == TOTAL_SUPPLY / 100, "OWNER_NOT_1PCT");

        totalSupply = TOTAL_SUPPLY;
        balanceOf[address(this)] = saleAllocation + poolAllocation;
        balanceOf[treasury] = ownerAllocation + reserveAllocation;
        emit Transfer(address(0), address(this), saleAllocation + poolAllocation);
        emit Transfer(address(0), treasury, ownerAllocation);
        emit Transfer(address(0), treasury, reserveAllocation);

        phase = 1;
        emit PhaseChanged(1);
    }

    // ------------------------------------------------------------------- views
    /// @notice Total shares in the sale (free + paid): 5,999 for AUGENT.
    function maxShares() public view returns (uint256) {
        return freeShares + paidShares;
    }

    /// @notice Alias kept for site/template compatibility: the per-wallet cap
    ///         figure sites display; in this model it is the PAID cap (10),
    ///         the free share is on top of it.
    function maxPerWallet() public view returns (uint256) {
        return maxPaidPerWallet;
    }

    /// @notice Alias kept for site/template compatibility: tokens per PAID share.
    function tokensPerShare() public view returns (uint256) {
        return paidTokensPerShare;
    }

    /// @notice Alias kept for site/template compatibility: the LP inventory.
    function lpAllocation() public view returns (uint256) {
        return poolAllocation;
    }

    /// @notice Alias kept for site/template compatibility: the sale allocation.
    function publicAllocation() public view returns (uint256) {
        return saleAllocation;
    }

    /// @notice Alias kept for site/template compatibility: the owner allocation.
    function treasuryAllocation() public view returns (uint256) {
        return ownerAllocation;
    }

    function totalSoldShares() public view returns (uint256) {
        return sold + freeClaimed;
    }

    /// @notice Tokens that will be distributed to share holders in total
    ///         (free claimed x 200,000 + paid sold x 2,000,000).
    function distributedTokens() public view returns (uint256) {
        return freeClaimed * freeTokensPerShare + sold * paidTokensPerShare;
    }

    function sharesOf(address user) public view returns (uint256) {
        return paidSharesOf[user] + (freeClaimedByWallet[user] ? 1 : 0);
    }

    /// @notice Tokens `user` can claim once the pool is open (0 after claiming).
    function claimableOf(address user) public view returns (uint256) {
        if (tokensClaimed[user]) return 0;
        uint256 amount = paidSharesOf[user] * paidTokensPerShare;
        if (freeClaimedByWallet[user]) amount += freeTokensPerShare;
        return amount;
    }

    /// @notice BNB refundable for ONE paid share: 80% of the escrow
    ///         portion (75%) of the price = 60% of the price
    ///         (0.0006 BNB at the 0.001 BNB AUGENT price).
    function refundPerShare() public view returns (uint256) {
        return ((price * ESCROW_BPS) / 10000) * REFUND_PCT_OF_ESCROW / 100;
    }

    /// @notice BNB `user` would receive for refunding all their paid
    ///         shares right now (0 once the pool is open or after refund).
    function refundableOf(address user) public view returns (uint256) {
        if (phase != 1) return 0;
        return paidSharesOf[user] * refundPerShare();
    }

    struct Info {
        string name;
        string symbol;
        address treasury;
        address quote;
        bool native;
        address pair;
        uint256 price;
        uint256 maxShares;
        uint256 freeShares;
        uint256 paidShares;
        uint256 maxPerWallet;
        uint256 maxPaidPerWallet;
        uint256 tokensPerShare;
        uint256 freeTokensPerShare;
        uint256 paidTokensPerShare;
        uint256 escrowBps;
        uint256 treasuryBps;
        uint256 referralBps;
        uint256 buyTaxBps;
        uint256 sellTaxBps;
        uint256 startedAt;
        uint256 deadline;
        uint256 sold;
        uint256 freeClaimed;
        uint256 raised;
        uint256 escrow;
        uint8 phase;
        uint256 poolAllocation;
        uint256 reserveAllocation;
        uint256 refundPerShare;
        uint256 taxAccumulated;
    }

    function info() external view returns (Info memory i) {
        i.name = name;
        i.symbol = symbol;
        i.treasury = treasury;
        i.quote = wbnb;
        i.native = true;
        i.pair = pair;
        i.price = price;
        i.maxShares = maxShares();
        i.freeShares = freeShares;
        i.paidShares = paidShares;
        i.maxPerWallet = maxPaidPerWallet;
        i.maxPaidPerWallet = maxPaidPerWallet;
        i.tokensPerShare = paidTokensPerShare;
        i.freeTokensPerShare = freeTokensPerShare;
        i.paidTokensPerShare = paidTokensPerShare;
        i.escrowBps = ESCROW_BPS;
        i.treasuryBps = TREASURY_BPS;
        i.referralBps = REFERRAL_BPS;
        i.buyTaxBps = buyTaxBps;
        i.sellTaxBps = sellTaxBps;
        i.startedAt = startedAt;
        i.deadline = deadline;
        i.sold = sold;
        i.freeClaimed = freeClaimed;
        i.raised = raised;
        i.escrow = escrow;
        i.phase = phase;
        i.poolAllocation = poolAllocation;
        i.reserveAllocation = reserveAllocation;
        i.refundPerShare = refundPerShare();
        i.taxAccumulated = taxAccumulated;
    }

    struct UserInfo {
        bool hasAgentId;
        uint256 remainingPaid;
        bool freeClaimed;
        uint256 paidShares;
        uint256 totalShares;
        uint256 claimable;
        bool tokensClaimed;
        uint256 refundable;
    }

    function userInfo(address user) external view returns (UserInfo memory) {
        bool hasId = _hasAgentId(user);
        uint256 paid = paidSharesOf[user];
        return UserInfo({
            hasAgentId: hasId,
            remainingPaid: !hasId ? 0 : (paid >= maxPaidPerWallet ? 0 : maxPaidPerWallet - paid),
            freeClaimed: freeClaimedByWallet[user],
            paidShares: paid,
            totalShares: sharesOf(user),
            claimable: claimableOf(user),
            tokensClaimed: tokensClaimed[user],
            refundable: refundableOf(user)
        });
    }

    function _hasAgentId(address user) internal view returns (bool) {
        return agentIdRegistry.balanceOf(user) > 0;
    }

    /// @dev v9 spec section 4.2: a referrer is valid iff it holds an Agent
    ///      ID, is not the buyer and is not the zero address. The buyer
    ///      necessarily holds an Agent ID too, because _mint enforces it
    ///      before this check is reached.
    function _isValidReferrer(address buyer, address referrer) internal view returns (bool) {
        if (referrer == address(0) || referrer == buyer) return false;
        return _hasAgentId(referrer);
    }

    function _soldOut() internal view returns (bool) {
        return sold >= paidShares && freeClaimed >= freeShares;
    }

    // -------------------------------------------------------------- sale logic
    /// @notice Record the one free share for an Agent ID wallet, in a single
    ///         on-chain step: the SPACE ID registry is checked directly.
    ///         No voucher, no signature, no backend, no social task.
    ///         The 200,000 tokens are NOT transferred yet; they become
    ///         claimable via claim() once the pool opens.
    function claimFree() external nonReentrant {
        if (paused) revert PausedError();
        if (phase != 1) revert WrongPhase();
        if (block.timestamp > deadline) revert AfterDeadline();
        if (!_hasAgentId(msg.sender)) revert NoAgentId();
        if (freeClaimedByWallet[msg.sender]) revert AlreadyClaimed();
        if (freeClaimed >= freeShares) revert FreeSoldOut();

        freeClaimedByWallet[msg.sender] = true;
        freeClaimed += 1;
        emit FreeClaimed(msg.sender, freeTokensPerShare);
        if (_soldOut()) _openPool();
    }

    /// @notice Buy paid shares at exactly `price` wei each, naming no referrer
    ///         (the referral 10% then goes into the LP escrow).
    function mint(uint256 requested) external payable nonReentrant {
        _mint(requested, address(0));
    }

    /// @notice Buy paid shares at exactly `price` wei each.
    /// @param referrer Optional referrer. It is paid 10% of the cost
    ///        immediately ONLY if it is a valid referrer: an Agent ID
    ///        holder address different from the buyer (the buyer is an
    ///        Agent ID holder by construction of this gated mint).
    ///        Otherwise the 10% goes into the LP escrow instead.
    function mint(uint256 requested, address referrer) external payable nonReentrant {
        _mint(requested, referrer);
    }

    function _mint(uint256 requested, address referrer) internal {
        if (paused) revert PausedError();
        if (phase != 1) revert WrongPhase();
        if (block.timestamp > deadline) revert AfterDeadline();
        if (requested == 0) revert BadQuantity();
        if (!_hasAgentId(msg.sender)) revert NoAgentId();
        if (paidSharesOf[msg.sender] + requested > maxPaidPerWallet) revert QuotaExceeded();
        if (sold + requested > paidShares) revert SoldOutError();
        uint256 cost = requested * price;
        require(msg.value == cost, "EXACT_PAYMENT_REQUIRED");

        paidSharesOf[msg.sender] += requested;
        sold += requested;
        raised += cost;
        emit Minted(msg.sender, requested, cost);

        // Immediate 75 / 15 / 10 split of this purchase. The escrow keeps
        // the remainder (everything not paid out), so the three parts
        // always sum to exactly `cost`, dust included.
        uint256 treasuryCut = (cost * TREASURY_BPS) / 10000;
        uint256 referralCut = (cost * REFERRAL_BPS) / 10000;

        if (treasuryCut > 0) {
            (bool okT, ) = treasury.call{value: treasuryCut}("");
            if (!okT) revert TransferFailed();
            emit TreasuryPaid(treasury, treasuryCut);
        }

        bool referralPaid = false;
        if (referralCut > 0 && _isValidReferrer(msg.sender, referrer)) {
            (bool okR, ) = referrer.call{value: referralCut}("");
            if (okR) {
                referralPaid = true;
                emit ReferralPaid(referrer, msg.sender, referralCut);
            }
            // If the referrer cannot receive (e.g. a reverting contract),
            // the referral slice falls back into the LP escrow below
            // instead of blocking or losing the buyer's purchase.
        }

        escrow += cost - treasuryCut - (referralPaid ? referralCut : 0);

        if (_soldOut()) _openPool();
    }

    /// @notice Exit ALL of your paid shares before the deadline and get
    ///         back 80% of the escrow portion of your purchases — 60% of
    ///         the price per share (0.0006 BNB at the AUGENT price). The
    ///         other 20% of the escrow portion stays in the escrow for
    ///         the pool; the treasury 15% and any referral 10% were paid
    ///         out at purchase time and are not refundable. Your free
    ///         share (if any) is NOT affected. After refunding you may
    ///         buy again while the sale is still live. Once the deadline
    ///         passes or the pool has opened there is no refund: the pool
    ///         always opens and shares are claimed as tokens via claim().
    function refund() external nonReentrant {
        if (phase != 1) revert WrongPhase();
        if (block.timestamp > deadline) revert AfterDeadline();
        uint256 shares = paidSharesOf[msg.sender];
        if (shares == 0) revert NothingToRefund();
        uint256 amount = shares * refundPerShare();

        paidSharesOf[msg.sender] = 0;
        sold -= shares;
        escrow -= amount;
        emit Refunded(msg.sender, shares, amount);

        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Open the pool. Permissionless. Before the deadline this is
    ///         only possible once the sale is fully sold out (all free
    ///         claimed AND all paid sold); after the deadline ANYONE can
    ///         finalize with whatever was sold — the pool always opens.
    ///         (Refunds exist only before the deadline, as an early exit;
    ///         there is no post-deadline refund phase.)
    function finalize() external nonReentrant {
        if (phase != 1) revert WrongPhase();
        if (!_soldOut() && block.timestamp <= deadline) revert BeforeDeadline();
        _openPool();
    }

    /// @notice Claim the tokens for the shares recorded during the sale:
    ///         200,000 for the free share plus 2,000,000 per paid share.
    ///         Only after the pool has opened; one claim per wallet.
    function claim() external nonReentrant {
        if (phase != 3) revert WrongPhase();
        if (tokensClaimed[msg.sender]) revert TokensAlreadyClaimed();
        uint256 amount = claimableOf(msg.sender);
        if (amount == 0) revert NothingToClaim();
        tokensClaimed[msg.sender] = true;
        balanceOf[address(this)] -= amount;
        balanceOf[msg.sender] += amount;
        emit Transfer(address(this), msg.sender, amount);
        emit TokensClaimed(msg.sender, amount);
    }

    /// @notice The owner's ONLY power: pause/unpause the sale-phase entry
    ///         points (claimFree and mint). It cannot stop claim(),
    ///         finalize(), refund(), transfers, or the tax auto-swap, and
    ///         there is no other owner function in this contract.
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
    }

    // -------------------------------------------------------------- pool open
    function _openPool() internal {
        phase = 3;
        emit PhaseChanged(3);

        uint256 distributed = distributedTokens();
        // LP tokens seeded: the pool allocation scaled by the fraction of
        // the sale allocation that was actually distributed, so the
        // opening price stays consistent with the sale terms at any fill
        // level (the basis contract's proportional approach).
        uint256 lpTokens = distributed == 0 ? 0 : (poolAllocation * distributed) / saleAllocation;
        uint256 lpBnb = escrow;
        escrow = 0;
        // The proportional LP amount is only actually seeded when there is
        // escrow BNB to pair it with; with zero escrow it cannot be seeded
        // and is burned with the rest of the undistributed tokens instead.
        uint256 seeded = (lpBnb > 0 && lpTokens > 0) ? lpTokens : 0;
        uint256 burned = (saleAllocation - distributed) + (poolAllocation - seeded);

        if (burned > 0) {
            balanceOf[address(this)] -= burned;
            balanceOf[BURN] += burned;
            emit Transfer(address(this), BURN, burned);
        }

        if (seeded > 0) {
            pair = IPancakeFactory(pancakeFactory).createPair(address(this), wbnb);
            // Wrap the seed BNB and move both sides into the pair, then mint
            // LP to the burn address: liquidity is locked forever.
            IWBNB(wbnb).deposit{value: lpBnb}();
            require(IWBNB(wbnb).transfer(pair, lpBnb), "WBNB_TRANSFER_FAILED");
            balanceOf[address(this)] -= seeded;
            balanceOf[pair] += seeded;
            emit Transfer(address(this), pair, seeded);
            IPancakePair(pair).mint(BURN);
        }
        // Zero-escrow edge (not a single paid share sold): there is no BNB
        // to seed a pool with, so no pair is created; claims still open and
        // every undistributed / LP-side token is burned above.

        emit PoolOpened(pair, lpBnb, seeded, burned);
        emit Finalized(pair, lpBnb, seeded, burned);
    }

    // --------------------------------------------------------- tax auto-swap
    /// @dev Swap the whole accrued tax balance to BNB via the PancakeSwap
    ///      V2 router, sending the BNB to the treasury. Called from
    ///      _transfer on sells once the threshold is reached. Failures are
    ///      swallowed (the accrued amount is restored and retried on a
    ///      later sell) so a router/pair problem can never brick trading.
    ///      amountOutMin is 0: the accrued amounts are small and this is
    ///      the template family's simplicity-over-MEV-protection choice;
    ///      see the deployment report for the flagged trade-off.
    function _swapTax() internal {
        uint256 amount = taxAccumulated;
        if (amount == 0) return;
        taxAccumulated = 0;
        _inTaxSwap = true;
        allowance[address(this)][pancakeRouter] = type(uint256).max;
        emit Approval(address(this), pancakeRouter, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = wbnb;
        uint256 treasuryBefore = address(treasury).balance;
        try IPancakeRouter(pancakeRouter).swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, path, treasury, block.timestamp
        ) {
            emit TaxSwapped(amount, address(treasury).balance - treasuryBefore);
        } catch {
            taxAccumulated = amount;
            emit TaxSwapFailed(amount);
        }
        _inTaxSwap = false;
    }

    // --------------------------------------------------------------- transfers
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (phase != 3) revert TradingLocked();
        require(balanceOf[from] >= amount, "BALANCE");
        require(to != address(0), "ZERO_TO");

        uint256 tax = 0;
        bool exempt = from == treasury || to == treasury || from == address(this) || to == address(this);
        if (!exempt && pair != address(0)) {
            if (from == pair) {
                tax = (amount * buyTaxBps) / 10000;
            } else if (to == pair) {
                tax = (amount * sellTaxBps) / 10000;
            }
        }

        balanceOf[from] -= amount;
        if (tax > 0) {
            // Tax accrues to this contract for the auto-swap (difference
            // from the basis, which paid the tax to the treasury as tokens).
            balanceOf[address(this)] += tax;
            taxAccumulated += tax;
            emit Transfer(from, address(this), tax);
        }
        balanceOf[to] += amount - tax;
        emit Transfer(from, to, amount - tax);

        // On a sell, once enough tax has accumulated, auto-swap it to BNB
        // for the treasury. Skipped while a swap is already running (the
        // router's own pull of the tax tokens also lands in this function
        // with to == pair) and skipped for the contract's own transfers.
        if (to == pair && from != address(this) && !_inTaxSwap && taxAccumulated >= TAX_SWAP_THRESHOLD) {
            _swapTax();
        }
    }

    receive() external payable {}
}
