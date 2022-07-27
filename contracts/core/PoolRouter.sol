// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./interfaces/IERC677.sol";
import "./interfaces/IStakingPool.sol";

/**
 * @title PoolRouter
 * @dev Handles staking allowances and acts as a proxy for staking pools
 */
contract PoolRouter is Ownable {
    using SafeERC20 for IERC677;

    enum PoolStatus {
        OPEN,
        DRAINING,
        CLOSED
    }
    address public emergencyWallet;

    IERC677 public allowanceToken;
    mapping(address => uint) public allowanceStakes;

    struct Pool {
        IERC677 token;
        IStakingPool stakingPool;
        bool allowanceRequired;
        PoolStatus status;
        mapping(address => uint) stakedAmounts;
    }
    mapping(bytes32 => Pool) public pools;
    mapping(address => uint16) public poolCountByToken;
    uint public poolCount;

    address[] public tokens;

    event StakeAllowance(address indexed account, uint amount);
    event WithdrawAllowance(address indexed account, uint amount);
    event StakeToken(address indexed token, address indexed pool, address indexed account, uint amount);
    event WithdrawToken(address indexed token, address indexed pool, address indexed account, uint amount);
    event AddPool(address indexed token, address indexed pool);
    event RemovePool(address indexed token, address indexed pool);

    modifier poolExists(address _token, uint _index) {
        require(poolCountByToken[_token] > _index, "Pool does not exist");
        _;
    }

    constructor(address _allowanceToken, address _emergencyWallet) {
        allowanceToken = IERC677(_allowanceToken);
        emergencyWallet = _emergencyWallet;
    }

    /**
     * @dev Returns a list of all supported tokens
     * @return list of tokens
     **/
    function supportedTokens() external view returns (address[] memory) {
        return tokens;
    }

    /**
     * @dev Returns the token stake balance for an account
     * @param _token token to return balance for
     * @param _index index of pool to return balance for
     * @param _account account to return balance for
     * @return account token stake balance
     **/
    function stakedAmount(
        address _token,
        uint16 _index,
        address _account
    ) external view poolExists(_token, _index) returns (uint) {
        return pools[_poolKey(_token, _index)].stakedAmounts[_account];
    }

    /**
     * @dev Returns a list of Pool objects by the token address
     * @param _token token address
     * @return list of pools
     **/
    function poolsByToken(address _token) external view returns (address[] memory) {
        address[] memory stakingPools = new address[](poolCountByToken[_token]);

        for (uint16 i = 0; i < poolCountByToken[_token]; i++) {
            stakingPools[i] = address(pools[_poolKey(_token, i)].stakingPool);
        }

        return stakingPools;
    }

    /**
     * @notice Returns the current status of a pool
     * @param _token pool token
     * @param _index pool index
     */
    function poolStatus(address _token, uint16 _index) external view returns (PoolStatus) {
        return pools[_poolKey(_token, _index)].status;
    }

    /**
     * @dev Fetch a list of all pools
     * @return an array of tokens and an array of staking pools
     **/
    function allPools() external view returns (address[] memory, address[] memory) {
        address[] memory poolTokens = new address[](poolCount);
        address[] memory stakingPools = new address[](poolCount);

        uint index = 0;
        for (uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            for (uint16 j = 0; j < poolCountByToken[token]; j++) {
                poolTokens[index] = token;
                stakingPools[index] = address(pools[_poolKey(token, j)].stakingPool);
                index++;
            }
        }

        return (poolTokens, stakingPools);
    }

    /**
     * @dev ERC677 implementation to receive a token or allowance stake
     * @param _sender of the token transfer
     * @param _value of the token transfer
     **/
    function onTokenTransfer(
        address _sender,
        uint _value,
        bytes calldata _calldata
    ) external {
        require(
            msg.sender == address(allowanceToken) || poolCountByToken[msg.sender] > 0,
            "Only callable by supported tokens"
        );

        if (msg.sender == address(allowanceToken)) {
            allowanceStakes[_sender] += _value;
            emit StakeAllowance(_sender, _value);
            return;
        }

        uint16 index = SafeCast.toUint16(_bytesToUint(_calldata));

        _stake(msg.sender, index, _sender, _value);
    }

    /**
     * @dev stakes tokens in a staking pool
     * @param _token token to stake
     * @param _index index of pool to stake in
     * @param _amount amount to stake
     **/
    function stake(
        address _token,
        uint16 _index,
        uint _amount
    ) external poolExists(_token, _index) {
        IERC677(_token).safeTransferFrom(msg.sender, address(this), _amount);
        _stake(_token, _index, msg.sender, _amount);
    }

    /**
     * @dev withdraws tokens from a staking pool
     * @param _token token to withdraw
     * @param _index pool index
     * @param _amount amount to withdraw
     **/
    function withdraw(
        address _token,
        uint16 _index,
        uint _amount
    ) external poolExists(_token, _index) {
        Pool storage pool = pools[_poolKey(_token, _index)];
        require(pool.status != PoolStatus.CLOSED, "Pool is closed");
        require(pool.stakedAmounts[msg.sender] >= _amount, "Amount exceeds staked balance");

        pool.stakedAmounts[msg.sender] -= _amount;
        pool.stakingPool.withdraw(msg.sender, _amount);

        emit WithdrawToken(_token, address(pool.stakingPool), msg.sender, _amount);
    }

    /**
     * @dev stakes allowance tokens
     * @param _amount amount to stake
     **/
    function stakeAllowance(uint _amount) external {
        IERC677(allowanceToken).safeTransferFrom(msg.sender, address(this), _amount);
        allowanceStakes[msg.sender] += _amount;
        emit StakeAllowance(msg.sender, _amount);
    }

    /**
     * @dev withdraws allowance
     * @param _amount amount to withdraw
     **/
    function withdrawAllowance(uint _amount) external {
        require(_amount <= allowanceStakes[msg.sender], "Cannot withdraw more than staked allowance balance");

        uint allowanceToRemain = allowanceStakes[msg.sender] - _amount;

        for (uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            for (uint16 j = 0; j < poolCountByToken[token]; j++) {
                uint usedAllowance = allowanceInUse(token, j, msg.sender);
                require(usedAllowance <= allowanceToRemain, "Cannot withdraw allowance that is in use");
            }
        }

        allowanceStakes[msg.sender] = allowanceToRemain;
        allowanceToken.safeTransfer(msg.sender, _amount);

        emit WithdrawAllowance(msg.sender, _amount);
    }

    /**
     * @dev calculates the amount of allowance tokens in use for a given staking pool
     * @param _token the token address used by the staking pool
     * @param _index  pool index
     * @param _account the account to check how much allowance in use
     * @return the amount of allowance tokens in use
     **/
    function allowanceInUse(
        address _token,
        uint16 _index,
        address _account
    ) public view poolExists(_token, _index) returns (uint256) {
        Pool storage pool = pools[_poolKey(_token, _index)];
        if (!pool.allowanceRequired) {
            return 0;
        }
        return
            (1e18 * pool.stakedAmounts[_account]) / ((1e18 * pool.stakingPool.maxDeposits()) / allowanceToken.totalSupply());
    }

    /**
     * @dev calculates the amount of allowance tokens required for a given staking amount
     * @param _token the token address used by the staking pool
     * @param _index  pool index
     * @param _amount the amount to query how much allowance is required
     * @return the amount of allowance tokens in use
     **/
    function allowanceRequired(
        address _token,
        uint16 _index,
        uint256 _amount
    ) public view poolExists(_token, _index) returns (uint256) {
        Pool storage pool = pools[_poolKey(_token, _index)];
        if (!pool.allowanceRequired) {
            return 0;
        }
        return (1e18 * _amount) / ((1e18 * pool.stakingPool.maxDeposits()) / allowanceToken.totalSupply());
    }

    /**
     * @dev adds a new token and staking config
     * @param _token staking token to add
     * @param _stakingPool token staking pool
     * @param _allowanceRequired whether the pool requires allowance to stake
     **/
    function addPool(
        address _token,
        address _stakingPool,
        bool _allowanceRequired,
        PoolStatus _status
    ) external onlyOwner {
        poolCount++;
        uint16 tokenPoolCount = poolCountByToken[_token];
        Pool storage pool = pools[_poolKey(_token, tokenPoolCount)];

        poolCountByToken[_token]++;
        if (tokenPoolCount == 0) {
            tokens.push(_token);
        }

        pool.token = IERC677(_token);
        pool.stakingPool = IStakingPool(_stakingPool);
        pool.allowanceRequired = _allowanceRequired;
        pool.status = _status;

        IERC677(_token).safeApprove(_stakingPool, type(uint).max);
        emit AddPool(_token, _stakingPool);
    }

    /**
     * @dev removes an existing pool
     * @param _token staking token
     * @param _index index of pool to remove
     **/
    function removePool(address _token, uint16 _index) external onlyOwner poolExists(_token, _index) {
        Pool storage pool = pools[_poolKey(_token, _index)];
        require(pool.stakingPool.totalSupply() == 0, "Only can remove a pool with no active stake");

        delete pools[_poolKey(_token, _index)];
        poolCountByToken[_token]--;
        poolCount--;

        if (poolCountByToken[_token] == 0) {
            for (uint i = 0; i < tokens.length; i++) {
                if (tokens[i] == _token) {
                    tokens[i] = tokens[tokens.length - 1];
                    tokens.pop();
                    break;
                }
            }
        }

        emit RemovePool(_token, address(pool.stakingPool));
    }

    /**
     * @dev updates a given pool to whether allowance is needed or not
     * @param _token token address for the staking pool
     * @param _index pool index
     * @param _allowanceRequired bool whether allowance is required
     */
    function setAllowanceRequired(
        address _token,
        uint16 _index,
        bool _allowanceRequired
    ) external onlyOwner poolExists(_token, _index) {
        pools[_poolKey(_token, _index)].allowanceRequired = _allowanceRequired;
    }

    /**
     * @notice emergency wallet function to set the pool status
     * @param _token pool token
     * @param _index pool index
     * @param _status pool status
     */
    function setPoolStatus(
        address _token,
        uint16 _index,
        PoolStatus _status
    ) external {
        require((_status == PoolStatus.CLOSED ? emergencyWallet : super.owner()) == msg.sender, "Unauthorised");
        Pool storage pool = pools[_poolKey(_token, _index)];
        pool.status = _status;
    }

    /**
     * @notice transfer ownership of the emergency wallet
     * @param _to the account to transfer to
     */
    function transferEmergencyWallet(address _to) external {
        require(emergencyWallet == msg.sender, "Unauthorised");
        emergencyWallet = _to;
    }

    /**
     * @dev stakes tokens in a staking pool
     * @param _token token to stake
     * @param _index index of pool to stake in
     * @param _account account to stake for
     * @param _amount amount to stake
     **/
    function _stake(
        address _token,
        uint16 _index,
        address _account,
        uint _amount
    ) private {
        Pool storage pool = pools[_poolKey(_token, _index)];
        require(pool.status == PoolStatus.OPEN, "Pool is not open");

        uint requiredAllowance = allowanceRequired(_token, _index, _amount);
        uint usedAllowance = allowanceInUse(_token, _index, _account);
        require((usedAllowance + requiredAllowance) <= allowanceStakes[_account], "Not enough allowance staked");

        pool.stakedAmounts[_account] += _amount;
        pool.stakingPool.stake(_account, _amount);

        emit StakeToken(_token, address(pool.stakingPool), _account, _amount);
    }

    /**
     * @dev returns the pool key hash by token and index
     * @param _token token
     * @param _index pool index
     * @return the hashed pool key
     */
    function _poolKey(address _token, uint16 _index) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(_token, _index));
    }

    /**
     * @dev converts bytes to uint
     * @param _bytes to convert
     * @return uint256 result
     */
    function _bytesToUint(bytes memory _bytes) private pure returns (uint256) {
        uint256 number;
        for (uint i = 0; i < _bytes.length; i++) {
            number = number + uint(uint8(_bytes[i])) * (2**(8 * (_bytes.length - (i + 1))));
        }
        return number;
    }
}
