// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "./abstracts/Context.sol";
import "./libraries/SafeMath.sol";
import "./interfaces/IBEP20.sol";

contract DevelopmentVault is Context {
	using SafeMath for uint256;

	uint private _lockedUntil;
	uint constant private timeunit = 1 days;
	address private _owner;
	IBEP20 public tokenContract;
	uint256 public immutable slice;

	event DevelopmentVaultWithdraw(address indexed to, uint256 indexed slice);

	modifier onlyOwner() {
		require(_owner == _msgSender(), "DevelopmentVault: caller is not the owner");
		_;
	}

	constructor(address _tokenContract) {
		_owner = _msgSender();
		tokenContract = IBEP20(_tokenContract);
		_lockedUntil = block.timestamp + (730 * timeunit);
		slice = tokenContract.totalSupply().div(200);
	}

	function owner() external view returns (address) {
		return _owner;
	}

	function lockedUntil() external view returns (uint) {
		return _lockedUntil;
	}

	function unlockTokens(address to) external onlyOwner returns (uint) {
		require(to != address(0), "DevelopmentVault: transfer to the zero address");
		require(block.timestamp > _lockedUntil, "DevelopmentVault: Tokens cannot be withdrawn");
		require(tokenContract.balanceOf(address(this)) > 0, "DevelopmentVault: The Vault is empty");
		uint256 numberOfDays = 30;
		if (tokenContract.balanceOf(address(this)) >= slice) {
			emit DevelopmentVaultWithdraw(to, slice);
			tokenContract.transfer(to, slice);
		} else {
			uint256 amount = tokenContract.balanceOf(address(this));
			emit DevelopmentVaultWithdraw(to, amount);
			tokenContract.transfer(to, amount);
		}
		_lockedUntil = block.timestamp + (numberOfDays * timeunit);
		return _lockedUntil;
	}
}