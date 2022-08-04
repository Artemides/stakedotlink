// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";

import "./base/OperatorController.sol";
import "./interfaces/IOperatorWhitelist.sol";

/**
 * @title Whitelist Operator Controller
 * @notice Handles whitelisted validator keys and operator rewards distirbution
 */
contract WLOperatorController is OperatorController {
    struct OperatorCache {
        uint id;
        uint usedKeyPairs;
        uint validatorLimit;
        uint validatorCount;
    }

    IOperatorWhitelist public operatorWhitelist;

    uint public batchSize;
    uint public assignmentIndex;
    uint public queueLength;

    constructor(
        address _ethStakingStrategy,
        address _operatorWhitelist,
        uint _batchSize
    ) OperatorController(_ethStakingStrategy, "Whitelisted Validator Token", "wlVT") {
        operatorWhitelist = IOperatorWhitelist(_operatorWhitelist);
        batchSize = _batchSize;
    }

    /**
     * @notice Adds a new operator
     * @param _name name of operator
     */
    function addOperator(string calldata _name) external {
        operatorWhitelist.useWhitelist(msg.sender);
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
    ) external operatorExists(_operatorId) {
        require(msg.sender == operators[_operatorId].owner, "Sender is not operator owner");
        _addKeyPairs(_operatorId, _quantity, _pubkeys, _signatures);
    }

    /**
     * @notice Removes added pubkey/signature pairs from an operator in LIFO order
     * @param _operatorId id of operator
     * @param _quantity number of pairs to remove
     */
    function removeKeyPairs(uint _operatorId, uint _quantity) external operatorExists(_operatorId) {
        require(msg.sender == operators[_operatorId].owner, "Sender is not operator owner");
        require(_quantity > 0, "Quantity must be greater than 0");
        require(_quantity <= operators[_operatorId].totalKeyPairs, "Cannot remove more keys than are added");
        require(
            _quantity <= operators[_operatorId].totalKeyPairs - operators[_operatorId].usedKeyPairs,
            "Cannot remove used key pairs"
        );

        operators[_operatorId].totalKeyPairs -= uint64(_quantity);
        if (operators[_operatorId].validatorLimit > operators[_operatorId].totalKeyPairs) {
            queueLength -= operators[_operatorId].validatorLimit - operators[_operatorId].totalKeyPairs;
            operators[_operatorId].validatorLimit = operators[_operatorId].totalKeyPairs;
        }
    }

    /**
     * @notice Reports the results of key pair validation for an operator
     * @param _operatorId id of operator
     * @param _success whether the pairs are valid
     */
    function reportKeyPairValidation(uint _operatorId, bool _success)
        external
        onlyKeyValidationOracle
        operatorExists(_operatorId)
    {
        require(operators[_operatorId].keyValidationInProgress, "No key validation in progress");

        if (_success) {
            queueLength += operators[_operatorId].totalKeyPairs - operators[_operatorId].validatorLimit;
            operators[_operatorId].validatorLimit = operators[_operatorId].totalKeyPairs;
        }
        operators[_operatorId].keyValidationInProgress = false;
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
    ) external onlyEthStakingStrategy returns (bytes memory keys, bytes memory signatures) {
        require(_operatorIds.length > 0, "Empty operatorIds");
        require(_operatorIds.length == _validatorCounts.length, "Inconsistent operatorIds and validatorCounts length");

        uint _batchSize = batchSize;

        keys = BytesUtils.unsafeAllocateBytes(_totalValidatorCount * PUBKEY_LENGTH);
        signatures = BytesUtils.unsafeAllocateBytes(_totalValidatorCount * SIGNATURE_LENGTH);

        OperatorCache memory lastOperator = OperatorCache(
            assignmentIndex == 0 ? operators.length - 1 : assignmentIndex - 1,
            0,
            0,
            0
        );

        bool[] memory seenOperatorIds = new bool[](operators.length);
        uint totalValidatorCount;
        uint maxBatches;
        uint maxBatchOperatorId;

        for (uint i = 0; i < _operatorIds.length; i++) {
            uint operatorId = _operatorIds[i];

            require(operators[operatorId].active, "Inactive operator");
            require(!seenOperatorIds[operatorId], "Duplicate operator");
            seenOperatorIds[operatorId] = true;

            _updateRewards(operators[operatorId].owner);

            operators[operatorId].usedKeyPairs += uint64(_validatorCounts[i]);
            _mint(operators[operatorId].owner, _validatorCounts[i]);

            OperatorCache memory operator = OperatorCache(
                operatorId,
                operators[operatorId].usedKeyPairs,
                operators[operatorId].validatorLimit,
                _validatorCounts[i]
            );

            require(
                totalValidatorCount + operator.validatorCount <= _totalValidatorCount,
                "Inconsistent total validator count"
            );

            for (uint j = operator.usedKeyPairs - operator.validatorCount; j < operator.usedKeyPairs; j++) {
                (bytes memory key, bytes memory signature) = _loadKeyPair(operatorId, j);
                BytesUtils.copyBytes(key, keys, totalValidatorCount * PUBKEY_LENGTH);
                BytesUtils.copyBytes(signature, signatures, totalValidatorCount * SIGNATURE_LENGTH);
                totalValidatorCount++;
            }

            require(operator.usedKeyPairs <= operator.validatorLimit, "Assigned more keys than validator limit");
            require(
                (operator.validatorCount % _batchSize == 0) || (operator.usedKeyPairs == operator.validatorLimit),
                "Invalid batching"
            );

            // All excluded operators between any 2 successive included operators must be at capacity
            if (operatorId > (lastOperator.id + 1)) {
                for (uint j = lastOperator.id + 1; j < operatorId; j++) {
                    require(
                        operators[j].usedKeyPairs == operators[j].validatorLimit,
                        "1: Validator assignments were skipped"
                    );
                }
            } else if (operatorId < (lastOperator.id + 1)) {
                for (uint j = lastOperator.id + 1; j < operators.length; j++) {
                    require(
                        operators[j].usedKeyPairs == operators[j].validatorLimit,
                        "2: Validator assignments were skipped"
                    );
                }
                for (uint j = 0; j < operatorId; j++) {
                    require(
                        operators[j].usedKeyPairs == operators[j].validatorLimit,
                        "3: Validator assignments were skipped"
                    );
                }
            }

            if (operator.validatorCount > lastOperator.validatorCount) {
                // An operator cannot be assigned more validators than the operator before unless the operator before is at capacity
                require(
                    lastOperator.usedKeyPairs == lastOperator.validatorLimit,
                    "1: Validator assignments incorrectly split"
                );
            } else if (operator.validatorCount < lastOperator.validatorCount) {
                // An operator cannot be assigned greater than a single batch more than the operator after unless the operator
                // after is at capacity
                require(
                    ((lastOperator.validatorCount - operator.validatorCount) <= _batchSize) ||
                        (operator.usedKeyPairs == operator.validatorLimit),
                    "2: Validator assignments incorrectly split"
                );
            }

            uint batches = operator.validatorCount / _batchSize + (operator.validatorCount % _batchSize > 0 ? 1 : 0);
            if (batches >= maxBatches) {
                maxBatches = batches;
                maxBatchOperatorId = operatorId;
            }

            lastOperator = operator;
        }

        require(totalValidatorCount == _totalValidatorCount, "Inconsistent total validator count");

        // If any operator received more than 1 batch, a full loop has occurred - we need to check that every operator
        // between the last one in _operatorIds and assignmentIndex is at capacity
        if (maxBatches > 1) {
            if (lastOperator.id < assignmentIndex) {
                for (uint i = lastOperator.id + 1; i < assignmentIndex; i++) {
                    require(
                        operators[i].usedKeyPairs == operators[i].validatorLimit,
                        "4: Validator assignments were skipped"
                    );
                }
            } else if (lastOperator.id > assignmentIndex) {
                for (uint i = lastOperator.id + 1; i < operators.length; i++) {
                    require(
                        operators[i].usedKeyPairs == operators[i].validatorLimit,
                        "5: Validator assignments were skipped"
                    );
                }
                for (uint i = 0; i < assignmentIndex; i++) {
                    require(
                        operators[i].usedKeyPairs == operators[i].validatorLimit,
                        "6: Validator assignments were skipped"
                    );
                }
            }
        }

        // The next assignmentIndex should be the one right after the operator that received the most batches,
        // the farthest back in the loop
        if (maxBatchOperatorId == operators.length - 1) {
            assignmentIndex = 0;
        } else {
            assignmentIndex = maxBatchOperatorId + 1;
        }

        queueLength -= totalValidatorCount;
    }

    /**
     * @notice Returns the next set of validators to be assigned
     * @param _validatorCount total number of validators to assign
     * @return operatorIds ids of operators that should be assigned validators
     * @return validatorCounts number of validators to assign each operator
     */
    function getNextValidators(uint _validatorCount)
        external
        view
        returns (
            uint[] memory operatorIds,
            uint[] memory validatorCounts,
            uint totalValidatorCount
        )
    {
        uint[] memory validatorCounter = new uint[](operators.length);
        uint[] memory operatorTracker = new uint[](operators.length);
        uint operatorCount;
        uint loopValidatorCount;
        uint index = assignmentIndex;
        uint loopEnd = index == 0 ? operators.length - 1 : index - 1;

        while (true) {
            uint validatorRoom = operators[index].validatorLimit - (operators[index].usedKeyPairs + validatorCounter[index]);
            uint remainingToAssign = _validatorCount - (totalValidatorCount + loopValidatorCount);

            if (validatorRoom > 0 && operators[index].active) {
                if (validatorRoom <= batchSize && validatorRoom <= remainingToAssign) {
                    if (validatorCounter[index] == 0) {
                        operatorTracker[operatorCount] = index;
                        operatorCount++;
                    }
                    validatorCounter[index] += validatorRoom;
                    loopValidatorCount += validatorRoom;
                } else if (batchSize <= remainingToAssign) {
                    if (validatorCounter[index] == 0) {
                        operatorTracker[operatorCount] = index;
                        operatorCount++;
                    }
                    validatorCounter[index] += batchSize;
                    loopValidatorCount += batchSize;
                } else {
                    totalValidatorCount += loopValidatorCount;
                    break;
                }
            }

            if (index == loopEnd) {
                if (loopValidatorCount == 0) {
                    break;
                } else {
                    totalValidatorCount += loopValidatorCount;
                    loopValidatorCount = 0;
                }
            }

            if (index == operators.length - 1) {
                index = 0;
            } else {
                index++;
            }
        }

        if (operatorCount > 0) {
            operatorIds = new uint[](operatorCount);
            validatorCounts = new uint[](operatorCount);

            for (uint i = 0; i < operatorCount; i++) {
                operatorIds[i] = operatorTracker[i];
                validatorCounts[i] = validatorCounter[operatorTracker[i]];
            }
        }
    }

    /**
     * @notice Reports lifetime stopped validators for a list of operators
     * @param _operatorIds list of operator ids to report for
     * @param _stoppedValidators list of lifetime stopped validators for each operator
     */
    function reportStoppedValidators(uint[] calldata _operatorIds, uint[] calldata _stoppedValidators)
        external
        onlyBeaconOracle
    {
        require(_operatorIds.length == _stoppedValidators.length, "Inconsistent list lengths");

        for (uint i = 0; i < _operatorIds.length; i++) {
            uint operatorId = _operatorIds[i];
            require(operatorId < operators.length, "Operator does not exist");
            require(
                _stoppedValidators[i] > operators[operatorId].stoppedValidators,
                "Reported negative or zero stopped validators"
            );
            require(
                (_stoppedValidators[i]) <= operators[operatorId].usedKeyPairs,
                "Reported more stopped validators than active"
            );

            _updateRewards(operators[operatorId].owner);

            uint newlyStoppedValidators = _stoppedValidators[i] - operators[operatorId].stoppedValidators;

            operators[operatorId].stoppedValidators += uint64(newlyStoppedValidators);
            _burn(operators[operatorId].owner, newlyStoppedValidators);
        }
    }

    /**
     * @notice Sets the batch size for validator assignment
     * @param _batchSize new location of operator whitelist
     */
    function setBatchSize(uint _batchSize) external onlyOwner {
        batchSize = _batchSize;
    }

    /**
     * @notice Sets the location of the operator whitelist
     * @param _operatorWhitelist new location of operator whitelist
     */
    function setOperatorWhitelist(address _operatorWhitelist) external onlyOwner {
        operatorWhitelist = IOperatorWhitelist(_operatorWhitelist);
    }
}
