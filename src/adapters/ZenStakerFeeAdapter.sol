// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";
import {IZenStaker} from "./ZenStakerAdapter.sol";

/// @notice Fee-aware ZenStaker strategy adapter for Layrs ZEN LPVaults.
/// @dev This is an additive replacement for the first ZenStaker adapter. It
/// keeps the same LPVault-facing IYieldAdapter shape, compounds the LP share
/// of ZEN rewards back into ZenStaker, and routes the protocol share to a
/// treasury without changing audited LPVault/LayrsPool logic.
contract ZenStakerFeeAdapter is Ownable, ReentrancyGuard, IYieldAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOMINATOR = 10_000;

    error ZeroAddress();
    error ZeroAmount();
    error RewardTokenMismatch(address stakeToken, address rewardToken);
    error InvalidRewardToken(address rewardToken);
    error InvalidFee();
    error NoDeposit();
    error UnauthorizedDelegateeManager();

    address public immutable override asset;
    address public immutable rewardToken;
    IZenStaker public immutable zenStaker;
    address public immutable treasury;
    address public immutable delegateeManager;
    uint256 public immutable protocolFeeBps;
    address public delegatee;
    string private _name;

    uint256 public depositId;
    bool public depositCreated;
    uint256 public accountedStaked;
    uint256 public pendingProtocolFees;

    event YieldHarvested(uint256 grossReward, uint256 lpAmount, uint256 protocolAmount);
    event YieldCompounded(uint256 lpAmount, uint256 totalDeployed);
    event YieldCompoundSkipped();
    event ProtocolFeesSwept(uint256 amount, uint256 remainingPending);
    event DelegateeUpdated(address indexed oldDelegatee, address indexed newDelegatee);

    constructor(
        address pool_,
        address zenStaker_,
        address delegatee_,
        address delegateeManager_,
        address treasury_,
        uint256 protocolFeeBps_,
        string memory name_
    ) Ownable(pool_) {
        if (pool_ == address(0)) revert ZeroAddress();
        if (zenStaker_ == address(0)) revert ZeroAddress();
        if (delegatee_ == address(0)) revert ZeroAddress();
        if (delegateeManager_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (protocolFeeBps_ > BPS_DENOMINATOR) revert InvalidFee();

        IZenStaker z = IZenStaker(zenStaker_);
        address stakeToken = z.STAKE_TOKEN();
        address rewards = z.REWARD_TOKEN();
        if (stakeToken == address(0)) revert ZeroAddress();
        if (rewards == address(0)) revert ZeroAddress();
        if (stakeToken != rewards) revert RewardTokenMismatch(stakeToken, rewards);

        asset = stakeToken;
        rewardToken = rewards;
        zenStaker = z;
        delegatee = delegatee_;
        delegateeManager = delegateeManager_;
        treasury = treasury_;
        protocolFeeBps = protocolFeeBps_;
        _name = name_;
    }

    function pool() external view override returns (address) {
        return owner();
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function setDelegatee(address newDelegatee) external nonReentrant {
        if (msg.sender != delegateeManager) revert UnauthorizedDelegateeManager();
        if (newDelegatee == address(0)) revert ZeroAddress();
        address oldDelegatee = delegatee;
        if (depositCreated) {
            zenStaker.alterDelegatee(depositId, newDelegatee);
        }
        delegatee = newDelegatee;
        emit DelegateeUpdated(oldDelegatee, newDelegatee);
    }

    function deposit(uint256 amount) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();

        _compoundBestEffort();

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(address(zenStaker), amount);

        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        if (depositCreated) {
            zenStaker.stakeMore(depositId, amount);
        } else {
            depositId = zenStaker.stake(amount, delegatee, address(this));
            depositCreated = true;
        }
        IERC20(asset).forceApprove(address(zenStaker), 0);

        uint256 accepted = beforeBalance - IERC20(asset).balanceOf(address(this));
        if (accepted == 0) revert ZeroAmount();
        accountedStaked += accepted;

        emit YieldDeposited(accepted, deposited());
    }

    function withdraw(uint256 amount) external override onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!depositCreated) revert NoDeposit();

        _compoundBestEffort();

        uint256 received;
        uint256 availableIdle = _lpIdleBalance();
        if (availableIdle != 0) {
            uint256 fromIdle = availableIdle > amount ? amount : availableIdle;
            IERC20(asset).safeTransfer(owner(), fromIdle);
            received += fromIdle;
            amount -= fromIdle;
        }

        if (amount != 0) {
            uint256 toWithdraw = amount > accountedStaked ? accountedStaked : amount;
            if (toWithdraw != 0) {
                uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
                zenStaker.withdraw(depositId, toWithdraw);
                accountedStaked -= toWithdraw;
                uint256 withdrawn = IERC20(asset).balanceOf(address(this)) - beforeBalance;
                IERC20(asset).safeTransfer(owner(), withdrawn);
                received += withdrawn;
            }
        }

        emit YieldWithdrawn(received, deposited());
    }

    function sync() external view override onlyOwner returns (uint256) {
        return deposited();
    }

    function compound() external nonReentrant returns (uint256 lpCompounded) {
        lpCompounded = _compoundStrict();
    }

    function sweepProtocolFees() external nonReentrant returns (uint256 swept) {
        swept = _sweepProtocolFeesStrict();
    }

    function claimRewards(address rewardToken_, bytes calldata) external override onlyOwner nonReentrant {
        if (rewardToken_ != rewardToken) revert InvalidRewardToken(rewardToken_);
        _compoundStrict();
    }

    function deposited() public view override returns (uint256) {
        return _lpIdleBalance() + accountedStaked;
    }

    function _compoundStrict() internal returns (uint256 lpCompounded) {
        if (!depositCreated) return 0;

        uint256 claimable = zenStaker.unclaimedReward(depositId);
        if (claimable == 0) {
            _sweepProtocolFeesStrict();
            return 0;
        }

        uint256 grossReward = _claimReward();
        if (grossReward == 0) return 0;

        lpCompounded = _accountRewardSplit(grossReward);
        _sweepProtocolFeesBestEffort();
        _restakeLpAmount(lpCompounded);

        emit YieldHarvested(grossReward, lpCompounded, grossReward - lpCompounded);
        emit YieldCompounded(lpCompounded, deposited());
    }

    function _compoundBestEffort() internal returns (uint256 lpCompounded) {
        if (!depositCreated) return 0;

        uint256 claimable;
        try zenStaker.unclaimedReward(depositId) returns (uint256 amount) {
            claimable = amount;
        } catch {
            emit YieldCompoundSkipped();
            return 0;
        }
        if (claimable == 0) {
            _sweepProtocolFeesBestEffort();
            return 0;
        }

        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        try zenStaker.claimReward(depositId) returns (uint256) {
            uint256 grossReward = IERC20(asset).balanceOf(address(this)) - beforeBalance;
            if (grossReward == 0) return 0;
            lpCompounded = _accountRewardSplit(grossReward);
            _sweepProtocolFeesBestEffort();

            uint256 beforeStake = IERC20(asset).balanceOf(address(this));
            IERC20(asset).forceApprove(address(zenStaker), lpCompounded);
            try zenStaker.stakeMore(depositId, lpCompounded) {
                accountedStaked += beforeStake - IERC20(asset).balanceOf(address(this));
                IERC20(asset).forceApprove(address(zenStaker), 0);
                emit YieldHarvested(grossReward, lpCompounded, grossReward - lpCompounded);
                emit YieldCompounded(lpCompounded, deposited());
            } catch {
                IERC20(asset).forceApprove(address(zenStaker), 0);
                emit YieldCompoundSkipped();
                return 0;
            }
        } catch {
            emit YieldCompoundSkipped();
            return 0;
        }
    }

    function _claimReward() internal returns (uint256 grossReward) {
        uint256 beforeBalance = IERC20(asset).balanceOf(address(this));
        zenStaker.claimReward(depositId);
        grossReward = IERC20(asset).balanceOf(address(this)) - beforeBalance;
    }

    function _accountRewardSplit(uint256 grossReward) internal returns (uint256 lpAmount) {
        uint256 protocolAmount = grossReward * protocolFeeBps / BPS_DENOMINATOR;
        if (protocolAmount != 0) pendingProtocolFees += protocolAmount;
        lpAmount = grossReward - protocolAmount;
    }

    function _restakeLpAmount(uint256 amount) internal {
        if (amount == 0) return;

        IERC20(asset).forceApprove(address(zenStaker), amount);
        uint256 beforeStake = IERC20(asset).balanceOf(address(this));
        zenStaker.stakeMore(depositId, amount);
        IERC20(asset).forceApprove(address(zenStaker), 0);
        accountedStaked += beforeStake - IERC20(asset).balanceOf(address(this));
    }

    function _sweepProtocolFeesStrict() internal returns (uint256 swept) {
        swept = _sweepableProtocolFees();
        if (swept == 0) return 0;
        pendingProtocolFees -= swept;
        IERC20(asset).safeTransfer(treasury, swept);
        emit ProtocolFeesSwept(swept, pendingProtocolFees);
    }

    function _sweepProtocolFeesBestEffort() internal returns (uint256 swept) {
        swept = _sweepableProtocolFees();
        if (swept == 0) return 0;

        (bool ok, bytes memory returndata) =
            asset.call(abi.encodeCall(IERC20.transfer, (treasury, swept)));
        if (!ok || (returndata.length != 0 && !abi.decode(returndata, (bool)))) {
            emit YieldCompoundSkipped();
            return 0;
        }

        pendingProtocolFees -= swept;
        emit ProtocolFeesSwept(swept, pendingProtocolFees);
    }

    function _sweepableProtocolFees() internal view returns (uint256) {
        uint256 pending = pendingProtocolFees;
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return pending < balance ? pending : balance;
    }

    function _lpIdleBalance() internal view returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 pending = pendingProtocolFees;
        return idle > pending ? idle - pending : 0;
    }
}
