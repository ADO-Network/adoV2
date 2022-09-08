// SPDX-License-Identifier: MIT
pragma solidity 0.8.9;
// Web: https://www.ado.network
// Twitter: https://twitter.com/NetworkAdo
// Discord: https://discord.gg/n9FyS5Tr
// Telegram: https://t.me/ADONetworkEnglish
// Reddit: https://www.reddit.com/r/ADO_Network/

// ADO works simultaneously with two liquidity pools, ADO-BNB and ADO-BUSD.
// ADO can switch between pools anytime, moving 99% of the funds from
// main pool to secondary pool and generate revenue for holders by earning in price compared to the price of BNB.
// ADO.Network Team is not responsible for any losses incurred by swaping in the secondary pool.
// If you use PancakeSwap, make sure you are dealing with the Main Pool.
// We'd recommend using the swap mode on www.ado.network as it is set to always work with the Main Pool.
import "./libraries/SafeMath.sol";
import "./DividendTracker.sol";
import "./AdoVault.sol";
import "./LPManager.sol";
import "./abstracts/Ownable.sol";
import "./interfaces/IBEP20.sol";
import "./interfaces/IPancakeSwapV2Pair.sol";
import "./interfaces/IPancakeSwapV2Factory.sol";
import "./interfaces/IPancakeSwapV2Router02.sol";

contract AdoToken is IBEP20, Ownable {
	using SafeMath for uint256;

	address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
	address public immutable deployer;
	address public mainLPToken;
	IPancakeSwapV2Router02 public pancakeSwapV2Router;
	IPancakeSwapV2Pair public pancakeSwapWETHV2Pair;
	IPancakeSwapV2Pair public pancakeSwapBUSDV2Pair;
	DividendTracker public dividendContract;
	LPManager public lpManager;
	IBEP20 public busdContract;
	
	string private _name = "ADO.Network";
	string private _symbol = "ADO";
	uint8 private _decimals = 18;
	bool public swapEnabled = false;
	bool private _swapping = false;
	bool private _dividendContractSet = false;
	bool private _busdContractSet = false;
	bool private _lpManagerSet = false;
	uint256 private _totalSupply = 1000000000 * (10 ** _decimals);
	uint256 private _tokensToLiqudate = _totalSupply.div(10000);
	uint256 private _lpWeight;
	uint256 private _holdersLotteryFund;
	uint256 private _referrersLotteryFund;
	uint256 private _buyBackBalance;
	uint256 private _cursor;
	uint256 private _dividendFee = 2;
	uint256 private _buyBackFee = 6;
	uint256 private _lotteryFee = 2;
	uint256 private _totalFee = 10;
	uint256 private _totalIterations;
	uint256 public partners;
	mapping(address => uint256) private _balances;
	mapping(address => mapping(address => uint256)) private _allowances;
	mapping (address => bool) private _isExcludedFromFees;
	mapping (address => bool) private _partners;

	event ExcludedAddress(address indexed account, bool fromFee, bool fromDividends, bool fromLottery);
	event NewPartner(address indexed account);
	event BuyBackUpdate(address indexed token, uint256 eth, uint256 busd);
	event LPWeight(uint256 lp, uint256 bb);
	event FeeDistribution(uint256 buyBack, uint256 dividend, uint256 lottery);
	event TokenBalanceToLiqudate(uint256 indexed newValue, uint256 indexed oldValue);
	event ProcessedDividendTracker(uint256 iterations, uint256 claims, uint256 indexed lastProcessedIndex, bool indexed automatic, uint256 gas, address indexed processor);
	event MainLPSwitch(address indexed newToken);

	modifier onlyDeployer() {
		require(_msgSender() == deployer, "Token: Only the token deployer can call this function");
		_;
	}

	constructor() {
		deployer = owner();
		_isExcludedFromFees[owner()] = true;
		_isExcludedFromFees[address(this)] = true;
		_isExcludedFromFees[BURN_ADDRESS] = true;
		_balances[owner()] = _totalSupply;
		emit Transfer(address(0), owner(), _totalSupply);
	}

	receive() external payable {}

	function name() external view override returns (string memory) {
		return _name;
	}

	function symbol() external view override returns (string memory) {
		return _symbol;
	}

	function decimals() external view override returns (uint8) {
		return _decimals;
	}

	function getOwner() external view override returns (address) {
		return owner();
	}

	function totalFee() external view returns (uint256) {
		return _totalFee;
	}

	function fees() external view returns (uint256 dividendFee, uint256 buyBackFee, uint256 lotteryFee, bool isActive) {
		dividendFee = _dividendFee;
		buyBackFee = _buyBackFee;
		lotteryFee = _lotteryFee;
		isActive = _totalFee > 0;
	}

	function totalSupply() external view override returns (uint256) {
		return _totalSupply;
	}

	function balanceOf(address account) external view override returns (uint256) {
		return _balances[account];
	}

	function isExcludedFromFees(address account) external view returns(bool) {
		return _isExcludedFromFees[account];
	}

	function tokensToLiqudate() external view returns(uint256) {
		return _tokensToLiqudate;
	}

	function totalIterations() external view returns(uint256) {
		return _totalIterations;
	}

	function cursor() external view returns(uint256) {
		return _cursor;
	}

	function lpvsbb() external view returns(uint256 lp, uint256 bb) {
		uint256 weight = 10;
		lp = _lpWeight;
		bb = weight.sub(_lpWeight);
	}

	function funds() external view returns(uint256 hlf, uint256 rlf, uint256 bbbnb, uint256 bbbusd) {
		hlf = _holdersLotteryFund;
		rlf = _referrersLotteryFund;
		bbbnb = _buyBackBalance;
		bbbusd = busdContract.balanceOf(address(this));
	}

	function transfer(address recipient, uint256 amount) external override returns (bool) {
		_transfer(_msgSender(), recipient, amount);
		return true;
	}

	function allowance(address owner, address spender) external view override returns (uint256) {
		return _allowances[owner][spender];
	}

	function approve(address spender, uint256 amount) external override returns (bool) {
		_approve(_msgSender(), spender, amount);
		return true;
	}

	function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
		_transfer(sender, recipient, amount);
		_approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "Token: transfer amount exceeds allowance"));
		return true;
	}

	function updateLPWeight(uint256 lpWeight) external onlyDeployer returns (bool) {
		require(lpWeight <= 10, "Token: LPWeight must be between 0 and 10");
		_lpWeight = lpWeight;
		emit LPWeight(_lpWeight, 10 - _lpWeight);
		return true;
	}

	function updateFeeDistribution(uint256 newBuyBackFee) external onlyDeployer returns (bool) {
		require(newBuyBackFee != _buyBackFee, "Token: The BuyBack fee is already set to the requested value");
		require(newBuyBackFee == 2 || newBuyBackFee == 4 || newBuyBackFee == 6, "Token: The BuyBack fee can only be 2 4 or 6");
		_buyBackFee = newBuyBackFee;
		_dividendFee = _totalFee.sub(_buyBackFee).sub(_lotteryFee);
		emit FeeDistribution(_buyBackFee, _dividendFee, _lotteryFee);
		return true;
	}

	function updateTokensToLiqudate(uint256 newValue) external onlyDeployer returns (bool) {
		require(newValue >= 100000000000000000000 && newValue <= 1000000000000000000000000, "Token: numTokensToLiqudate must be between 100 and 1.000.000 ADO");
		emit TokenBalanceToLiqudate(newValue, _tokensToLiqudate);
		_tokensToLiqudate = newValue;
		return true;
	}

	function buyBack(uint256 amount, address recipient) external onlyDeployer {
		require(recipient == BURN_ADDRESS || recipient == address(dividendContract), "Token: Invalid recipient.");
		if (mainLPToken == pancakeSwapV2Router.WETH()) {
			require(amount <= _buyBackBalance, "Token: Insufficient funds.");
			swapETHForTokens(recipient, 0, amount);
			_buyBackBalance = address(this).balance
				.sub(_holdersLotteryFund)
				.sub(_referrersLotteryFund);
		} else {
			require(amount <= busdContract.balanceOf(address(this)), "Token: Insufficient funds.");
			address[] memory path = new address[](2);
			path[0] = address(busdContract);
			path[1] = address(this);
			busdContract.approve(address(pancakeSwapV2Router), amount);
			pancakeSwapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
				amount,
				0,
				path,
				recipient,
				block.timestamp
			);
		}
	}

	function processDividendTracker() external onlyDeployer {
		require(_dividendContractSet, "Token: Dividend Contract Token is not set");
		uint256 contractTokenBalance = _balances[address(this)];
		bool canSwap = contractTokenBalance > _tokensToLiqudate;
		if (canSwap) {
			_swapping = true;
			swapAndSendDividends(_tokensToLiqudate);
			_swapping = false;
		}
		uint256 _iterations = 0;
		try dividendContract.process() returns (uint256 iterations, uint256 claims, uint256 lpIndex) {
			emit ProcessedDividendTracker(iterations, claims, lpIndex, true, dividendContract.gasForProcessing(), tx.origin);
			_iterations = iterations;
		} catch {}
		_totalIterations = _totalIterations.add(_iterations);
	}

	function addPartner(address account) external onlyDeployer returns (uint256) {
		require(_partners[account] == false, "Token: Account is a partner");
		_partners[account] = true;
		partners++;
		dividendContract.excludeFromLottery(account);
		emit NewPartner(account);
		return partners;
	}

	function excludeAddress(address account, bool fromFee, bool fromDividends, bool fromLottery) external onlyDeployer returns (bool) {
		if (fromFee) {
			require(_isExcludedFromFees[account] == false, "Token: Account is already excluded");
			_isExcludedFromFees[account] = true;
		}
		if (fromDividends) {
			dividendContract.excludeFromDividends(account);
		}
		if (fromLottery) {
			dividendContract.excludeFromLottery(account);
		}
		emit ExcludedAddress(account, fromFee, fromDividends, fromLottery);
		return true;
	}

	function removeTax() external onlyDeployer returns (uint256) {
		require(dividendContract.maxMilestone() == 0, "Token: milestone in progress");
		_totalFee = 0;
		uint256 burnedAmount = _balances[address(this)];
		_transfer(address(this), BURN_ADDRESS, burnedAmount);
		_buyBackBalance = address(this).balance;
		_holdersLotteryFund = 0;
		_referrersLotteryFund = 0;
		uint256 dBurnedAmount = dividendContract.burnTheHouseDown();
		return burnedAmount.add(dBurnedAmount);
	}

	function _approve(address owner, address spender, uint256 amount) private {
		require(owner != address(0), "Token: approve from the zero address");
		require(spender != address(0), "Token: approve to the zero address");
		_allowances[owner][spender] = amount;
		emit Approval(owner, spender, amount);
	}

	function swapBUSDforETH(uint256 amount, address to) private returns (uint256) {
		uint256 initialBalance = address(this).balance;
		address[] memory path = new address[](2);
		path[0] = address(busdContract);
		path[1] = pancakeSwapV2Router.WETH();
		busdContract.approve(address(pancakeSwapV2Router), amount);
		pancakeSwapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
			amount,
			0,
			path,
			to,
			block.timestamp
		);
		return address(this).balance.sub(initialBalance);
	}

	function swapETHforBUSD(uint256 amount, address to) private returns (uint256) {
		uint256 initialBalance = busdContract.balanceOf(address(this));
		address[] memory path = new address[](2);
		path[0] = pancakeSwapV2Router.WETH();
		path[1] = address(busdContract);
		pancakeSwapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(0, path, to, block.timestamp);
		return busdContract.balanceOf(address(this)).sub(initialBalance);
	}

	function swapETHForTokens(address recipient, uint256 minTokenAmount, uint256 amount) private {
		address[] memory path = new address[](2);
		path[0] = pancakeSwapV2Router.WETH();
		path[1] = address(this);
		pancakeSwapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
			minTokenAmount,
			path,
			recipient,
			block.timestamp
		);
	}

	function swapTokensForEth(uint256 tokenAmount) public returns (uint256) {
		uint256 pathlength = mainLPToken == pancakeSwapV2Router.WETH() ? 2 : 3;
		address[] memory path = new address[](pathlength);
		path[0] = address(this);
		path[1] = mainLPToken;
		if (mainLPToken != pancakeSwapV2Router.WETH()) {
			path[2] = pancakeSwapV2Router.WETH();
		}
		uint256 initialBalance = address(this).balance;
		_approve(address(this), address(pancakeSwapV2Router), tokenAmount);
		pancakeSwapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
			tokenAmount,
			0,
			path,
			address(this),
			block.timestamp
		);
		uint256 eth = address(this).balance.sub(initialBalance);
		return eth;
	}

	function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
		_approve(address(this), address(pancakeSwapV2Router), tokenAmount);
		pancakeSwapV2Router.addLiquidityETH{value: ethAmount}(
			address(this),
			tokenAmount,
			0,
			0,
			address(lpManager),
			block.timestamp
		);
	}

	function swapAndSendDividends(uint256 amount) private {
		_cursor++;
		bool addLP = (mainLPToken == pancakeSwapV2Router.WETH()) && (_cursor.mod(10) < _lpWeight);
		uint256 swapTokensAmount = amount;
		if (addLP) {
			uint256 lpf = _buyBackFee.div(2);
			lpf = lpf.add(_lotteryFee).add(_dividendFee);
			swapTokensAmount = amount.div(_totalFee).mul(lpf);
		}
		uint256 eth = swapTokensForEth(swapTokensAmount);
		uint256 lotteriesEth = eth.div(_totalFee).mul(_lotteryFee);
		_holdersLotteryFund = _holdersLotteryFund.add(lotteriesEth.div(2));
		_referrersLotteryFund = _referrersLotteryFund.add(lotteriesEth.div(2));
		uint256 dividendEth = eth.div(_totalFee).mul(_dividendFee);
		(bool dividendContractTransfer,) = payable(address(dividendContract)).call{value: dividendEth, gas: 3000}('');
		if (dividendContractTransfer) {
			dividendContract.updateDividendsDistributed(dividendEth);
		}
		if (addLP) {
			uint256 lpeth = eth.sub(lotteriesEth).sub(dividendEth);
			addLiquidity(amount.sub(swapTokensAmount), lpeth);
		}
		_buyBackBalance = address(this).balance.sub(_holdersLotteryFund).sub(_referrersLotteryFund);
	}

	function _transfer(address from, address to, uint256 amount) private {
		require(from != address(0), "Token: Transfer from the zero address");
		require(to != address(0), "Token: Transfer to the zero address");
		require(amount > 0, "Token: Transfer amount must be greater than zero");
		require(swapEnabled || from == deployer, "Token: Public transfer has not yet been activated");
		require(_dividendContractSet, "Token: Dividend Contract Token is not set");
		
		bool takeFee = true;
		bool process = true;
		if (
			_isExcludedFromFees[from] ||
			_isExcludedFromFees[to] ||
			(_partners[from]) ||
			(_partners[to])
		) {
			takeFee = false;
			process = false;
			if (_partners[from]) {
				if (to == address(pancakeSwapWETHV2Pair) || to == address(pancakeSwapBUSDV2Pair)) takeFee = true;
			}
			if (_partners[to]) {
				if (from == address(pancakeSwapWETHV2Pair) || from == address(pancakeSwapBUSDV2Pair)) takeFee = true;
			}
		}

		if (!_swapping && _totalFee != 0 && takeFee) {
			uint256 contractTokenBalance = _balances[address(this)];
			bool canSwap = contractTokenBalance > _tokensToLiqudate;
			if (canSwap) {
				if (
					(mainLPToken == pancakeSwapV2Router.WETH() && from != address(pancakeSwapWETHV2Pair)) ||
					(mainLPToken == address(busdContract) && from != address(pancakeSwapBUSDV2Pair)))
				{
					_swapping = true;
					swapAndSendDividends(_tokensToLiqudate);
					_swapping = false;
					process = false;
				}
			}

			uint256 txFee = amount.div(100).mul(_totalFee);
			amount = amount.sub(txFee);
			_balances[from] = _balances[from].sub(txFee, "Token: Transfer amount exceeds balance");
			_balances[address(this)] = _balances[address(this)].add(txFee);
			emit Transfer(from, address(this), txFee);
		}

		_balances[from] = _balances[from].sub(amount, "Token: Transfer amount exceeds balance");
		_balances[to] = _balances[to].add(amount);
		emit Transfer(from, to, amount);

		dividendContract.setBalance(payable(from), _balances[from], false);
		dividendContract.setBalance(payable(to), _balances[to], true);

		if (!_swapping && process) {
			if (
				from == address(pancakeSwapWETHV2Pair) ||
				to == address(pancakeSwapWETHV2Pair) ||
				from == address(pancakeSwapBUSDV2Pair) ||
				to == address(pancakeSwapBUSDV2Pair)
			) {
				uint256 _iterations = 0;
				try dividendContract.process() returns (uint256 iterations, uint256 claims, uint256 lpIndex) {
					emit ProcessedDividendTracker(iterations, claims, lpIndex, true, dividendContract.gasForProcessing(), tx.origin);
					_iterations = iterations;
				} catch {}
				_totalIterations = _totalIterations.add(_iterations);
			}
		}
	}

	function setDividendTrackerContract(address _dividendTracker, uint256 amount) external onlyOwner {
		dividendContract = DividendTracker(payable(_dividendTracker));
		_dividendContractSet = true;
		_isExcludedFromFees[_dividendTracker] = true;
		_transfer(_msgSender(), _dividendTracker, amount);
	}

	function setLPManeger(address _lpManager) external onlyOwner {
		require(!_lpManagerSet, "Token: LP Maneger is already set");
		require(address(pancakeSwapV2Router) != address(0), "Token: PancakeSwapV2 Router is not set");
		require(address(pancakeSwapWETHV2Pair) != address(0), "Token: PancakeSwapV2 WETH Pair is not set");
		require(address(pancakeSwapBUSDV2Pair) != address(0), "Token: PancakeSwapV2 BUSD Pair is not set");
		lpManager = LPManager(payable(_lpManager));
		_lpManagerSet = true;
		_isExcludedFromFees[_lpManager] = true;
		dividendContract.excludeFromDividends(_lpManager);
	}

	function setBUSDContract(address _busd) external onlyOwner {
		require(!_busdContractSet, "Token: BUSD Token is already set");
		busdContract = IBEP20(_busd);
		_busdContractSet = true;
	}

	function createPancakeSwapPair(address PancakeSwapRouter) external onlyOwner {
		require(_dividendContractSet, "Token: Dividend Contract contract is not set");
		require(_busdContractSet, "Token: BUSD Token Contract contract is not set");
		pancakeSwapV2Router = IPancakeSwapV2Router02(PancakeSwapRouter);
		pancakeSwapWETHV2Pair = IPancakeSwapV2Pair(IPancakeSwapV2Factory(pancakeSwapV2Router
			.factory())
			.createPair(address(this), pancakeSwapV2Router.WETH()));
		mainLPToken = pancakeSwapV2Router.WETH();
		pancakeSwapBUSDV2Pair = IPancakeSwapV2Pair(IPancakeSwapV2Factory(pancakeSwapV2Router
			.factory())
			.createPair(address(this), address(busdContract)));
		dividendContract.excludeFromDividends(address(pancakeSwapV2Router));
		dividendContract.excludeFromDividends(address(pancakeSwapWETHV2Pair));
		dividendContract.excludeFromDividends(address(pancakeSwapBUSDV2Pair));
	}

	function enableSwap() external onlyDeployer returns (bool) {
		require(!swapEnabled, "Token: PublicSwap is already enabeled");
		require(address(pancakeSwapV2Router) != address(0), "Token: PancakeSwapV2 Router is not set");
		swapEnabled = true;
		return swapEnabled;
	}

	function swapETHForExactTokens(uint256 amountOut, address referrer) external payable returns (uint256) {
		address[] memory path = new address[](2);
		path[1] = address(this);
		if (mainLPToken == pancakeSwapV2Router.WETH()) {
			path[0] = pancakeSwapV2Router.WETH();
			pancakeSwapV2Router.swapETHForExactTokens{value: msg.value}(
				amountOut,
				path,
				_msgSender(),
				block.timestamp
			);
			uint256 ethBack = address(this).balance
				.sub(_holdersLotteryFund)
				.sub(_referrersLotteryFund)
				.sub(_buyBackBalance);
			(bool refund, ) = _msgSender().call{value: ethBack, gas: 3000}("");
			require(refund, "Token: Refund Failed");
		} else {
			uint256 initialBUSDBalance = busdContract.balanceOf(address(this));
			path[0] = address(busdContract);
			uint256 busdAmount = swapETHforBUSD(msg.value, address(this));
			busdContract.approve(address(pancakeSwapV2Router), busdAmount);
			pancakeSwapV2Router.swapTokensForExactTokens(
				amountOut,
				busdAmount,
				path,
				_msgSender(),
				block.timestamp
			);
			uint256 busdBack = busdContract.balanceOf(address(this))
				.sub(initialBUSDBalance);
			swapBUSDforETH(busdBack, _msgSender());
		}
		uint256 txFee = amountOut.div(100).mul(_totalFee);
		uint256 amount = amountOut.sub(txFee);
		if (referrer != address(0) && referrer != _msgSender() && _totalFee > 0) {
			dividendContract.payCommission(referrer, amount);
		}
		return amount;
	}

	function swapBUSDForExactTokens(uint256 busdAmount, uint256 amountOut, address referrer) external returns (uint256) {
		uint256 initialBUSDBalance = busdContract.balanceOf(address(this));
		busdContract.transferFrom(_msgSender(), address(this), busdAmount);
		address[] memory path = new address[](2);
		path[1] = address(this);
		if (mainLPToken == pancakeSwapV2Router.WETH()) {
			uint256 eth = swapBUSDforETH(busdAmount, address(this));
			path[0] = pancakeSwapV2Router.WETH();
			pancakeSwapV2Router.swapETHForExactTokens{value: eth}(
				amountOut,
				path,
				_msgSender(),
				block.timestamp
			);
			uint256 ethBack = address(this).balance
				.sub(_buyBackBalance)
				.sub(_holdersLotteryFund)
				.sub(_referrersLotteryFund);
			swapETHforBUSD(ethBack, _msgSender());
		} else {
			path[0] = address(busdContract);
			busdContract.approve(address(pancakeSwapV2Router), busdAmount);
			pancakeSwapV2Router.swapTokensForExactTokens(
				amountOut,
				busdAmount,
				path,
				_msgSender(),
				block.timestamp
			);
			uint256 busdBack = busdContract.balanceOf(address(this))
				.sub(initialBUSDBalance);
			busdContract.transfer(_msgSender(), busdBack);
		}
		uint256 txFee = amountOut.div(100).mul(_totalFee);
		uint256 amount = amountOut.sub(txFee);
		if (referrer != address(0) && referrer != _msgSender() && _totalFee > 0) {
			dividendContract.payCommission(referrer, amount);
		}
		return amount;
	}

	function swapExactETHForTokens(uint256 amountOutMin, address referrer) external payable returns (uint256) {
		uint256 initialTokenBalance = _balances[_msgSender()];
		if (mainLPToken == pancakeSwapV2Router.WETH()) {
			swapETHForTokens(_msgSender(), amountOutMin, msg.value);
		} else {
			uint256 busdAmount = swapETHforBUSD(msg.value, address(this));
			address[] memory path = new address[](2);
			path[0] = address(busdContract);
			path[1] = address(this);
			busdContract.approve(address(pancakeSwapV2Router), busdAmount);
			pancakeSwapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
				busdAmount,
				amountOutMin,
				path,
				_msgSender(),
				block.timestamp
			);
		}
		uint256 amount = _balances[_msgSender()].sub(initialTokenBalance);
		if (referrer != address(0) && referrer != _msgSender() && _totalFee > 0) {
			dividendContract.payCommission(referrer, amount);
		}
		return amount;
	}

	function swapExactBUSDForTokens(uint256 busdAmount, uint256 amountOutMin, address referrer) external returns (uint256) {
		busdContract.transferFrom(_msgSender(), address(this), busdAmount);
		uint256 initialTokenBalance = _balances[_msgSender()];
		if (mainLPToken == pancakeSwapV2Router.WETH()) {
			uint256 eth = swapBUSDforETH(busdAmount, address(this));
			swapETHForTokens(_msgSender(), amountOutMin, eth);
		} else {
			address[] memory path = new address[](2);
			path[0] = address(busdContract);
			path[1] = address(this);
			busdContract.approve(address(pancakeSwapV2Router), busdAmount);
			pancakeSwapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
				busdAmount,
				amountOutMin,
				path,
				_msgSender(),
				block.timestamp
			);
		}
		uint256 amount = _balances[_msgSender()].sub(initialTokenBalance);
		if (referrer != address(0) && referrer != _msgSender() && _totalFee > 0) {
			dividendContract.payCommission(referrer, amount);
		}
		return amount;
	}

	function switchPool(uint bp) external onlyDeployer returns (address) {
		require(bp <= 5 , "Token: Burn to high");
		_swapping = true;
		(address lptoken, bool updateBB) = lpManager.switchPool(bp);
		_swapping = false;
		mainLPToken = lptoken;
		if (updateBB) {
			_buyBackBalance = address(this).balance
				.sub(_holdersLotteryFund)
				.sub(_referrersLotteryFund);
		}
		emit MainLPSwitch(mainLPToken);
		return lptoken;
	}

	function addToBuyBack() external payable returns (uint256) {
		require(msg.value > 0, "Token: Transfer amount must be greater than zero");
		_buyBackBalance = _buyBackBalance.add(msg.value);
		emit BuyBackUpdate(_msgSender(), msg.value, 0);
		return _buyBackBalance;
	}

	function swapBuyBack2BNB() external onlyDeployer returns (uint256) {
		uint256 busd = busdContract.balanceOf(address(this));
		require(busd > 0, "Token: Insufficient funds.");
		uint256 eth = swapBUSDforETH(busdContract.balanceOf(address(this)), address(this));
		emit BuyBackUpdate(pancakeSwapV2Router.WETH(), eth, busd);
		_buyBackBalance = _buyBackBalance.add(eth);
		return eth;
	}

	function swapBuyBack2BUSD() external onlyDeployer returns (uint256) {
		require(_buyBackBalance > 0, "Token: Insufficient funds.");
		uint256 busd = swapETHforBUSD(_buyBackBalance, address(this));
		emit BuyBackUpdate(address(busdContract), _buyBackBalance, busd);
		_buyBackBalance = 0;
		return busd;
	}

	function payTheWinner(address winner) external returns (bool) {
		require(_msgSender() == address(dividendContract), "Token: Only the Dividend contract can call this function");
		(bool success,) = payable(winner).call{value: _holdersLotteryFund, gas: 3000}('');
		require(success, "Token: Transfer to lottery winner faild");
		_holdersLotteryFund = 0;
		return success;
	}

	function referrersLotteryFundWithdrawal(address referrerLotteryWallet) external returns (bool) {
		require(_msgSender() == address(dividendContract), "Token: Only the Dividend contract can call this function");
		(bool success,) = payable(referrerLotteryWallet).call{value: _referrersLotteryFund, gas: 3000}('');
		require(success, "Token: Transfer to Referrer Lottery Wallet faild");
		_referrersLotteryFund = 0;
		return success;
	}
}