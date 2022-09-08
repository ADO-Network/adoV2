// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "./abstracts/Context.sol";
import "./libraries/SafeMath.sol";
import "./AdoToken.sol";
import "./DividendTracker.sol";

contract AdoVault is Context {
	using SafeMath for uint256;
	address private _owner;
	AdoToken public tokenContract;
	DividendTracker public dividendContract;
	uint256 public immutable slice;
	uint256 public pendingMilestone;

	event VaultWithdraw(address indexed to, uint256 indexed slice, uint256 indexed milestone);

	modifier onlyOwner() {
		require(_owner == _msgSender(), "Vault: caller is not the owner");
		_;
	}

	constructor(AdoToken _tokenContract, DividendTracker _dividendContract) {
		_owner = _msgSender();
		tokenContract = _tokenContract;
		dividendContract = _dividendContract;
		slice = tokenContract.totalSupply().div(20);
		pendingMilestone = dividendContract.MILESTONE4();
	}

	function owner() external view returns (address) {
		return _owner;
	}

	function unlockSlice(address to) external onlyOwner returns (uint256) {
		require(to != address(0), "Vault: transfer to the zero address");
		require(tokenContract.balanceOf(address(this)) >= slice, "Vault: insufficient funds");
		require(dividendContract.lastMilestoneReached() >= pendingMilestone, "Vault: no eligible milestone has been reached");

		if (dividendContract.lastMilestoneReached() >= dividendContract.MILESTONE4() && pendingMilestone == dividendContract.MILESTONE4()) {
			tokenContract.transfer(to, slice);
			pendingMilestone = dividendContract.MILESTONE5();
			emit VaultWithdraw(to, slice, dividendContract.MILESTONE4());
			return slice;
		}

		if (dividendContract.lastMilestoneReached() >= dividendContract.MILESTONE5() && pendingMilestone == dividendContract.MILESTONE5()) {
			tokenContract.transfer(to, slice);
			pendingMilestone = dividendContract.MILESTONE6();
			emit VaultWithdraw(to, slice, dividendContract.MILESTONE5());
			return slice;
		}

		if (dividendContract.lastMilestoneReached() >= dividendContract.MILESTONE6() && pendingMilestone == dividendContract.MILESTONE6()) {
			tokenContract.transfer(to, slice);
			pendingMilestone = dividendContract.MILESTONE7();
			emit VaultWithdraw(to, slice, dividendContract.MILESTONE6());
			return slice;
		}

		if (dividendContract.lastMilestoneReached() >= dividendContract.MILESTONE7() && pendingMilestone == dividendContract.MILESTONE7()) {
			tokenContract.transfer(to, tokenContract.balanceOf(address(this)));
			pendingMilestone = 0;
			emit VaultWithdraw(to, slice, dividendContract.MILESTONE7());
			return slice;
		}
		return 0;
	}
}