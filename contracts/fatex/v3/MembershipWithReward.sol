// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";

import "../../libraries/RankedArray.sol";

import "./IRewardScheduleV3.sol";
import "./IFateRewardControllerV3.sol";

abstract contract MembershipWithReward is Ownable {
    uint256 constant public POINTS_PER_BLOCK = 0.08e18;

    // The emission scheduler that calculates fate per block over a given period
    IRewardScheduleV3 public emissionSchedule;

    struct MembershipInfo {
        uint256 firstDepositBlock; // set when first deposit
        uint256 lastWithdrawBlock; // set when first deposit, updates whenever withdraws
    }

    mapping(uint256 => bool) public isFatePool;
    mapping(address => bool) public isExcludedAddress;

    // pid => address => membershipInfo
    mapping(uint256 => mapping (address => MembershipInfo)) public userMembershipInfo;

    mapping(uint256 => mapping (address => uint256)) public additionalPoints;

    /// @dev pid => user address => lockedRewards
    mapping(uint256 => mapping (address => uint256)) public userLockedRewards;

    /// @dev data for FateLockedRewardFee
    uint256[] public lockedRewardsPeriodBlocks = [
        30,
        60,
        120,
        3600,
        86400,
        172800,
        259200,
        345600,
        432000,
        518400,
        604800,
        691200,
        777600,
        864000,
        950400,
        1036800,
        1123200,
        1209600,
        1296000,
        1382400,
        1468800,
        1555200
    ];
    uint256[] public lockedRewardsFeePercents = [
        1e18,
        0.98e18,
        0.97e18,
        0.9e18,
        0.8e18,
        0.75e18,
        0.7e18,
        0.65e18,
        0.6e18,
        0.55e18,
        0.5e18,
        0.45e18,
        0.4e18,
        0.35e18,
        0.3e18,
        0.25e18,
        0.2e18,
        0.15e18,
        0.1e18,
        0.03e18,
        0.01e18,
        0.005e18
    ];

    /// @dev data for LPWithdrawFee
    uint256[] public lpWithdrawPeriodBlocks = [
        1,
        8,
        24,
        72,
        336,
        672,
        888
    ];
    uint256[] public lpWithdrawFeePercent = [
        0.18e18,
        0.08e18,
        0.036e18,
        0.0143e18,
        0.0080e18,
        0.0036e18,
        0.0018e18
    ];

    event LockedRewardsDataSet(uint256[] _lockedRewardsPeriodBlocks, uint256[] _lockedRewardsFeePercents);
    event LPWithdrawDataSet(uint256[] _lpWithdrawPeriodBlocks, uint256[] _lpWithdrawFeePercent);
    event ExcludedAddressSet(address _account, bool _status);

    /// @dev set lockedRewardsPeriodBlocks & lockedRewardsFeePercents
    function setLockedRewardsData(
        uint256[] memory _lockedRewardsPeriodBlocks,
        uint256[] memory _lockedRewardsFeePercents
    ) external onlyOwner {
        require(
            _lockedRewardsPeriodBlocks.length > 0 &&
            _lockedRewardsPeriodBlocks.length == _lockedRewardsFeePercents.length,
            "setLockedRewardsData: invalid input data"
        );
        lockedRewardsPeriodBlocks = _lockedRewardsPeriodBlocks;
        lockedRewardsFeePercents = _lockedRewardsFeePercents;

        emit LockedRewardsDataSet(_lockedRewardsPeriodBlocks, _lockedRewardsFeePercents);
    }

    /// @dev set lpWithdrawPeriodBlocks & lpWithdrawFeePercent
    function setLPWithdrawData(
        uint256[] memory _lpWithdrawPeriodBlocks,
        uint256[] memory _lpWithdrawFeePercent
    ) external onlyOwner {
        require(
            _lpWithdrawPeriodBlocks.length == _lpWithdrawFeePercent.length,
            "setLPWithdrawData: not same length"
        );
        lpWithdrawPeriodBlocks = _lpWithdrawPeriodBlocks;
        lpWithdrawFeePercent = _lpWithdrawFeePercent;

        emit LPWithdrawDataSet(_lpWithdrawPeriodBlocks, _lpWithdrawFeePercent);
    }

    /// @dev set FatePool Ids
    function setFatePoolIds(uint256[] memory pids, bool[] memory status) external onlyOwner {
        require(
            pids.length > 0 &&
            pids.length == status.length,
            "setFatePoolIds: invalid pids"
        );
        for (uint i = 0; i < pids.length; i++) {
            isFatePool[pids[i]] = status[i];
        }
    }

    /// @dev set excluded addresses
    function setExcludedAddresses(address[] memory accounts, bool[] memory status) external onlyOwner {
        require(
            accounts.length > 0 &&
            accounts.length == status.length,
            "setExcludedAddresses: invalid data"
        );
        for (uint i = 0; i < accounts.length; i++) {
            isExcludedAddress[accounts[i]] = status[i];
            emit ExcludedAddressSet(accounts[i], status[i]);
        }
    }

    /// @dev calculate Points earned by this user
    function userPoints(uint256 _pid, address _user) external view returns (uint256 points){
        points = _getBlocksOfPeriod(_pid, _user, true) * POINTS_PER_BLOCK + additionalPoints[_pid][_user];
    }

    /// @dev record deposit block
    function _recordDepositBlock(uint256 _pid, address _user) internal {
        if (isFatePool[_pid]) {
            uint256 currentBlockNumber = block.number;
            require(
                currentBlockNumber <= emissionSchedule.epochEndBlock(),
                "_recordDepositBlock: epoch ended"
            );

            if (userMembershipInfo[_pid][_user].firstDepositBlock == 0) {
                // record deposit block number
                userMembershipInfo[_pid][_user] = MembershipInfo({
                    firstDepositBlock: currentBlockNumber,
                    lastWithdrawBlock: currentBlockNumber
                });
            }
        }
    }

    /// @dev calculate index of LockedRewardFee data
    function _getPercentFromBlocks(
        uint256 periodBlocks,
        uint256[] memory blocks,
        uint256[] memory percents
    ) internal pure returns(uint256 percent) {
        if (periodBlocks <= blocks[0]) {
            percent = percents[0];
        } else if (periodBlocks > blocks[blocks.length - 1]) {
            percent = percents[percents.length - 1];
        } else {
            for (uint i = 0; i < blocks.length - 1; i++) {
                if (
                    periodBlocks > blocks[i] &&
                    periodBlocks <= blocks[i + 1]
                ) {
                    percent = percents[i];
                }
            }
        }
    }

    function _getBlocksOfPeriod(
        uint256 _pid,
        address _user,
        bool _isDepositPeriod
    ) internal view returns (uint256 blocks) {
        if (isFatePool[_pid]) {
            uint256 currentBlockNumber = block.number;
            uint256 epochEndBlock = emissionSchedule.epochEndBlock();
            uint256 endBlock = currentBlockNumber > epochEndBlock ? epochEndBlock : currentBlockNumber;

            MembershipInfo memory membership = userMembershipInfo[_pid][_user];
            uint256 startBlock = _isDepositPeriod ?
                membership.firstDepositBlock : membership.lastWithdrawBlock;

            if (startBlock == 0) {
                blocks = 0;
            } else if (endBlock >= startBlock) {
                blocks = endBlock - startBlock;
            }
        }
    }

    /// @dev calculate percent of lockedRewardFee based on their deposit period
    /// when withdraw during epoch, this fee will be reduced from member's lockedRewards
    /// this fee does not work for excluded address and after epoch is ended
    function _getLockedRewardsFeePercent(
        uint256 _pid,
        address _caller
    ) internal view returns(uint256 percent) {
        if (
            isExcludedAddress[_caller] ||
            block.number >= emissionSchedule.epochEndBlock()
        ) {
            percent = 0;
        } else {
            percent = _getPercentFromBlocks(
                _getBlocksOfPeriod(
                    _pid,
                    _caller,
                    true
                ),
                lockedRewardsPeriodBlocks,
                lockedRewardsFeePercents
            );
        }
    }

    /// @dev calculate percent of lpWithdrawFee based on their deposit period
    /// when users withdaw during epoch, this fee will be reduced from their withdrawAmount
    /// this fee will be still stored on FateRewardControllerV3 contract
    /// this fee does not work for excluded address and after epoch is ended
    function _getLPWithdrawFeePercent(
        uint256 _pid,
        address _caller
    ) internal view returns(uint256 percent) {
        if (
            isExcludedAddress[_caller] ||
            block.number >= emissionSchedule.epochEndBlock()
        ) {
            percent = 0;
        } else {
            percent = _getPercentFromBlocks(
                _getBlocksOfPeriod(
                    _pid,
                    _caller,
                    false
                ),
                lpWithdrawPeriodBlocks,
                lpWithdrawFeePercent
            );
        }
    }
}
