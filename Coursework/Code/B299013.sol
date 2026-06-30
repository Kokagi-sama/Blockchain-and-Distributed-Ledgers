// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Imports the standard interface for an ERC721 NFT.
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// Imports the interface required for the contract to safely receive an NFT.
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// This contract implements the receiver interface, allowing it to hold an NFT during the auction.
contract VickreyAuction is IERC721Receiver {

    // State Variables
    // Stores the address of the ClassNFT contract. It's set once and unchangeable.
    IERC721 public immutable nftContract;

    // A custom data structure to hold all information about a single auction.
    struct Auction{
        address payable seller;         // The person selling the NFT.
        uint256 nftTokenId;             // The unique ID of the NFT being sold.
        uint256 reservePrice;           // The minimum price the seller will accept.
        uint256 biddingEndTime;         // The timestamp when the commit/bidding phase ends.
        uint256 revealEndTime;          // The timestamp when the reveal phase ends.
        bool isActive;                    // The flag to check activity of the auction.
        bool isFinalised;                 // The flag to check whether auction has been finalised.
        address payable highestBidder;  // The current winning bidder.
        uint256 highestBid;             // The highest bid amount revealed so far.
        uint256 secondHighestBid;       // The second-highest bid amount revealed.
        uint256 highestBidCommitBlock;  // The block number of the highest bid, used for tie-breaking.
    }

    // A custom data structure to hold a bidder's information for an auction.
    struct Bid{
        bytes32 commitment;            // The user's hashed bid (keccak256(amount, nonce)).
        uint256 deposit;               // The total Wei the bidder locked up with their bid.
        uint256 commitBlock;           // The block number when the bid was committed.
        bool isRevealed;                 // The flag to check whether bid was revealed.
    }

    // A counter to give each new auction a unique ID. Not using counters library since version ^0.8 prevents underflow/overflow
    uint256 public auctionCounter;

    // Mappings
    // A mapping from an auction's ID to its Auction data.
    mapping(uint256 => Auction) public auctions;

    // A nested mapping from an auction ID to bidder's address to bidder's Bid data.
    mapping(uint256 => mapping(address => Bid)) public bids;

    // A mapping to track how much Wei each address is owed from auctions.
    // This is for the "pull" withdrawal pattern, which is more secure.
    mapping(address => uint256) public pendingWithdrawals;

    // Events
    // Logs the creation and key details of a new auction.
    event AuctionStarted(
        uint256 indexed auctionId,
        address indexed seller,
        uint256 indexed nftTokenId,
        uint256 reservePrice,
        uint256 biddingEndTime,
        uint256 revealEndTime
    );

    // Logs that a bidder has submitted their hidden (committed) bid.
    event BidCommitted(
        uint256 indexed auctionId,
        address indexed bidder,
        bytes32 commitment
    );

    // Logs that a bidder has successfully revealed their bid amount.
    event BidRevealed(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount
    );

    // Logs the final outcome of an auction, including the winner and final price.
    event AuctionFinalised(
        uint256 indexed auctionId,
        address winner,
        uint256 paymentAmount
    );

    // Logs a successful withdrawal of funds by a specific user.
    event FundsWithdrawn(
        address indexed user,
        uint256 amount
    );

    // Functions
    // The constructor runs once when the contract is deployed.
    // It permanently sets the address of the ClassNFT contract.
    constructor(address _nftContract) {
        // Pass the address of ClassNFT.sol (0x1546Bd67237122754D3F0CB761c139f81388b210)
        require(_nftContract != address(0), "Invalid NFT contract address.");
        nftContract = IERC721(_nftContract);
    }

    // This function is required by IERC721Receiver. It allows the contract
    // to accept an NFT from the safeTransferFrom function.
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    // Creates a new auction.
    function startAuction(
        uint256 _tokenId,          // The ID of the NFT to be auctioned off.
        uint256 _reservePrice,     // The minimum price.
        uint256 _biddingDuration,  // How long the bidding phase lasts (seconds).
        uint256 _revealDuration    // How long the reveal phase lasts (seconds).
    ) external {
        // Checks that the person starting the auction is the real owner of the NFT.
        require(nftContract.ownerOf(_tokenId) == msg.sender, "Not the NFT's owner.");
        require(_biddingDuration > 0, "Bidding duration must be more than 0.");
        require(_revealDuration > 0, "Reveal duration must be more than 0.");

        // Checks that the contract is approved to take the NFT.
        require( nftContract.getApproved(_tokenId) == address(this) 
            || nftContract.isApprovedForAll(msg.sender, address(this)),
            "Contract not approved for this NFT."
        );

        // Transfers the NFT from the seller into this contract, which acts as a secure escrow.
        nftContract.safeTransferFrom(msg.sender, address(this), _tokenId);

        // Sets up the new auction's data in storage.
        uint256 auctionId = auctionCounter;
        Auction storage newAuction = auctions[auctionId];

        newAuction.seller = payable(msg.sender);
        newAuction.nftTokenId = _tokenId;
        newAuction.reservePrice = _reservePrice;
        newAuction.biddingEndTime = block.timestamp + _biddingDuration;
        newAuction.revealEndTime = newAuction.biddingEndTime + _revealDuration;
        newAuction.isActive = true;
        newAuction.isFinalised = false;

        // Increments the counter so the next auction gets a new ID.
        auctionCounter++;

        emit AuctionStarted(
            auctionId, 
            newAuction.seller, 
            newAuction.nftTokenId, 
            newAuction.reservePrice, 
            newAuction.biddingEndTime, 
            newAuction.revealEndTime
        );
    }

    // Allows a bidder to commit their hashed bid and deposit.
    function commitBid(
        uint256 _auctionId,  // The ID of the auction to bid on.
        bytes32 _commitment  // The hashed bid (keccak256(amount, nonce)).
    ) external payable {
        Auction storage auction = auctions[_auctionId];

        // Checks to ensure the auction is in a valid state for bidding.
        require(msg.sender != auction.seller, "Seller cannot bid.");
        require(auction.isActive, "Auction not active.");
        require(block.timestamp < auction.biddingEndTime, "Bidding phase over.");

        // Check to ensure a bidder can only commit once.
        require(bids[_auctionId][msg.sender].commitment == bytes32(0), "Bid has already been committed.");

        require(msg.value > 0, "Deposit must be more than 0");
        require(_commitment != bytes32(0), "Commitment cannot be zero");

        // Stores the bidder's information.
        Bid storage newBid = bids[_auctionId][msg.sender];
        newBid.commitment = _commitment;
        newBid.deposit = msg.value;         // msg.value is the amount of Wei sent.
        newBid.commitBlock = block.number;  // Stores the block number for tie-breaking.
        newBid.isRevealed = false;

        emit BidCommitted(_auctionId, msg.sender, newBid.commitment);
    }

    // Allows a bidder to reveal their actual bid amount and nonce.
    function revealBid(
        uint256 _auctionId,  // The auction ID.
        uint256 _bidAmount,  // The real bid amount.
        bytes32 _nonce       // The secret random string.
    ) external {
        Auction storage auction = auctions[_auctionId];
        Bid storage bid = bids[_auctionId][msg.sender];

        // Checks to ensure the auction is in the correct reveal phase.
        require(auction.isActive, "Auction not active.");
        require(block.timestamp > auction.biddingEndTime, "Bidding phase not over.");
        require(block.timestamp < auction.revealEndTime, "Reveal phase over.");

        // Checks that the bidder has a committed bid to reveal.
        require(bid.commitment != 0, "No bid committed");
        require(!bid.isRevealed, "Bid already revealed");

        // Recalculate and check the hash to see if it matches the one committed earlier.
        bytes32 commitment = keccak256(abi.encodePacked(_bidAmount, _nonce));
        require(bid.commitment == commitment, "Invalid reveal");

        // Check if the revealed amount is covered by their deposit.
        require(bid.deposit >= _bidAmount, "Deposit less than required amount");

        // Marks the bid as revealed to prevent revealing again.
        bid.isRevealed = true;

        // Check if bid meet reserve price threshold.
        if(_bidAmount < auction.reservePrice){
            emit BidRevealed(_auctionId, msg.sender, _bidAmount);
            return; //Exit the function early
        }

        // Winner Determination Logic
        // If current bid is the new highest
        if(_bidAmount > auction.highestBid) {
            // The old highest bid becomes the new second-highest.
            auction.secondHighestBid = auction.highestBid;
            // This bid becomes the new highest.
            auction.highestBid = _bidAmount;
            auction.highestBidder = payable(msg.sender);
            auction.highestBidCommitBlock = bid.commitBlock;

        // If this bid is tied with the current highest
        } else if (_bidAmount == auction.highestBid) {

            // TIE-BREAKING RULE: Check if this bid was committed in an earlier block.
            if (bid.commitBlock < auction.highestBidCommitBlock) {
                // Current bid wins the tie breaking
                auction.secondHighestBid = auction.highestBid; // The tied amount is now second-highest.
                auction.highestBidder = payable(msg.sender);
                auction.highestBidCommitBlock = bid.commitBlock;
            } else {
                //Old bid comes first, the current bid is now second highest
                auction.secondHighestBid = _bidAmount;
            }
        // If current bid is not the highest, but is higher than the current second-highest
        } else if (_bidAmount > auction.secondHighestBid) {
            // Current bid becomes the new second-highest bid.
            auction.secondHighestBid = _bidAmount;
        }

        emit BidRevealed(_auctionId, msg.sender, _bidAmount);
    }

    // Finalises the auction, calculates the winner and price, and handles refunds.
    function finalisedAuction(
        uint256 _auctionId  // The auction ID to end.
    ) external {
        Auction storage auction = auctions[_auctionId];

        // Checks to ensure the auction can be finalised.
        require(auction.isActive, "Auction not active.");
        require(block.timestamp > auction.revealEndTime, "Reveal phase not over.");
        require(!auction.isFinalised, "Auction already finalised");

        // Marks the auction as finished so this can't be run again.
        auction.isFinalised = true;
        auction.isActive = false;

        address payable winner = auction.highestBidder;
        uint256 paymentAmount = 0;

        // Check if there was a winner, at least one valid bid above reserve.
        if (winner != address(0)){

            // Second-Price Logic
            if (auction.secondHighestBid == 0) {
                // If only one bid, the winner pays the reserve price.
                paymentAmount = auction.reservePrice;
            } else {
                 // If multiple bids, winner pays  the max between second-highest and reserve price.
                paymentAmount = (auction.secondHighestBid > auction.reservePrice) ? auction.secondHighestBid : auction.reservePrice;
            }

            // Credit the seller's internal account. They can withdraw this later.
            pendingWithdrawals[auction.seller] += paymentAmount;

            // Calculate the winner's refund (Deposit - Price Paid).
            uint256 winnerDeposit = bids[_auctionId][winner].deposit;
            uint256 winnerRefund = winnerDeposit - paymentAmount;

            // If the winner is owed a refund, credit their internal account.
            if (winnerRefund > 0){
                pendingWithdrawals[winner] += winnerRefund;
            }
        }

        emit AuctionFinalised(_auctionId, winner, paymentAmount); 

        // NFT Transfer
         // If there's a winner, send them the NFT.
        if (winner != address(0)) {
            nftContract.safeTransferFrom(
                address(this),
                winner,
                auction.nftTokenId
            );
        
        // If no winner, return the NFT to the seller.
        } else {
            nftContract.safeTransferFrom(
                address(this),
                auction.seller,
                auction.nftTokenId
            );
        }        
    }

    // Allows losing bidders to make their deposits claimable by transferring their deposits to withdrawable balance.
    function claimLosingBid(
        uint256 _auctionId  // The auction they bid in.
    ) external {
        Auction storage auction = auctions[_auctionId];

        // Checks that the auction is over and the caller is not the winner.
        require(auction.isFinalised, "Auction not finalised");
        require(msg.sender != auction.highestBidder, "Winner cannot claim refund here");

        Bid storage bid = bids[_auctionId][msg.sender];
        uint256 amount = bid.deposit;

        require(amount > 0, "No deposit to claim");

        // Set deposit to 0 before adding to withdrawal list.
        // This prevents a re-entrancy attack where they could claim multiple times.
        bid.deposit = 0;

        // Credit the bidder's internal account.
        pendingWithdrawals[msg.sender] += amount;
    }

    // Allows any user to withdraw their balance from the contract.
    // This is the "pull" part of the secure pull-over-push pattern.
    function withdrawFunds() external{
        // Get the amount this user is owed.
        uint256 amount = pendingWithdrawals[msg.sender];

        require(amount > 0, "No funds to withdraw");

        // Set their internal balance to 0 before sending the Wei.
        // This is the most critical part of preventing re-entrancy attacks.
        pendingWithdrawals[msg.sender] = 0;

        // Send the Wei to the user.
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        emit FundsWithdrawn(msg.sender, amount);
    }
}