// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";

import "../base/OperatorController.sol";

/**
 * @title Operator Controller
 * @notice Base controller contract to be inherited from
 */
contract OperatorControllerMock is OperatorController {
    constructor(address _ethStakingStrategy) OperatorController(_ethStakingStrategy, "Validator Token", "VT") {}

    /**
     * @notice Adds a new operator
     * @param _name name of operator
     */
    function addOperator(string calldata _name) external {
        _addOperator(_name);
    }

    /**
     * @notice Adds a set of new validator pubkey/signature pairs for an operator
     * @param _operatorId id of operator
     * @param _quantity number of new pairs to add
     * @param _pubkeys concatenated set of pubkeys to add
     * @param _signatures concatenated set of signatures to add
     */
    function addKeyPairs(
        uint _operatorId,
        uint _quantity,
        bytes calldata _pubkeys,
        bytes calldata _signatures
    ) external {
        _addKeyPairs(_operatorId, _quantity, _pubkeys, _signatures);
    }

    /**
     * @notice Assigns the next set of validators in the queue
     * @param _operatorIds ids of operators that should be assigned validators
     * @param _validatorCounts number of validators to assign each operator
     * @param _totalValidatorCount sum of all entries in _validatorCounts
     * @return keys concatenated list of pubkeys
     * @return signatures concatenated list of signatures
     */
    function assignNextValidators(
        uint[] calldata _operatorIds,
        uint[] calldata _validatorCounts,
        uint _totalValidatorCount
    ) external returns (bytes memory keys, bytes memory signatures) {
        for (uint i = 0; i < _operatorIds.length; i++) {
            uint operatorId = _operatorIds[i];

            operators[operatorId].usedKeyPairs += uint64(_validatorCounts[i]);
            _mint(operators[operatorId].owner, _validatorCounts[i]);
        }
    }

    function reportKeyPairValidation(uint _operatorId, bool _success) external {
        require(operators[_operatorId].keyValidationInProgress, "No key validation in progress");

        if (_success) {
            operators[_operatorId].validatorLimit = operators[_operatorId].totalKeyPairs;
        }
        operators[_operatorId].keyValidationInProgress = false;
    }
}
