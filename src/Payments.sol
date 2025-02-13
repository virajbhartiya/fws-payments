// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Payments is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Account {
        // The address of the account owner.
        address owner;

        // The total amount of funds in the account, including both locked and unlocked funds.
        uint256 funds;

        // The required amount of funds that should be locked in the account. This reflects three components:
        // 1. Fixed lockups from all rails associated with this account.
        // 2. Accumulated rate-based lockups that have been converted to fixed lockups across all rails.
        // 3. Funds reserved for future payments based on current payment rates and lockup periods across all rails.
        uint256 requiredTotalLockedFunds;

        // The total rate at which funds are being locked for this account.
        // This is the sum of all payment rates across all active rails for this account.
        uint256 totalLockupRate;

        // The last epoch when rate-based lockup was accumulated into the `requiredTotalLockedFunds`.
        // Used to calculate the amount of rate-based lockup to convert to fixed lockup.
        uint256 lastRateAccumulationAt;

        // The epoch since which the account has had insufficient funds to cover its lockup.
        // A value of 0 indicates the account has sufficient funds
        uint256 lockupInsufficientSince;
    }

    struct Rail {
        // Indicates whether this rail is currently active.
        // When set to false, the rail is considered "deleted" or inactive.
        bool isActive;

        // The address of the ERC20 token contract used for payments on this rail.
        address token;

        // The address of the payer (client) who will be sending funds through this rail.
        address from;

        // The address of the payee (service provider) who will be receiving funds through this rail.
        address to;

        // The address of the operator (typically a market contract) that manages this rail.
        // The operator has special permissions to modify rail parameters.
        address operator;

        // Optional address of an arbiter that can validate payments before they are processed.
        // If set, this address will be consulted to approve or modify payments before settlement.
        address arbiter;

        // The rate at which funds are transferred from the payer to the payee.
        // Measured in tokens per epoch.
        uint256 paymentRate;

        // The number of epochs into the future for which funds should always be locked.
        // This ensures that the payer has sufficient funds for future payments.
        uint256 lockupPeriod;

        // A fixed amount of funds that are locked in addition to the rate-based lockup.
        // This can be used for upfront payments or as an additional "security deposit".
        uint256 lockupFixed;

        // The last epoch at which this rail was settled.
        // Used to calculate the amount owed since the last settlement.
        uint256 lastSettledAt;
    }

    struct OperatorApproval {
        // Indicates whether the operator is approved to create and modify rails for the payer.
        bool isApproved;

        // Optional address of the arbiter that can validate payments for rails created by this operator.
        // If set to address(0), the operator can assign any arbiter they choose when creating a rail.
        // If set to a non-zero address, it must match the arbiter provided when creating a rail.
        address arbitrer;

        // The maximum total payment rate allowed across all rails created by this operator.
        uint256 maxRate;

        // The maximum amount the operator can spend outside of rate-based payments across all rails.
        // This covers both fixed lockups and one-time payments for all rails managed by this operator.
        uint256 maxFixedLockup;

        // The current total payment rate used by this operator across all rails.
        uint256 rate_used;

        // The current amount used by this operator for fixed lockups and one-time payments across all rails.
        uint256 fixedLockupUsed;
    }

    // Counter for generating unique rail IDs
    uint256 private nextRailId;

    // token => owner => Account
    mapping(address => mapping(address => Account)) public accounts;

    // railId => Rail
    mapping(uint256 => Rail) public rails;

    // token => client => operator => Approval
    mapping(address => mapping(address => mapping(address => OperatorApproval))) public operatorApprovals;

    // client => operator => railIds
    mapping(address => mapping(address => uint256[])) public clientOperatorRails;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier validateRailActive(uint256 railId) {
        require(rails[railId].from != address(0), "Rail does not exist");
        require(rails[railId].isActive, "Rail is inactive");
        _;
    }

    modifier validateRailAccountsExist(uint256 railId) {
        Rail storage rail = rails[railId];
        require(rail.from != address(0), "Rail does not exist");
        require(accounts[rail.token][rail.from].owner != address(0), "From account does not exist");
        require(accounts[rail.token][rail.to].owner != address(0), "To account does not exist");
        _;
    }

    modifier onlyRailOperator(uint256 railId) {
        require(rails[railId].operator == msg.sender, "Only the rail operator can perform this action");
        _;
    }

    modifier onlyAccountOwner(address token) {
        address owner = accounts[token][msg.sender].owner;
        require(owner != address(0), "Account does not exist");
        require(owner == msg.sender, "Not account owner");
        _;
    }

    /// Approves or modifies approval for an operator to create and manage payment rails where the account owner is the payer.
    /// This sets approval limits for new rails and rail modifications going forward.
    /// When reducing approvals, existing rails continue operating under their original
    /// terms.
    /// However, any modifications to existing rails must fit within these new approval limits.
    /// Approval tracking works as follows:
    /// - New rails check against current maxRate/maxBase - rate_used/base_used.
    /// - Rail modifications (e.g. rate increases) also check against these current limits.
    /// - Existing unmodified rails continue with their original terms.
    /// This allows users to reduce exposure while honoring existing commitments.
    /// @param token The ERC20 token address this approval is for
    /// @param operator The operator address being approved to create/modify rails
    /// @param arbiter Optional address that can validate payments before settlement
    /// @param maxRate Maximum rate at which the sum of all rails operated by this operator can pay out
    /// Payments made via rail payment rates count against this limit. Unused rate does not accumulate.
    /// @param maxFixedLockup Maximum amount operator can spend outside of rate-based payments. This covers:
    /// 1) Lockup amounts (sum of rail.rate * rail.lockup_period + rail.lockup_fixed for all operator rails).
    /// 2) One-time payments.
    function approveOperator(
        address token,
        address operator,
        address arbiter,
        uint256 maxRate,
        uint256 maxFixedLockup
    ) external onlyAccountOwner(token) {
        require(token != address(0), "Token address cannot be zero");
        require(operator != address(0), "Operator address cannot be zero");

        OperatorApproval storage approval = operatorApprovals[token][msg.sender][operator];
        approval.arbitrer = arbiter;
        approval.maxRate = maxRate;
        approval.maxFixedLockup = maxFixedLockup;
        approval.isApproved = true;
    }

    // TODO: Debt handling and docs
    function terminateOperator(address operator) external  {
        require(operator != address(0), "operator address invalid");

        uint256[] memory railIds = clientOperatorRails[msg.sender][operator];
        for (uint256 i = 0; i < railIds.length; i++) {
            Rail storage rail = rails[railIds[i]];
            require(rail.from == msg.sender, "Not rail payer");
            if (!rail.isActive) {
                continue;
            }

            settleRail(railIds[i]);

            Account storage account = accounts[rail.token][msg.sender];
            account.requiredTotalLockedFunds -= rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
            account.totalLockupRate -= rail.paymentRate;

            rail.paymentRate = 0;
            rail.lockupFixed = 0;
            rail.lockupPeriod = 0;
            rail.isActive = false;

            OperatorApproval storage approval = operatorApprovals[rail.token][msg.sender][operator];
            approval.maxRate = 0;
            approval.maxFixedLockup = 0;
            approval.isApproved = false;
        }
    }

    // TODO: Debt handling and docs
    function deposit(address token, address to, uint256 amount) external {
        require(token != address(0), "Token address cannot be zero");
        require(to != address(0), "To address cannot be zero");
        require(amount > 0, "Amount must be greater than 0");

        // Create account if it doesn't exist
        Account storage account = accounts[token][to];
        if (account.owner == address(0)) {
            account.owner = to;
        }

        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update account balance
        account.funds += amount;
    }

    /// @notice Allows an account owner to withdraw funds from their account.
    /// @dev This function settles the account's lockup before calculating available funds.
    /// @dev Withdrawal is only possible if the account has sufficient unlocked funds after accounting
    /// for lockup.
    /// @dev The available balance for withdrawal is calculated as:
    ///      max(0, account.funds - account.lockupBase)
    /// @dev If the requested amount exceeds available unlocked funds, the transaction will revert
    /// @param token The address of the ERC20 token to withdraw
    /// @param amount The amount of tokens to withdraw
    function withdraw(address token, uint256 amount) external onlyAccountOwner(token) nonReentrant {
        Account storage acct = accounts[token][msg.sender];

        applyAccumulatedRateLockup(acct);

        uint256 available = acct.funds > acct.requiredTotalLockedFunds
            ? acct.funds - acct.requiredTotalLockedFunds
            : 0;

        require(amount <= available, "Insufficient unlocked funds for withdrawal");
        acct.funds -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // TODO: Should only the operator be allowed to call this ???
    /// @notice Creates a new payment rail between a payer and payee, initiated by an approved operator.
    /// @param token The ERC20 token to use for payments on this rail.
    /// @param from The payer account.
    /// @param to The payee account.
    /// @param operator The account creating and managing this rail, must be pre-approved by the payer.
    /// @param arbiter An optional contract address that can validate payments before settlement,
    /// must match the arbiter approved by the payer during operator approval if set.
    /// @return railId The unique ID of the newly created payment rail.
    function createRail(
        address token,
        address from,
        address to,
        address operator,
        address arbiter
    ) external returns (uint256) {
        require(token != address(0), "Token address cannot be zero");
        require(from != address(0), "From address cannot be zero");
        require(to != address(0), "To address cannot be zero");
        require(operator != address(0), "Operator address cannot be zero");

        OperatorApproval memory approval = operatorApprovals[token][from][operator];
        require(approval.isApproved, "Operator not approved");

        Account storage toAccount = accounts[token][to];
        require(toAccount.owner != address(0), "To account does not exist");
        require(toAccount.funds > 0, "To account has no funds");

        Account storage fromAccount = accounts[token][from];
        require(fromAccount.owner != address(0), "From account does not exist");
        require(fromAccount.funds > 0, "From account has no funds");

        if (approval.arbitrer != address(0)) {
            require(arbiter == approval.arbitrer, "Arbiter mismatch");
        }

        uint256 railId = nextRailId++;

        Rail storage rail = rails[railId];
        rail.token = token;
        rail.from = from;
        rail.to = to;
        rail.operator = operator;
        rail.arbiter = arbiter;
        rail.isActive = true;
        rail.lastSettledAt = block.number;

        clientOperatorRails[from][operator].push(railId);
        return railId;
    }

    // TODO: Debt handling and docs
    function modifyRailLockup(
            uint256 railId,
            uint256 period,
            uint256 fixedLockup
        ) external validateRailActive(railId) validateRailAccountsExist(railId) onlyRailOperator(railId) returns (uint256) {
        Rail storage rail = rails[railId];

        Account storage payer = accounts[rail.token][rail.from];

        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "Operator not approved");

        applyAccumulatedRateLockup(payer);

        // Calculate the change in base lockup
        uint256 oldLockup = rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
        uint256 newLockup = fixedLockup + (rail.paymentRate * period);

        // checks to ensure we don't end up with a negative number after subtraction and this should
        // anyways never happen
        require(approval.fixedLockupUsed >= oldLockup, "fixedLockupUsed cannot be less than oldLockup");
        require(payer.requiredTotalLockedFunds >= oldLockup, "payer lockup requiredTotalLockedFunds cannot be less than oldLockup");

        require(approval.fixedLockupUsed - oldLockup + newLockup <= approval.maxFixedLockup, "Exceeds operator fixedLockup approval");

        approval.fixedLockupUsed = approval.fixedLockupUsed - oldLockup + newLockup;

        // Update payer's lockup
        payer.requiredTotalLockedFunds = payer.requiredTotalLockedFunds - oldLockup + newLockup;

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = fixedLockup;

        // Calculate and return deficit if any
        if (payer.funds < payer.requiredTotalLockedFunds) {
            return payer.requiredTotalLockedFunds - payer.funds;
        }
        return 0;
    }

    // TODO: Debt handling and docs
    function modifyRailPayment(
        uint256 railId,
        uint256 rate,
        uint256 once
    ) external validateRailActive(railId) validateRailAccountsExist(railId) onlyRailOperator(railId) returns (uint256) {
        Rail storage rail = rails[railId];

        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "Operator not approved");

        // Settle the rail before modifying payment
        // This ensures that all past payments are accounted for before changing the rate
        settleRail(railId);

        uint256 oldRate = rail.paymentRate;

        // Check if the new rate exceeds the operator's approval
        require(approval.rate_used >= oldRate, "rate_used cannot be less than oldRate");
        require(approval.rate_used - oldRate + rate <= approval.maxRate, "Exceeds operator rate approval");

        // Update the operator's used rate
        approval.rate_used = approval.rate_used - oldRate + rate;
        // Update rail payment rate
        rail.paymentRate = rate;

        // Handle one-time payment if specified
        if (once > 0) {
            require(approval.fixedLockupUsed + once <= approval.maxFixedLockup, "Exceeds operator fixedLockup approval");
            require(payer.funds >= once, "Insufficient funds for one-time payment");

            payer.funds -= once;
            payee.funds += once;

            // Update operator's used fixedLockup
            approval.fixedLockupUsed += once;
        }

        // Update payer's requiredTotalLockedFunds and totalLockupRate
        payer.requiredTotalLockedFunds = payer.requiredTotalLockedFunds - (oldRate * rail.lockupPeriod) + (rate * rail.lockupPeriod);
        payer.totalLockupRate = payer.totalLockupRate - oldRate + rate;

        return 0; // No deficit as we assumed user has enough funds
    }


    function updateRailArbiter(uint256 railId, address newArbiter) external validateRailActive(railId) onlyRailOperator(railId) {
        Rail storage rail = rails[railId];

        // Update the arbiter
        rail.arbiter = newArbiter;
    }

    // TODO: anybody can call this -> is that okay ?
    function settleRailBatch(uint256[] calldata railId) public {
        for (uint256 i = 0; i < railId.length; i++) {
            settleRail(railId[i]);
        }
    }

    // TODO: anybody can call this -> is that okay ?
    // TODO: Debt handling and docs
    function settleRail(uint256 railId) public validateRailActive(railId) validateRailAccountsExist(railId) {
        Rail storage rail = rails[railId];
        uint256 currentEpoch = block.number;
        uint256 elapsedTime = currentEpoch - rail.lastSettledAt;

        if (elapsedTime == 0) return;

        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        // Apply accumulated rate lockup for payer
        applyAccumulatedRateLockup(payer);

        // Calculate payment amount
        uint256 paymentAmount = rail.paymentRate * elapsedTime;

        // Update balances
        payer.funds -= paymentAmount;
        payee.funds += paymentAmount;

        // Update last settlement time
        rail.lastSettledAt = currentEpoch;

        // Adjust lockup base for payer
        payer.requiredTotalLockedFunds -= paymentAmount;
    }

    // ---- Functions below are all private/internal ----

    /**
     * @dev Applies the accumulated rate-based lockup to the account's base lockup.
     * @notice This function converts the rate-based lockup that has accumulated
     * since the last settlement into a fixed base amount.
     *
     * @dev It updates the `requiredTotalLockedFunds` to include the additional funds that should
     * be locked based on the `totalLockupRate` and the time elapsed since the last settlement.
     * Future lockup needs are handled separately when creating or modifying rails.
     *
     * @param acct The Account struct to apply the accumulated rate lockup for
     */
    function applyAccumulatedRateLockup(Account storage acct) internal {
        uint256 currentEpoch = block.number;

        // Convert rate-based lockup accumulation to fixed base
        acct.requiredTotalLockedFunds += acct.totalLockupRate * (currentEpoch - acct.lastRateAccumulationAt);
        acct.lastRateAccumulationAt = currentEpoch;
    }
}
