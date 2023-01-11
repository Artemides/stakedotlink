// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.15;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../interfaces/IRewardsPool.sol";
import "../RewardsPool.sol";
import "../tokens/base/ERC677Upgradeable.sol";

/**
 * @title Rewards Pool Controller
 * @notice Acts as a proxy for any number of rewards pools
 */
abstract contract RewardsPoolController is UUPSUpgradeable, OwnableUpgradeable, ERC677Upgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    mapping(address => IRewardsPool) public tokenPools;
    address[] private tokens;

    mapping(address => address) public rewardRedirects;
    mapping(address => uint256) public redirectedStakes;
    mapping(address => address) public redirectApprovals;

    event WithdrawRewards(address indexed account);
    event AddToken(address indexed token, address rewardsPool);
    event RemoveToken(address indexed token, address rewardsPool);

    event RedirectApproval(address indexed approver, address indexed to);
    event RedirectApprovalRevoked(address indexed approver, address indexed from);
    event RewardsRedirected(address indexed from, address indexed to, address indexed by);

    function __RewardsPoolController_init(string memory _derivativeTokenName, string memory _derivativeTokenSymbol)
        public
        onlyInitializing
    {
        __ERC677_init(_derivativeTokenName, _derivativeTokenSymbol, 0);
        __Ownable_init();
        __UUPSUpgradeable_init();
    }

    modifier updateRewards(address _account) {
        _updateRewards(_account);
        _;
    }

    /**
     * @notice returns a list of supported tokens
     * @return list of token addresses
     **/
    function supportedTokens() external view returns (address[] memory) {
        return tokens;
    }

    /**
     * @notice returns true/false to whether a given token is supported
     * @param _token token address
     * @return is token supported
     **/
    function isTokenSupported(address _token) public view returns (bool) {
        return address(tokenPools[_token]) != address(0) ? true : false;
    }

    /**
     * @notice returns balances of supported tokens within the controller
     * @return list of supported tokens
     * @return list of token balances
     **/
    function tokenBalances() external view returns (address[] memory, uint256[] memory) {
        uint256[] memory balances = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            balances[i] = IERC20Upgradeable(tokens[i]).balanceOf(address(this));
        }

        return (tokens, balances);
    }

    /**
     * @notice ERC677 implementation to receive a token distribution
     **/
    function onTokenTransfer(
        address,
        uint256,
        bytes calldata
    ) external virtual {
        if (isTokenSupported(msg.sender)) {
            distributeToken(msg.sender);
        }
    }

    /**
     * @notice returns an account's staked amount for use by reward pools
     * controlled by this contract. If rewards are redirected, it returns the sum of the amount
     * staked by all of the accounts that have redirected rewards.
     * @param _account account address
     * @return account's staked amount
     */
    function staked(address _account) external view virtual returns (uint256) {
        return (rewardRedirects[_account] == address(0) ? balanceOf(_account) : 0) + redirectedStakes[_account];
    }

    /**
     * @notice returns the total staked amount for use by reward pools
     * controlled by this contract
     * @return total staked amount
     */
    function totalStaked() external view virtual returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice returns the address that receives rewards for an account
     * @param _account account address
     * @return rewards receiver address
     */
    function rewardsAddress(address _account) external view returns (address) {
        return rewardRedirects[_account] != address(0) ? rewardRedirects[_account] : _account;
    }

    /**
     * @dev updates the rewards of the sender and previousRedirect, also updates redirected staked amounts
     * if rewards are redirected
     * @param _from account sending from
     * @param _to account sending to
     * @param _amount amount being sent
     */
    function _transfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal virtual override updateRewards(_from) updateRewards(_to) {
        address rewardRedirectFrom = rewardRedirects[_from];
        address rewardRedirectTo = rewardRedirects[_to];

        if (rewardRedirectFrom != address(0)) {
            _updateRewards(rewardRedirectFrom);
            redirectedStakes[rewardRedirectFrom] -= _amount;
        }
        if (rewardRedirectTo != address(0)) {
            _updateRewards(rewardRedirectTo);
            redirectedStakes[rewardRedirectTo] += _amount;
        }

        super._transfer(_from, _to, _amount);
    }

    /**
     * @notice redirect rewards to a specific address. Supports multiple addresses redirecting to the same previousRedirect.
     * To stop redirecting rewards, set _to as the current wallet.
     * @param _to account to redirect rewards to
     */
    function redirectRewards(address _to) external {
        _redirectRewards(msg.sender, _to);
    }

    /**
     * @notice redirect rewards for an account with approval
     * @param _from account to redirect rewards for
     * @param _to account to redirect rewards to
     */
    function redirectRewardsFrom(address _from, address _to) external {
        require(redirectApprovals[_from] == msg.sender, "Approval required to redirect rewards");
        delete (redirectApprovals[_from]);
        _redirectRewards(_from, _to);
    }

    /**
     * @notice approve a reward redirect
     * @param _to account to approve
     */
    function approveRedirect(address _to) external {
        redirectApprovals[msg.sender] = _to;
        emit RedirectApproval(msg.sender, _to);
    }

    /**
     * @notice revoke a redirect approval
     */
    function revokeRedirectApproval() external {
        address revokedFrom = redirectApprovals[msg.sender];
        delete (redirectApprovals[msg.sender]);
        emit RedirectApprovalRevoked(msg.sender, revokedFrom);
    }

    /**
     * @notice distributes token balances to their respective rewards pools
     * @param _tokens list of token addresses
     */
    function distributeTokens(address[] memory _tokens) public {
        for (uint256 i = 0; i < _tokens.length; i++) {
            distributeToken(_tokens[i]);
        }
    }

    /**
     * @notice distributes a token balance to its respective rewards pool
     * @param _token token address
     */
    function distributeToken(address _token) public {
        require(isTokenSupported(_token), "Token not supported");

        IERC20Upgradeable token = IERC20Upgradeable(_token);
        uint256 balance = token.balanceOf(address(this));
        require(balance > 0, "Cannot distribute zero balance");

        token.safeTransfer(address(tokenPools[_token]), balance);
        tokenPools[_token].distributeRewards();
    }

    /**
     * @notice returns a list of withdrawable rewards for an account
     * @param _account account address
     * @return list of withdrawable reward amounts
     **/
    function withdrawableRewards(address _account) external view returns (uint256[] memory) {
        uint256[] memory withdrawable = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            withdrawable[i] = tokenPools[tokens[i]].withdrawableRewards(_account);
        }

        return withdrawable;
    }

    /**
     * @notice withdraws an account's earned rewards for a list of tokens
     * @param _tokens list of token addresses to withdraw rewards from
     **/
    function withdrawRewards(address[] memory _tokens) public {
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenPools[_tokens[i]].withdraw(msg.sender);
        }
        emit WithdrawRewards(msg.sender);
    }

    /**
     * @notice adds a new token
     * @param _token token to add
     * @param _rewardsPool token rewards pool to add
     **/
    function addToken(address _token, address _rewardsPool) public onlyOwner {
        require(!isTokenSupported(_token), "Token is already supported");

        tokenPools[_token] = IRewardsPool(_rewardsPool);
        tokens.push(_token);

        if (IERC20Upgradeable(_token).balanceOf(address(this)) > 0) {
            distributeToken(_token);
        }

        emit AddToken(_token, _rewardsPool);
    }

    /**
     * @notice removes a supported token
     * @param _token address of token
     **/
    function removeToken(address _token) external onlyOwner {
        require(isTokenSupported(_token), "Token is not supported");

        IRewardsPool rewardsPool = tokenPools[_token];
        delete (tokenPools[_token]);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == _token) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                break;
            }
        }

        emit RemoveToken(_token, address(rewardsPool));
    }

    /**
     * @notice redirect rewards to a specific account from an account
     * @param _from account that's redirecting rewards
     * @param _to account to redirect rewards to
     */
    function _redirectRewards(address _from, address _to) internal updateRewards(_from) updateRewards(_to) {
        require(_to != address(0), "Cannot burn rewards");
        require(rewardRedirects[_from] != _to, "Cannot redirect rewards to the same address");
        require(rewardRedirects[_from] == address(0) ? (_from != _to) : true, "Cannot redirect to self");

        uint256 balanceFrom = balanceOf(_from);
        require(balanceFrom > 0, "A balance is required to redirect rewards");

        address previousRedirect = rewardRedirects[_from];
        if (previousRedirect != address(0)) {
            _updateRewards(previousRedirect);
            redirectedStakes[previousRedirect] -= balanceFrom;
        }

        if (_to == _from) {
            delete (rewardRedirects[_from]);
        } else {
            rewardRedirects[_from] = _to;
            redirectedStakes[_to] += balanceFrom;
        }

        emit RewardsRedirected(_from, _to, msg.sender);
    }

    /**
     * @dev triggers a reward update for a given account
     * @param _account account to update rewards for
     */
    function _updateRewards(address _account) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenPools[tokens[i]].updateReward(_account);
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
