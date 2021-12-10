// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IRewardScheduleV3 {

    function getFatePerBlock(
        uint _startBlock,
        uint _fromBlock,
        uint _toBlock
    )
    external
    view
    returns (uint lockedFatePerBlock, uint unlockedFatePerBlock);


    function calculateCurrentIndex(
        uint _startBlock
    )
    external
    view
    returns (uint);

    function epochStartBlock() external view returns (uint);
    function epochEndBlock() external view returns (uint);
    function lockedPercent() external view returns (uint);
}