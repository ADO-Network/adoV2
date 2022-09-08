// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "./abstracts/Context.sol";
import "./libraries/SafeMath.sol";
import "./libraries/SafeMathUint.sol";
import "./libraries/SafeMathInt.sol";
import "./AdoToken.sol";
import "./interfaces/IPancakeSwapV2Router02.sol";

contract DividendTracker is Context {
	using SafeMath for uint256;
	using SafeMathUint for uint256;
	using SafeMathInt for int256;

	IPancakeSwapV2Router02 public pancakeSwapV2Router;

	address private _owner;
	address public referrerLotteryWallet;
	address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
	uint256 private constant MAGNITUDE = 2**128;
	uint256 public constant MILESTONE1 = 5000;
	uint256 public constant MILESTONE2 = 10000;
	uint256 public constant MILESTONE3 = 25000;
	uint256 public constant MILESTONE4 = 50000;
	uint256 public constant MILESTONE5 = 75000;
	uint256 public constant MILESTONE6 = 100000;
	uint256 public constant MILESTONE7 = 150000;
	struct MilestoneDetails { bool active; uint8 burn; }
	struct ReferrerDetails { uint256 transactions; uint256 bonus; uint256 totalValue; uint256 commissions; }
	struct DividendsHolders {
		address[] keys;
		mapping(address => uint) values;
		mapping(address => uint) indexOf;
		mapping(address => bool) active;
	}
	DividendsHolders private _tokenHoldersMap;
	address[] private _referredSwaps;
	uint256 private _totalSupply;
	uint256 private _totalDividendsDistributed;
	uint256 private _magnifiedDividendPerShare;
	uint256 private _minimumTokenBalanceForDividends;
	uint256 private _minimumDividendBalanceToProcess;
	uint256 private _minimumTokenBalanceForLottery;
	uint256 private _lastProcessedIndex;
	uint256 private _claimWait = 600;
	uint256 private _gasForProcessing = 200000;
	uint256 private _lastMilestoneReached;
	uint256 private _unqualified;
	address private _hlWinner;
	address private _rlWinner;
	mapping(address => bool) private _projects;
	mapping(address => int256) private _magnifiedDividendCorrections;
	mapping(address => uint256) private _withdrawnDividends;
	mapping(address => uint256) private _balances;
	mapping(address => bool) private _excludedFromDividends;
	mapping(address => bool) private _excludedFromLottery;
	mapping(address => uint256) private _lastClaimTimes;
	mapping(address => ReferrerDetails) private _referrers;
	mapping(uint256 => MilestoneDetails) private _milestones;
	uint256[] private _milestonesList;
	mapping(uint256 => uint256) private _bonusStructure;
	AdoToken public tokenContract;

	event NewProject(address indexed account);
	event NewMilestone(uint256 indexed milestone);
	event ExcludeFromDividends(address indexed account);
	event ExcludeFromLottery(address indexed account);
	event GasForProcessing(uint256 indexed newValue, uint256 indexed oldValue);
	event MinimumDividendBalanceToProcess(uint256 indexed newValue, uint256 indexed oldValue);
	event ClaimWait(uint256 indexed newValue, uint256 indexed oldValue);
	event Claim(address indexed account, uint256 amount, bool indexed automatic);
	event MinimumTokenBalanceForDividends(uint256 indexed newValue, uint256 indexed oldValue);
	event MinimumTokenBalanceForLottery(uint256 indexed newValue);
	event HoldersLotteryWinner(address indexed account, uint256 indexed milestone, uint256 amount, uint256 burn);
	event ReferrersLotteryWinner(address indexed account);
	event ReferrerLotteryWallet(address indexed newValue, address indexed oldValue);
	event DividendsDistributed(address indexed from, uint256 weiAmount);

	modifier onlyTokenContract() {
		require(_msgSender() == address(tokenContract), "DividendTracker: Only the token contract can call this function");
		_;
	}

	modifier onlyOwner() {
		require(_owner == _msgSender(), "DividendTracker: caller is not the owner");
		_;
	}

	constructor(AdoToken _tokenContract) {
		_owner = _msgSender();
		tokenContract = _tokenContract;
		_projects[address(tokenContract)] = true;
		referrerLotteryWallet = _msgSender();
		_minimumTokenBalanceForDividends = tokenContract.totalSupply().div(100000);
		_excludedFromDividends[address(this)] = true;
		_excludedFromDividends[address(tokenContract)] = true;
		_excludedFromDividends[BURN_ADDRESS] = true;
		_excludedFromDividends[_msgSender()] = true;
		_milestones[MILESTONE1] = MilestoneDetails({ active : true, burn: 5 });
		_milestones[MILESTONE2] = MilestoneDetails({ active : true, burn: 10 });
		_milestones[MILESTONE3] = MilestoneDetails({ active : true, burn: 15 });
		_milestones[MILESTONE4] = MilestoneDetails({ active : true, burn: 20 });
		_milestones[MILESTONE5] = MilestoneDetails({ active : true, burn: 25 });
		_milestones[MILESTONE6] = MilestoneDetails({ active : true, burn: 30 });
		_milestones[MILESTONE7] = MilestoneDetails({ active : true, burn: 35 });
		_milestonesList = [MILESTONE1, MILESTONE2, MILESTONE3, MILESTONE4, MILESTONE5, MILESTONE6, MILESTONE7];
		_bonusStructure[5] = 1;
		_bonusStructure[20] = 2;
		_bonusStructure[50] = 4;
		_bonusStructure[100] = 6;
		_bonusStructure[250] = 9;
	}

	receive() external payable {}

	function totalTokens() external view returns (uint256) {
		return _totalSupply;
	}

	function owner() external view returns (address) {
		return _owner;
	}

	function balanceOf(address account) external view returns (uint256) {
		return _balances[account];
	}

	function holdersLotteryWinner() external view returns (address) {
		return _hlWinner;
	}

	function referrersLotteryWinner() external view returns (address) {
		return _rlWinner;
	}

	function gasForProcessing() external view returns (uint256) {
		return _gasForProcessing;
	}

	function minimumDividendBalanceToProcess() external view returns (uint256) {
		return _minimumDividendBalanceToProcess;
	}

	function lastMilestoneReached() external view returns (uint256) {
		return _lastMilestoneReached;
	}

	function nextMilestone() external view returns (uint256) {
		return _milestonesList.length > 0 ? _milestonesList[0] : 0;
	}

	function maxMilestone() external view returns (uint256) {
		return _milestonesList.length > 0 ? _milestonesList[_milestonesList.length-1] : 0;
	}

	function isProject(address account) external view returns (bool) {
		return _projects[account];
	}

	function referredSwaps() external view returns (uint256 total, uint256 lotterySwaps) {
		total = _unqualified.add(_referredSwaps.length);
		lotterySwaps = _referredSwaps.length;
	}

	function isExcludedFromLottery(address account) external view returns (bool) {
		return _excludedFromLottery[account];
	}

	function isExcludedFromDividends(address account) external view returns (bool) {
		return _excludedFromDividends[account];
	}

	function totalDividendsDistributed() external view returns (uint256) {
		return _totalDividendsDistributed;
	}

	function withdrawableDividendOf(address account) public view returns(uint256) {
		return accumulativeDividendOf(account).sub(_withdrawnDividends[account]);
	}

	function minimumTokenBalanceForDividends() external view returns(uint256) {
		return _minimumTokenBalanceForDividends;
	}

	function minimumTokenBalanceForLottery() external view returns(uint256) {
		return _minimumTokenBalanceForLottery;
	}

	function claimWait() external view returns(uint256) {
		return _claimWait;
	}

	function lastProcessedIndex() external view returns(uint256) {
		return _lastProcessedIndex;
	}

	function dividendsTokenHolders() external view returns(uint256) {
		return _tokenHoldersMap.keys.length;
	}

	function accumulativeDividendOf(address _account) public view returns(uint256) {
		return _magnifiedDividendPerShare.mul(_balances[_account])
			.toInt256Safe()
			.add(_magnifiedDividendCorrections[_account])
			.toUint256Safe() / MAGNITUDE;
	}

	function getReferrer(address account) external view returns (uint256 transactions, uint256 bonus, uint256 totalValue, uint256 commissions, bool excludedFromLottery) {
		transactions = _referrers[account].transactions;
		bonus = _referrers[account].bonus;
		totalValue = _referrers[account].totalValue;
		commissions = _referrers[account].commissions;
		excludedFromLottery = _excludedFromLottery[account];
	}

	function getAccount(address _account) public view returns (address account, int256 index, int256 iterationsUntilProcessed, uint256 withdrawableDividends, uint256 totalDividends, uint256 lastClaimTime, uint256 nextClaimTime, uint256 secondsUntilAutoClaimAvailable) {
		account = _account;
		index = _getIndexOfKey(account);
		iterationsUntilProcessed = -1;

		if (index >= 0) {
			if (uint256(index) > _lastProcessedIndex) {
				iterationsUntilProcessed = index.sub(int256(_lastProcessedIndex));
			} else {
				uint256 processesUntilEndOfArray = _tokenHoldersMap.keys.length > _lastProcessedIndex ? _tokenHoldersMap.keys.length.sub(_lastProcessedIndex) : 0;
				iterationsUntilProcessed = index.add(int256(processesUntilEndOfArray));
			}
		}
		withdrawableDividends = withdrawableDividendOf(account);
		totalDividends = accumulativeDividendOf(account);
		lastClaimTime = _lastClaimTimes[account];
		nextClaimTime = lastClaimTime > 0 ? lastClaimTime.add(_claimWait) : 0;
		secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp ? nextClaimTime.sub(block.timestamp) : 0;
	}

	function getAccountAtIndex(uint256 index) external view returns (address, int256, int256, uint256, uint256, uint256, uint256, uint256) {
		if (index >= _tokenHoldersMap.keys.length) {
			return (address(0), -1, -1, 0, 0, 0, 0, 0);
		}
		address account = _getKeyAtIndex(index);
		return getAccount(account);
	}

	function _removeMilestoneFromList() private {
		if (_milestonesList.length > 1) {
			for (uint i = 0; i < _milestonesList.length-1; i++) {
			_milestonesList[i] = _milestonesList[i+1];
			}
		}
		_milestonesList.pop();
	}

	function _withdrawDividendOfUser(address payable user) private returns (uint256) {
		uint256 _withdrawableDividend = withdrawableDividendOf(user);
		if (_withdrawableDividend > 0) {
			_withdrawnDividends[user] = _withdrawnDividends[user].add(_withdrawableDividend);
			(bool success,) = user.call{value: _withdrawableDividend, gas: 3000}('');
			if (!success) {
				_withdrawnDividends[user] = _withdrawnDividends[user].sub(_withdrawableDividend);
				return 0;
			}
			return _withdrawableDividend;
		}
		return 0;
	}

	function _setBalance(address account, uint256 newBalance) private {
		uint256 currentBalance = _balances[account];
		if (newBalance > currentBalance) {
			uint256 mintAmount = newBalance.sub(currentBalance);
			_mint(account, mintAmount);
		} else if (newBalance < currentBalance) {
			uint256 burnAmount = currentBalance.sub(newBalance);
			_burn(account, burnAmount);
		}
	}

	function _mint(address account, uint256 value) private {
		require(account != address(0), "DividendTracker: mint to the zero address");
		_totalSupply = _totalSupply.add(value);
		_balances[account] = _balances[account].add(value);
		_magnifiedDividendCorrections[account] = _magnifiedDividendCorrections[account]
			.sub((_magnifiedDividendPerShare.mul(value))
			.toInt256Safe());
	}

	function _burn(address account, uint256 value) private {
		require(account != address(0), "DividendTracker: burn from the zero address");
		_balances[account] = _balances[account].sub(value, "DividendTracker: burn amount exceeds balance");
		_totalSupply = _totalSupply.sub(value);
		_magnifiedDividendCorrections[account] = _magnifiedDividendCorrections[account]
			.add((_magnifiedDividendPerShare.mul(value))
			.toInt256Safe());
	}

	function _canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
		if (lastClaimTime > block.timestamp) {
			return false;
		}
		return block.timestamp.sub(lastClaimTime) >= _claimWait;
	}

	function _setHolder(address key, uint val) private {
		if (_tokenHoldersMap.active[key]) {
			_tokenHoldersMap.values[key] = val;
		} else {
			_tokenHoldersMap.active[key] = true;
			_tokenHoldersMap.values[key] = val;
			_tokenHoldersMap.indexOf[key] = _tokenHoldersMap.keys.length;
			_tokenHoldersMap.keys.push(key);
		}
	}

	function _removeHolder(address key) private {
		if (!_tokenHoldersMap.active[key]) {
			return;
		}
		delete _tokenHoldersMap.active[key];
		delete _tokenHoldersMap.values[key];
		uint index = _tokenHoldersMap.indexOf[key];
		uint lastIndex = _tokenHoldersMap.keys.length - 1;
		address lastKey = _tokenHoldersMap.keys[lastIndex];
		_tokenHoldersMap.indexOf[lastKey] = index;
		delete _tokenHoldersMap.indexOf[key];
		_tokenHoldersMap.keys[index] = lastKey;
		_tokenHoldersMap.keys.pop();
	}

	function _processAccount(address payable account, bool automatic) private returns (bool) {
		uint256 amount = _withdrawDividendOfUser(account);
		if (amount > 0) {
			_lastClaimTimes[account] = block.timestamp;
			emit Claim(account, amount, automatic);
			return true;
		}
		return false;
	}

	function _getIndexOfKey(address key) private view returns (int) {
		if(!_tokenHoldersMap.active[key]) {
			return -1;
		}
		return int(_tokenHoldersMap.indexOf[key]);
	}

	function _getKeyAtIndex(uint index) private view returns (address) {
		return _tokenHoldersMap.keys[index];
	}

	function claim() external {
		_processAccount(payable(_msgSender()), false);
	}

	function addToDividends() external payable {
		require(msg.value > 0, "DividendTracker: Transfer amount must be greater than zero");
		_updateDividendsDistributed(msg.value);
	}

	function updateDividendsDistributed(uint256 amount) external {
		require(_projects[_msgSender()] == true, "DividendTracker: Only authorized projects can call this function");
		_updateDividendsDistributed(amount);
	}

	function _updateDividendsDistributed(uint256 amount) private {
		if (_totalSupply > 0 && amount > 0) {
			_magnifiedDividendPerShare = _magnifiedDividendPerShare
				.add((amount)
				.mul(MAGNITUDE) / _totalSupply);
			emit DividendsDistributed(_msgSender(), amount);
			_totalDividendsDistributed = _totalDividendsDistributed.add(amount);
		}
	}

	function excludeFromDividends(address account) external onlyTokenContract {
		require(!_excludedFromDividends[account]);
		_excludeFromDividends(account);
	}

	function _excludeFromDividends(address account) private {
		require(!_excludedFromDividends[account]);
		_excludedFromDividends[account] = true;
		_setBalance(account, 0);
		_removeHolder(account);
		emit ExcludeFromDividends(account);
	}

	function excludeMeFromLottery() external {
		require(!_excludedFromLottery[_msgSender()]);
		_excludedFromLottery[_msgSender()] = true;
		emit ExcludeFromLottery(_msgSender());
	}

	function excludeFromLottery(address account) external onlyTokenContract {
		require(!_excludedFromLottery[account]);
		_excludedFromLottery[account] = true;
		emit ExcludeFromLottery(account);
	}

	function payCommission(address referrer, uint256 amount) external onlyTokenContract {
		if (amount >= _minimumTokenBalanceForDividends) {
			_referrers[referrer].transactions = _referrers[referrer].transactions.add(1);
			uint256 commission = 1;
			if (_bonusStructure[_referrers[referrer].transactions] > _referrers[referrer].bonus) {
				_referrers[referrer].bonus = _bonusStructure[_referrers[referrer].transactions];
			}
			_referrers[referrer].totalValue = _referrers[referrer].totalValue.add(amount);
			commission = commission.add(_referrers[referrer].bonus);
			uint256 commissionValue = amount.div(100).mul(commission);
			_referrers[referrer].commissions = _referrers[referrer].commissions.add(commissionValue);
			tokenContract.transfer(referrer, commissionValue);
			if (!_excludedFromLottery[referrer] && _referrers[referrer].transactions >= 5) {
				_referredSwaps.push(referrer);
			} else {
				_unqualified++;
			}
		}
	}

	function updateReferrerLotteryWallet(address wallet) external onlyOwner returns (bool) {
		require(wallet != address(0), "DividendTracker: ReferrerLotteryWallet cannot be the zero address");
		emit ReferrerLotteryWallet(wallet, referrerLotteryWallet);
		referrerLotteryWallet = wallet;
		return true;
	}

	function updateMinimumDividendBalanceToProcess(uint256 newValue) external onlyOwner returns (bool) {
		require(newValue <= 10 * 10 ** 18, "Token: MinimumDividendBalanceToProcess must be between 0 and 10 BNB");
		emit MinimumDividendBalanceToProcess(newValue, _minimumDividendBalanceToProcess);
		_minimumDividendBalanceToProcess = newValue;
		return true;
	}

	function updateGasForProcessing(uint256 newValue) external onlyOwner returns (bool) {
		require(newValue >= 150000 && newValue <= 500000, "DividendTracker: gasForProcessing must be between 100,000 and 500,000");
		emit GasForProcessing(newValue, _gasForProcessing);
		_gasForProcessing = newValue;
		return true;
	}

	function updateMinimumTokenBalanceForDividends(uint256 newValue) external onlyOwner {
		require(newValue >= 10 ** 18 && newValue <= 100000 * 10 ** 18, "DividendTracker: numTokensToLiqudate must be between 1 and 100.000 ADO");
		emit MinimumTokenBalanceForDividends(_minimumTokenBalanceForDividends, newValue);
		_minimumTokenBalanceForDividends = newValue;
	}

	function updateClaimWait(uint256 newClaimWait) external onlyOwner {
		require(newClaimWait >= 600 && newClaimWait <= 86400, "DividendTracker: claimWait must be between 1 and 24 hours");
		emit ClaimWait(newClaimWait, _claimWait);
		_claimWait = newClaimWait;
	}

	function setBalance(address payable account, uint256 newBalance, bool keep) external onlyTokenContract {
		if (_excludedFromDividends[account]) {
			return;
		}
		if (newBalance >= _minimumTokenBalanceForDividends || (_tokenHoldersMap.active[account] && keep)) {
			_setBalance(account, newBalance);
			_setHolder(account, newBalance);
		} else {
			_setBalance(account, 0);
			_removeHolder(account);
		}
		_processAccount(account, true);
	}

	function process() external onlyTokenContract returns (uint256, uint256, uint256) {
		uint256 gas = _gasForProcessing;
		uint256 numberOfTokenHolders = _tokenHoldersMap.keys.length;
		if (numberOfTokenHolders == 0) {
			return (0, 0, _lastProcessedIndex);
		}
		uint256 lpi = _lastProcessedIndex;
		uint256 gasUsed = 0;
		uint256 gasLeft = gasleft();
		uint256 iterations = 0;
		uint256 claims = 0;
		while (gasUsed < gas && iterations < numberOfTokenHolders) {
			lpi++;
			if (lpi >= _tokenHoldersMap.keys.length) {
				lpi = 0;
			}
			address account = _tokenHoldersMap.keys[lpi];
			if (_canAutoClaim(_lastClaimTimes[account])) {
				if (_processAccount(payable(account), true)) {
					claims++;
				}
			}
			iterations++;
			uint256 newGasLeft = gasleft();
			if (gasLeft > newGasLeft) {
				gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
			}
			gasLeft = newGasLeft;
		}
		_lastProcessedIndex = lpi;
		return (iterations, claims, _lastProcessedIndex);
	}

	function addNewProject(address account) external onlyOwner {
		require(!_projects[account], "DividendTracker: Smart Contract already added");
		require(account.code.length > 0, "DividendTracker: Only Smart Contracts can be added as projects");
		emit NewProject(account);
		_projects[account] = true;
	}

	function addNewMilestone(uint256 milestone) external onlyOwner {
		require(milestone > _milestonesList[_milestonesList.length-1], "DividendTracker: The new milestone cannot be smaller than the existing ones");
		_milestonesList.push(milestone);
		_milestones[milestone] = MilestoneDetails({ active : true, burn: 0 });
		emit NewMilestone(milestone);
	}

	function holdersLotteryDraw() external onlyOwner returns (address) {
		require(_milestonesList.length > 0, "DividendTracker: There are no active milestones");
		uint256 milestone = _milestonesList[0];
		require(_milestones[milestone].active, "DividendTracker: This milestone is not active");
		uint256 holders = _tokenHoldersMap.keys.length;
		require(holders >= milestone, "DividendTracker: Insufficient holders to activate this milestone");
		uint256 randomIndex = (uint(keccak256(abi.encodePacked(block.difficulty, block.timestamp, _totalSupply, _magnifiedDividendPerShare, milestone, _msgSender()))) % holders);
		require(!_excludedFromLottery[_tokenHoldersMap.keys[randomIndex]], "DividendTracker: Excluded from lottery");
		require(tokenContract.balanceOf(_tokenHoldersMap.keys[randomIndex]) >= _minimumTokenBalanceForLottery, "DividendTracker: Insufficient tokens");
		(uint256 hlf,,,) = tokenContract.funds();
		bool success = tokenContract.payTheWinner(_tokenHoldersMap.keys[randomIndex]);
		if (success) {
			_hlWinner = _tokenHoldersMap.keys[randomIndex];
			_lastMilestoneReached = milestone;
			_removeMilestoneFromList();
			_milestones[milestone].active = false;
			uint256 toBurn = 0;
			if (_milestones[milestone].burn > 0) {
				toBurn = tokenContract.balanceOf(address(this))
					.div(100)
					.mul(_milestones[milestone].burn);
				tokenContract.transfer(BURN_ADDRESS, toBurn);
			}
			emit HoldersLotteryWinner(_hlWinner, milestone, hlf, toBurn);
		}
		return _hlWinner;
	}

	function referrersLotteryDraw() external onlyOwner returns (address) {
		uint256 referrers = _referredSwaps.length;
		uint256 randomIndex = (uint(keccak256(abi.encodePacked(block.difficulty, block.timestamp, _totalSupply, _magnifiedDividendPerShare, _tokenHoldersMap.keys.length, address(this).balance, _msgSender()))) % referrers);
		require(!_excludedFromLottery[_referredSwaps[randomIndex]], "DividendTracker: Excluded from lottery");
		bool success = tokenContract.referrersLotteryFundWithdrawal(referrerLotteryWallet);
		if (success) {
			_rlWinner = _referredSwaps[randomIndex];
			emit ReferrersLotteryWinner(_rlWinner);
		}
		return _rlWinner;
	}

	function updateMinimumTokensForLottery() external onlyOwner returns (bool) {
		if (address(pancakeSwapV2Router) == address(0)) {
			pancakeSwapV2Router = tokenContract.pancakeSwapV2Router();
		}
		uint256 amount = 0;
		address[] memory path = new address[](2);
		if (tokenContract.mainLPToken() == pancakeSwapV2Router.WETH()) {
			path[0] = address(tokenContract.busdContract());
			path[1] = pancakeSwapV2Router.WETH();
			uint256 ethPrice = pancakeSwapV2Router.getAmountsOut(10**20, path)[1];
			path[0] = pancakeSwapV2Router.WETH();
			path[1] = address(tokenContract);
			amount = pancakeSwapV2Router.getAmountsOut(ethPrice, path)[1];
		} else {
			path[0] = address(tokenContract.busdContract());
			path[1] = address(tokenContract);
			amount = pancakeSwapV2Router.getAmountsOut(10**20, path)[1];
		}
		emit MinimumTokenBalanceForLottery(amount);
		_minimumTokenBalanceForLottery = amount;
		return true;
	}

	function burnTheHouseDown() external onlyTokenContract returns (uint256) {
		uint256 toBurn = tokenContract.balanceOf(address(this));
		tokenContract.transfer(BURN_ADDRESS, toBurn);
		return toBurn;
	}

	function addV1Comission(address referrer, uint256 amount) external onlyOwner {
		require(!tokenContract.swapEnabled(), "DividendTracker: V2 is public");
		_referrers[referrer].transactions = _referrers[referrer].transactions.add(1);
		uint256 commission = 1;
		if (_bonusStructure[_referrers[referrer].transactions] > _referrers[referrer].bonus) {
			_referrers[referrer].bonus = _bonusStructure[_referrers[referrer].transactions];
		}
		_referrers[referrer].totalValue = _referrers[referrer].totalValue.add(amount);
		commission = commission.add(_referrers[referrer].bonus);
		uint256 commissionValue = amount.div(100).mul(commission);
		_referrers[referrer].commissions = _referrers[referrer].commissions.add(commissionValue);
		if (!_excludedFromLottery[referrer] && _referrers[referrer].transactions >= 5) {
			_referredSwaps.push(referrer);
		} else {
			_unqualified++;
		}
	}
}