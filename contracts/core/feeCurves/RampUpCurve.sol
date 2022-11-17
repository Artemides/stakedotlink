// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@prb/math/contracts/PRBMathUD60x18.sol";

/**
 * @title Ramp Up Curve
 * @notice Sets a fee curve that significantly ramps up when the percentage increases
 */
contract RampUpCurve is Ownable {
    using PRBMathUD60x18 for uint;

    uint public rateConstantA;
    uint public rateConstantB;
    uint public rateConstantC;
    uint public rateConstantD;
    uint public rateConstantE;

    event RateConstantsSet(
        uint _rateConstantA,
        uint _rateConstantB,
        uint _rateConstantC,
        uint _rateConstantD,
        uint _rateConstantE
    );

    constructor(
        uint _rateConstantA,
        uint _rateConstantB,
        uint _rateConstantC,
        uint _rateConstantD,
        uint _rateConstantE
    ) {
        setRateConstants(_rateConstantA, _rateConstantB, _rateConstantC, _rateConstantD, _rateConstantE);
    }

    /**
     * @notice sets the constants used for calculating current rate
     * @param _rateConstantA value to set for rateA
     * @param _rateConstantB value to set for rateB
     * @param _rateConstantC value to set for rateC
     * @param _rateConstantD value to set for rateD
     * @param _rateConstantE value to set for rateE
     **/
    function setRateConstants(
        uint _rateConstantA,
        uint _rateConstantB,
        uint _rateConstantC,
        uint _rateConstantD,
        uint _rateConstantE
    ) public onlyOwner {
        require(_rateConstantA > 0 && _rateConstantB > 0 && _rateConstantC > 0, "Rate constants A, B and C cannot be zero");

        rateConstantA = _rateConstantA;
        rateConstantB = _rateConstantB;
        rateConstantC = _rateConstantC;
        rateConstantD = _rateConstantD;
        rateConstantE = _rateConstantE;

        emit RateConstantsSet(_rateConstantA, _rateConstantB, _rateConstantC, _rateConstantD, _rateConstantE);
    }

    /**
     * @notice calculates the current percentage of rewards that lenders
     * receive and borrowers pay. Fee cap of 95% hardcoded.
     * @dev Equation: y = (A*x/B)^C + x/D + E
     * @return current rate
     **/
    function currentRate(uint _percentage) external view returns (uint) {
        if (_percentage == 0) {
            return rateConstantE * 100;
        }
        uint x = _percentage;
        uint y = x.div(rateConstantB).mul(rateConstantA * 100).powu(rateConstantC);
        if (rateConstantD > 1) {
            y = y + (x * 100).div(rateConstantD).toUint();
        }
        y = y / 1e16 + rateConstantE * 100;

        if (y > 9500) {
            return 9500;
        }
        return y;
    }
}
