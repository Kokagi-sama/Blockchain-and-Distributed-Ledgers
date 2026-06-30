# Vickrey (Second-Price Sealed-Bid) NFT Auction

This project implements a secure **Vickrey (Second-Price Sealed-Bid) Auction** system for ERC721 NFTs. It is designed to be compiled and deployed using **Remix IDE** and includes a web-based utility to help bidders generate the required cryptographic commitments.

The project consists of three main components:
1. **Vickrey Auction Contract (B299013.sol)**: The main smart contract that handles the commit-reveal auction logic, escrow, and second-price settlement.
2. **Class NFT Contract (ClassNFT.sol)**: A standard ERC721 contract with URI storage, used to mint the NFTs being auctioned.
3. **Bid Commitment Generator (BidAmountGenerator.html)**: A standalone HTML/JS tool that allows bidders to securely generate their secret nonce and the required keccak256 commitment hash without exposing their bid amount.

---

## Table of Contents
- [Folder Structure](#folder-structure)
- [Prerequisites](#prerequisites)
- [Step-by-Step Usage Guide](#step-by-step-usage-guide)
- [Security Considerations](#security-considerations)

## Folder Structure

Coursework/
├── Code/
│   ├── B299013.sol              # The main Vickrey auction smart contract
│   ├── BidAmountGenerator.html  # Web-based tool to generate bid commitments
│   └── ClassNFT.sol             # The ERC721 NFT contract used for minting
├── Images/                      # Images for the report/documentation
├── Report/                      # Project report files
├── addresses.txt                # Deployed contract addresses
├── exampleMetadata.json         # Example NFT metadata
├── transactions.txt             # Transaction records
├── LICENSE                      # License file
└── README.md                    # This file

---

## Prerequisites

No local blockchain or Node.js installation is required. You only need:
1. **Remix IDE**: Access it via your browser at https://remix.ethereum.org/
2. **A Modern Web Browser**: To open the BidAmountGenerator.html file locally (Chrome, Firefox, Edge, etc.)
3. **Remix VM or Testnet Wallet**: You can use the default "Remix VM" for local testing, or connect MetaMask to a testnet (like Sepolia) if deploying to a live network.

---

## Step-by-Step Usage Guide

### 1. Deploy the NFT Contract
1. In Remix IDE, navigate to the Code folder and open ClassNFT.sol
2. Go to the **Solidity Compiler** tab, select compiler version ^0.8.0, and compile the contract
3. Go to the **Deploy & Run Transactions** tab
4. Select ClassNFT from the contract dropdown and click **Deploy**
5. **Copy the deployed contract address** from the "Deployed Contracts" section at the bottom left

### 2. Mint an NFT
1. In the deployed ClassNFT section in Remix, find the safeMint function
2. Enter a metadata URI (e.g., "https://example.com/metadata.json") and click **transact**
3. Note the tokenId returned in the transaction details (usually 0 for the first mint)

### 3. Deploy the Auction Contract
1. In Remix, open the B299013.sol file from the Code folder
2. Compile the contract
3. In the **Deploy & Run Transactions** tab, select the VickreyAuction contract
4. In the deploy input field, **paste the address of the deployed ClassNFT contract** from Step 1
5. Click **Deploy**

### 4. Start an Auction
1. First, you must approve the auction contract to transfer your NFT. In the deployed ClassNFT section, call the approve function:
   - to: The address of the deployed VickreyAuction contract
   - tokenId: The ID of the NFT you minted (e.g., 0)
2. Next, in the deployed VickreyAuction section, call the startAuction function:
   - _tokenId: The ID of the NFT (e.g., 0)
   - _reservePrice: Minimum acceptable bid in Wei (e.g., 100000000000000000 for 0.1 ETH)
   - _biddingDuration: Duration of the commit phase in seconds (e.g., 300 for 5 mins)
   - _revealDuration: Duration of the reveal phase in seconds (e.g., 300 for 5 mins)

### 5. Generate a Bid Commitment
Note: This step is done outside of Remix, in your web browser.
1. Open the BidAmountGenerator.html file (located in the Code folder) in your web browser
2. Enter your secret **Bid Amount** and select the unit (e.g., Ether, Gwei, Wei)
3. Click **Generate Nonce & Calculate Commitment**
4. **CRITICAL:** The tool will generate three things. You must save the **Nonce** and the **Final Bid Amount in Wei** securely! You will need them to reveal your bid later.
5. Copy the generated **Commitment Hash**

### 6. Commit and Reveal Bids

**Committing:**
1. Back in Remix, go to the deployed VickreyAuction contract
2. At the top of the Deploy tab, set the **Value** field to your deposit amount (must be >= your actual bid amount) and ensure the unit is **Wei**
3. Call the commitBid function:
   - _auctionId: The ID of the auction (usually 0 for the first auction)
   - _commitment: Paste the **Commitment Hash** you generated in Step 5
4. Repeat Steps 5 & 6 for multiple bidders (using different Remix test accounts) to simulate a real auction

**Revealing (After the bidding phase ends):**
1. Wait for the biddingEndTime to pass
2. In Remix, call the revealBid function for each bidder:
   - _auctionId: The auction ID
   - _bidAmount: The exact **Final Bid Amount in Wei** you saved from the HTML tool
   - _nonce: The exact **Nonce** you saved from the HTML tool

### 7. Finalize Auction and Withdraw
1. Wait for the revealEndTime to pass
2. Call the finalisedAuction function in Remix with the _auctionId. This will calculate the winner (who pays the second-highest bid), transfer the NFT to the winner, and credit the internal balances
3. Losing bidders must first call claimLosingBid with the _auctionId to move their deposit to their withdrawable balance
4. Finally, the seller, the winner (for their change), and the losing bidders can call withdrawFunds to withdraw their respective ETH balances from the contract

---

## Security Considerations

- **Commit-Reveal Scheme**: Bids are hidden during the bidding phase using keccak256 hashes, preventing front-running and bid sniping
- **Pull Payment Pattern**: Funds are not pushed to users automatically. Users must call withdrawFunds() to claim their money, which prevents reentrancy attacks and gas limit issues
- **Reentrancy Protection**: State changes (like zeroing out balances) are executed before any external ETH transfers
- **Tie-Breaking**: If two bids are identical, the contract fairly resolves the tie by awarding the win to the bid that was committed in the earlier block number
- **Secure Escrow**: The NFT is safely locked inside the auction contract and is only transferred to the winner (or returned to the seller) upon finalization
