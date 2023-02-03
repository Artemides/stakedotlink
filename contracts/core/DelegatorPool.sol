// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.15;

import "./base/RewardsPoolController.sol";
import "./interfaces/IPoolRouter.sol";
import "./interfaces/IStakingAllowance.sol";

/**
 * @title Delegator Pool
 * @notice Allows users to stake allowance tokens and receive a percentage of earned rewards
 */
contract DelegatorPool is RewardsPoolController {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct VestingSchedule {
        uint256 totalAmount;
        uint64 startTimestamp;
        uint64 durationSeconds;
    }

    IERC20Upgradeable public allowanceToken;
    IPoolRouter public poolRouter;
    address public feeCurve; // unused

    mapping(address => VestingSchedule) private vestingSchedules; // unused

    mapping(address => uint256) private lockedBalances;
    mapping(address => uint256) private lockedApprovals;
    mapping(address => bool) public communityPools;
    uint public totalLocked;

    event AllowanceStaked(address indexed user, uint256 amount);
    event AllowanceWithdrawn(address indexed user, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _allowanceToken,
        string memory _dTokenName,
        string memory _dTokenSymbol,
        address[] calldata _vestingAddresses
    ) public reinitializer(2) {
        if (address(allowanceToken) == address(0)) {
            __RewardsPoolController_init(_dTokenName, _dTokenSymbol);
            allowanceToken = IERC20Upgradeable(_allowanceToken);
        } else {
            for (uint i = 0; i < _vestingAddresses.length; i++) {
                address account = _vestingAddresses[i];
                VestingSchedule memory vestingSchedule = vestingSchedules[account];
                lockedBalances[account] += vestingSchedule.totalAmount;
                totalLocked += vestingSchedule.totalAmount;
                delete vestingSchedules[account];
            }
        }
    }

    /**
     * @notice ERC677 implementation to stake allowance or distribute rewards
     * @param _sender of the stake
     * @param _value of the token transfer
     * @param _calldata encoded vesting startTimestamp and durationSeconds if applicable
     **/
    function onTokenTransfer(
        address _sender,
        uint256 _value,
        bytes calldata _calldata
    ) external override {
        require(
            msg.sender == address(allowanceToken) || isTokenSupported(msg.sender),
            "Sender must be allowance or rewards token"
        );

        if (msg.sender == address(allowanceToken)) {
            _stakeAllowance(_sender, _value);
            if (_calldata.length > 1) {
                uint256 lockedAmount = abi.decode(_calldata, (uint256));
                require(_value >= lockedAmount, "Cannot lock more than transferred value");
                lockedBalances[_sender] += lockedAmount;
                totalLocked += lockedAmount;
            }
        } else {
            distributeToken(msg.sender);
        }
    }

    /**
     * @notice receipt tokens within the delegator pool cannot be transferred
     */
    function _transfer(
        address,
        address,
        uint256
    ) internal override {
        revert("Token cannot be transferred");
    }

    /**
     * @notice returns an account's staked amount for use by reward pools
     * controlled by this contract. If rewards are redirected, it returns the sum of the amount
     * staked by all of the accounts that have redirected rewards.
     * @param _account account address
     * @return account's staked amount
     */
    function staked(address _account) external view override returns (uint256) {
        return communityPools[msg.sender] ? super.balanceOf(_account) - lockedBalances[_account] : super.balanceOf(_account);
    }

    /**
     * @notice returns the total staked amount for use by reward pools
     * controlled by this contract
     * @return total staked amount
     */
    function totalStaked() external view override returns (uint256) {
        bool excludeLocked = communityPools[msg.sender];
        return excludeLocked ? totalSupply() - totalLocked : totalSupply();
    }

    /**
     * @notice returns the available balance of an account, taking into account any locked and approved tokens
     * @param _account account address
     * @return available balance
     */
    function availableBalanceOf(address _account) public view returns (uint256) {
        return balanceOf(_account) - lockedBalances[_account] + lockedApprovals[_account];
    }

    /**
     * @notice returns the locked balance for a given account
     * @param _account account address
     * @return locked balance
     */
    function lockedBalanceOf(address _account) public view returns (uint256) {
        return lockedBalances[_account] - lockedApprovals[_account];
    }

    /**
     * @notice returns the approved locked balance for a given account
     * @param _account account address
     * @return approved locked balance
     */
    function approvedLockedBalanceOf(address _account) public view returns (uint256) {
        return lockedApprovals[_account];
    }

    /**
     * @notice withdraws allowance tokens if no pools are in reserve mode
     * @param _amount amount to withdraw
     **/
    function withdrawAllowance(uint _amount) external updateRewards(msg.sender) {
        require(!poolRouter.isReservedMode(), "Allowance cannot be withdrawn when pools are reserved");
        require(availableBalanceOf(msg.sender) >= _amount, "Withdrawal amount exceeds available balance");

        uint unlockedBalance = balanceOf(msg.sender) - lockedBalances[msg.sender];
        if (_amount > unlockedBalance) {
            uint unlockedAmount = _amount - unlockedBalance;
            lockedApprovals[msg.sender] -= unlockedAmount;
            lockedBalances[msg.sender] -= unlockedAmount;
            totalLocked -= unlockedAmount;
        }

        _burn(msg.sender, _amount);
        allowanceToken.safeTransfer(msg.sender, _amount);

        emit AllowanceWithdrawn(msg.sender, _amount);
    }

    /**
     * @notice approves an amount of locked balances to be withdrawn
     * @param _account account to approve locked balance
     * @param _amount account to approve
     */
    function setLockedApproval(address _account, uint _amount) external onlyOwner {
        require(lockedBalances[_account] >= _amount, "Cannot approve more than locked balance");
        lockedApprovals[_account] = _amount;
    }

    /**
     * @notice burns an amount of an accounts locked allowance token
     * @param _account account to burn tokens
     * @param _amount amount of tokens to burn
     */
    function burnLockedBalance(address _account, uint _amount) external onlyOwner {
        require(lockedBalances[_account] >= _amount, "Cannot burn more than locked balance");

        if (lockedApprovals[_account] > 0 && _amount >= lockedApprovals[_account]) {
            delete lockedApprovals[_account];
        } else if (lockedApprovals[_account] > 0) {
            lockedApprovals[_account] -= _amount;
        }
        lockedBalances[_account] -= _amount;
        totalLocked -= _amount;

        _burn(_account, _amount);
        IStakingAllowance(address(allowanceToken)).burn(_amount);
    }

    /**
     * @notice sets the pool router address
     * @param _poolRouter pool router address
     **/
    function setPoolRouter(address _poolRouter) external onlyOwner {
        require(address(poolRouter) == address(0), "pool router already set");
        poolRouter = IPoolRouter(_poolRouter);
    }

    /**
     * @notice sets whether a given token pool is a community pool
     * @param _pool address of token pool
     * @param _isCommunityPool is community pool
     */
    function setCommunityPool(address _pool, bool _isCommunityPool) external onlyOwner {
        require(address(tokenPools[_pool]) != address(0), "Token pool must exist");
        communityPools[address(tokenPools[_pool])] = _isCommunityPool;
    }

    /**
     * @notice stakes allowance tokens
     * @param _sender account to stake for
     * @param _amount amount to stake
     **/
    function _stakeAllowance(address _sender, uint256 _amount) private updateRewards(_sender) {
        _mint(_sender, _amount);
        emit AllowanceStaked(_sender, _amount);
    }
}
