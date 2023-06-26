// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

interface ISTakingXYZ {
    function delegate(address validator, uint256 amount) external payable;
    function undelegate(address validator, uint256 amount) external payable returns (uint256 ID);
    function withdrawUndelegated(uint256 id) external payable returns (uint256 amount);
    function claimReward() external returns (uint256 amount);
    function getTotalDelegated(address delegator) external view returns (uint256);
    function getUndelegateTime() external view returns (uint256);
    function getRelayerFee() external view returns (uint256);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract LiquidStakingXYZ is IERC20 {
    string public name = "Liquid Staking XYZ";
    string public symbol = "sXYZ";
    uint8 public decimals = 18;
    // uint256 private totalSupply;
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;
    uint256 private relayerFee;

    ISTakingXYZ private stakingXYZ;
    address private constant VALIDATOR_ADDRESS = 0x12D90403733b6DD1f88240C773a6613331e60bCF; // Replace with the actual validator address
    
    struct Receipt {
        uint256 amount;
        uint256 unstakedAt;
    }

    // mapping: receiptId => Receipt
    mapping(uint256 => Receipt) private idToReceipt;
    // mapping(address => Receipt[]) private unlockReceipts;
    
    event Deposit(address indexed from, uint256 amount, uint256 sTokenAmount);
    event Unlock(address indexed from, uint256 sTokenAmount);
    event Withdraw(address indexed from, uint256 amount);
    
    constructor(address _stakingXYZ) {
        stakingXYZ = ISTakingXYZ(_stakingXYZ);
        relayerFee = stakingXYZ.getRelayerFee();
    }

    // function: deposit()
    // Assumption: the reward for the staking of XYZ is calculated in stakingXYZ, hence no need to keep in storage the block.number of each deposit.
    // If the assumption is not true, I need to implement storage structure to keep the address of depositor, block.number and amount of each deposit.
    function deposit() external payable {
        relayerFee = _getRelayerFee();
        require(msg.value >= relayerFee, "Insufficient funds to cover the relayer fee");
        uint256 amount = msg.value - relayerFee;

        // Transfer native XYZ tokens (ETH) from the user to the stakingXYZ contract
        stakingXYZ.delegate{value: msg.value}(VALIDATOR_ADDRESS, amount);

        // Mint sXYZ tokens to the user
        uint256 sTokenAmount = amount;
        balances[msg.sender] += sTokenAmount;
        balances[address(this)] += sTokenAmount;

        emit Deposit(msg.sender, amount, sTokenAmount);
    }
    // function: unlock()
    // Assumption: the reward to the holder of sXYZ token is calculated at stakingXYZ contract and can be called by stakingXYZ.claimReward()
    // The assumption here is that the reward is always positive and match the aToken model, where the staker get additional sXYZ tokens as reward.
    // Another assumption is that the reward is available only at unlock and get immidiatly swapped to XYZ (after delegation time ends)
    function unlock(uint256 sTokenAmount) external payable returns (uint256 receiptId) {
        relayerFee = _getRelayerFee();
        require(msg.value >= relayerFee, "Insufficient funds to cover the relayer fee");
        require(sTokenAmount > 0, "Amount must be greater than 0");
        require(balances[msg.sender] >= sTokenAmount, "Insufficient sXYZ balance");

        uint256 tokensReward = stakingXYZ.claimReward();
        // Transfer the relayer fee in XYZ to the stakingXYZ contract
        receiptId = stakingXYZ.undelegate{value: relayerFee}(VALIDATOR_ADDRESS, sTokenAmount + tokensReward);

        // Burn sXYZ tokens from the user
        balances[msg.sender] -= sTokenAmount;
        balances[address(this)] -= sTokenAmount;

        // Create a receipt for the unlock process
        uint256 unlockTime = block.timestamp + stakingXYZ.getUndelegateTime();
        Receipt memory receipt = Receipt(sTokenAmount, unlockTime);
        idToReceipt[receiptId] = receipt;
        
        // Return excess value (msg.value - relayerFee) to the user
        if (msg.value > relayerFee) {
            payable(msg.sender).transfer(msg.value - relayerFee);
        }

        emit Unlock(msg.sender, sTokenAmount);
    }
    
    function withdraw(uint256 _receiptId) external payable {
        relayerFee = _getRelayerFee();
        // require(receiptIndex < unlockReceipts[msg.sender].length, "Invalid receipt index");
        Receipt memory receipt = idToReceipt[_receiptId];
        require(block.timestamp >= receipt.unstakedAt, "Unlock period not elapsed");

        uint256 amount = receipt.amount;
        delete idToReceipt[_receiptId];

        // Call withdrawUndelegated() on stakingXYZ
        uint256 withdrawAmount = stakingXYZ.withdrawUndelegated{value: relayerFee}(_receiptId);
        
        // Transfer the unlocked XYZ tokens (minus the relayer fee) back to the user
        payable(msg.sender).transfer(withdrawAmount - relayerFee);
        
        emit Withdraw(msg.sender, withdrawAmount);
    }
    
        function _getRelayerFee() internal view returns (uint256) {
        return stakingXYZ.getRelayerFee();
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }
    
    function totalSupply() external view override returns (uint256) {
        return balances[address(this)];
    }
    
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = allowances[sender][msg.sender];
        require(currentAllowance >= amount, "Transfer amount exceeds allowance");
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, currentAllowance - amount);
        return true;
    }
    
    function approve(address spender, uint256 amount) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
    
    function allowance(address owner, address spender) external view override returns (uint256) {
        return allowances[owner][spender];
    }
    
    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "Transfer from the zero address");
        require(recipient != address(0), "Transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        require(balances[sender] >= amount, "Insufficient balance");

        balances[sender] -= amount;
        balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
    }
    
    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "Approve from the zero address");
        require(spender != address(0), "Approve to the zero address");

        allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function getRelayerFee() external view returns (uint256) {
        return relayerFee;
    }
}
