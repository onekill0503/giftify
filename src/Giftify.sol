// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ISUSDE.sol";

/**
 * @title Donate
 * @author To De Moon Team
 * @notice This Contract is used for donation and store the donation data
 * @custom:experimental This is an experimental contract
 */
contract Giftify is Ownable {
    /**
     * @notice Gifters Record Struct to Gifter data
     */
    struct GiftersRecord {
        uint256 totalDonations; // total donation amount
        uint256 donatedAmount; // donation amount deducted by platform fees
        uint256 totalShares; // total shares of donation
        uint256 grossDonatedAmount; // gross amount of donation
        uint256 lastClaimed; // last claimed timestamp
    }

    struct WithdrawBatch {
        uint256 batchAmount;
        uint256 lastBatchWithdraw;
        bool onGoing;
    }

    struct UserShares {
        uint256 totalShares;
        uint256 claimedAmount;
        uint256 usdeAmount;
    }
    /**
     * @notice Creators Record Struct to Creator data
     */

    struct CreatorsRecord {
        uint256 totalDonation; // total donation amount
        uint256 claimableShares; // claimable donation amount
        uint256 lastClaimed; // last claimed timestamp
    }

    /**
     * @notice Variables to store total donations
     */
    uint256 public totalDonations;
    /**
     * @notice Variables to store total withdraw
     */
    uint256 public totalWithdraw;
    /**
     * @notice Variables to store platform address
     */
    address public platformAddress;
    /**
     * @notice Platform Fees Percentage (fixed to 5%), platform fees will be deducted when user donate
     */
    uint256 public platformFees = 5;
    /**
     * @notice creator Fees Percentage (fixed to 30%), creator fees will be deducted when creator claim donation
     */
    uint256 public creatorPercentage = 30;
    /**
     * @notice yield Percentage (fixed to 70%), this is donatur yield percentage for cashback
     */
    uint256 public gifterPercentage = 70;
    /**
     * @notice batchWithdrawAmount to store total amount to batch withdraw
     */
    uint256 public currentBatch;
    /**
     * @notice batchWithdrawMin to store minimum amount to batch withdraw
     */
    uint256 public batchWithdrawMin = 500e18;
    /**
     * @notice Merkle Root Hash to store merkle root hash
     */
    bytes32 public merkleRoot;

    event NewDonation(
        address indexed gifter,
        uint256 grossAmount,
        uint256 netAmount,
        address indexed creator,
        uint256 gifterShares,
        uint256 timestamp
    );
    event InitiateWithdraw(address indexed creator, uint256 shares, uint256 timestamp);
    event ClaimReward(address indexed user, uint256 amount, uint256 timestamp);

    error DONATE__AMOUNT_ZERO();
    error DONATE__INSUFFICIENT_BALANCE(address wallet);
    error DONATE__BATCH_WITHDRAW_MINIMUM_NOT_REACHED(uint256 batchWithdrawAmount);
    error DONATE__INVALID_MERKLE_PROOF();
    error DONATE__ALREADY_CLAIMED(address wallet);

    /**
     * @notice Donation Mapping to store donation data
     */
    mapping(address => GiftersRecord) public gifters;
    /**
     * @notice Creators Mapping to store creator data
     */
    mapping(address => CreatorsRecord) public creators;
    /**
     * @notice Allowed Donation Token Mapping to store allowed donation token
     */
    mapping(address => bool) public allowedDonationToken;
    mapping(uint256 => WithdrawBatch) public batchWithdrawAmounts;
    mapping(uint256 => mapping(address => bool)) public claimed;
    mapping(uint256 => mapping(address => UserShares)) public userShares;
    /**
     * @notice Allowed Donation Token Array to store allowed donation token
     */
    address[] public allowedDonationTokens;
    /**
     * @notice sUSDe token address with ISUSDE interface
     */
    ISUSDE public sUSDeToken;
    /**
     * @notice USDe token address with IERC20 interface
     */
    IERC20 public uSDeToken;

    /**
     * @notice Constructor to initialize owner and platform address
     * @param _platformAddress platform wallet address to receive platform fees
     */
    constructor(address _platformAddress, address _sUSDeToken, address _uSDEeToken) Ownable(msg.sender) {
        platformAddress = _platformAddress;
        sUSDeToken = ISUSDE(_sUSDeToken);
        uSDeToken = IERC20(_uSDEeToken);
    }

    /**
     * @notice Function to set merkle root hash (only owner can set)
     * @param _merkleRoot merkle root hash
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }

    /**
     * @notice Donate function to donate token to creator
     * @param _amount Donation amount for creator
     * @param _to Creator wallet address
     */
    function donate(uint256 _amount, address _to) external {
        if (_amount == 0) revert DONATE__AMOUNT_ZERO();
        if (uSDeToken.balanceOf(msg.sender) < _amount) revert DONATE__INSUFFICIENT_BALANCE(msg.sender);

        uint256 _platformFees = (_amount * platformFees) / 100;
        uint256 _netAmount = _amount - _platformFees;
        uint256 _gifterAmount = (_netAmount * gifterPercentage) / 100;
        uint256 _netShares = sUSDeToken.convertToShares(_netAmount);
        uint256 _gifterShares = sUSDeToken.convertToShares(_gifterAmount);

        gifters[msg.sender].donatedAmount += _netAmount;
        gifters[msg.sender].totalShares += _gifterShares;
        gifters[msg.sender].grossDonatedAmount += _amount;
        gifters[msg.sender].totalDonations += _amount;

        creators[_to].totalDonation += _netAmount;
        creators[_to].claimableShares += _netShares;

        // 70% of donation will be record to calculate yield earned by gifter
        userShares[currentBatch][msg.sender].totalShares += _gifterShares;
        userShares[currentBatch][msg.sender].usdeAmount += _gifterAmount;
        // 30% of donation will be record to calculate yield earned by creator
        userShares[currentBatch][_to].totalShares += _netShares - _gifterShares;
        userShares[currentBatch][_to].usdeAmount += _netAmount - _gifterAmount;

        uSDeToken.transferFrom(msg.sender, platformAddress, _platformFees);
        uSDeToken.transferFrom(msg.sender, address(this), _netAmount);
        uSDeToken.approve(address(sUSDeToken), _netAmount);
        sUSDeToken.deposit(_netAmount, address(this));

        totalDonations += _amount;

        emit NewDonation(msg.sender, _amount, _netAmount, _to, _gifterShares, block.timestamp);
    }

    /**
     * @notice Withdraw function to withdraw donation from creator
     * @param _shares Amount of token to withdraw
     */
    function initiateWithdraw(uint256 _shares) external {
        if (_shares == 0) revert DONATE__AMOUNT_ZERO();
        if (creators[msg.sender].claimableShares < _shares) revert DONATE__INSUFFICIENT_BALANCE(msg.sender);

        if (batchWithdrawAmounts[currentBatch].onGoing) {
            batchWithdrawAmounts[currentBatch + 1].batchAmount += _shares;
        } else {
            batchWithdrawAmounts[currentBatch].batchAmount += _shares;
        }

        if (batchWithdrawAmounts[currentBatch].lastBatchWithdraw == 0) {
            batchWithdrawAmounts[currentBatch].lastBatchWithdraw = block.timestamp;
        }

        creators[msg.sender].claimableShares -= _shares;

        emit InitiateWithdraw(msg.sender, _shares, block.timestamp);
    }

    /**
     * @notice Function to batch withdraw all donation token from contract
     */
    function batchWithdraw() external onlyOwner {
        if (batchWithdrawAmounts[currentBatch].batchAmount < batchWithdrawMin) {
            revert DONATE__BATCH_WITHDRAW_MINIMUM_NOT_REACHED(batchWithdrawAmounts[currentBatch].batchAmount);
        }

        sUSDeToken.approve(address(sUSDeToken), batchWithdrawAmounts[currentBatch].batchAmount);
        sUSDeToken.cooldownShares(batchWithdrawAmounts[currentBatch].batchAmount);

        batchWithdrawAmounts[currentBatch].onGoing = true;
    }

    /**
     * @notice Function to unstake and withdraw all donation token from contract
     */
    function unstakeBatchWithdraw() external onlyOwner {
        sUSDeToken.unstake(address(this));
        currentBatch += 1;
    }

    /**
     * @notice Function to change owner of the contract
     * @param _newOwner new owner address
     */
    function changeOwner(address _newOwner) external onlyOwner {
        Ownable.transferOwnership(_newOwner);
    }

    /**
     * @notice function to get yield amount from active donation user
     * @param _user user wallet address
     * @return _yield yield amount deducted by yeild percentage
     */
    function getYield(address _user) external view returns (uint256) {
        uint256 _totalUSDE = userShares[currentBatch][_user].claimedAmount > 0
            ? userShares[currentBatch][_user].claimedAmount
            : sUSDeToken.previewRedeem(userShares[currentBatch][_user].totalShares);
        uint256 _yield = (_totalUSDE - userShares[currentBatch][_user].usdeAmount);
        return _yield;
    }

    /**
     * @notice function to update SUSDE token address
     * @param _sUSDeToken sUSDe token address
     */
    function updateToken(address _sUSDeToken, address _USDeToken) external onlyOwner {
        sUSDeToken = ISUSDE(_sUSDeToken);
        uSDeToken = IERC20(_USDeToken);
    }

    /**
     * @notice function to claim token
     * @param _amount amount to claim
     * @param _proof merkle proof
     */
    function claim(uint256 _amount, bytes32[] calldata _proof) external {
        if (claimed[currentBatch][msg.sender]) revert DONATE__ALREADY_CLAIMED(msg.sender);
        bool isValidProof = MerkleProof.verify(_proof, merkleRoot, keccak256(abi.encodePacked(msg.sender, _amount)));

        if (!isValidProof) revert DONATE__INVALID_MERKLE_PROOF();
        uSDeToken.transfer(msg.sender, _amount);

        claimed[currentBatch][msg.sender] = true;
        userShares[currentBatch][msg.sender].claimedAmount += _amount;

        // if sender has donated before, update last claimed timestamp
        if (gifters[msg.sender].donatedAmount > 0) {
            gifters[msg.sender].lastClaimed = block.timestamp;
        }

        totalWithdraw += _amount;

        emit ClaimReward(msg.sender, _amount, block.timestamp);
    }
    /**
     * @notice function to get total withdraw amount in current batch
     */
    function getBatchWithdrawAmount() external view returns (uint256) {
        return batchWithdrawAmounts[currentBatch].batchAmount;
    }
    /**
     * @notice function to gettotal withdraw amount in last batch
     */
    function getLastBatchWithdraw() external view returns (uint256) {
        return batchWithdrawAmounts[currentBatch].lastBatchWithdraw;
    }
}