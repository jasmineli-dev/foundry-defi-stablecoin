// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version //pragma solidity ^0.8.19;
// imports //import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol"; import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/*
 * @title DecentralizedStableCoin
 * @author Patrick Collins
 * Collateral: Exogenous
 * Minting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto
 *
 * This is the contract meant to be owned by DSCEngine. It is an ERC20 token that can be minted and burned by the DSCEngine smart contract.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin_InvalidBurnAmount();
    error DecentralizedStableCoin_InsufficientBalance();
    error DecentralizedStableCoin_InvalidMintAmount();
    error DecentralizedStableCoin_MintToZeroAddress();

    constructor() ERC20("Decentralized Stable Coin", "DSC") {}
    

    function burn(uint256 amount) public override onlyOwner {
        //In OpenZeppelin’s ERC20Burnable, there is a burn function defined with virtual decorator.
        uint256 balance = balanceOf(msg.sender);
        if (amount <= 0) {
            revert DecentralizedStableCoin_InvalidBurnAmount();
        }
        if (balance < amount) {
            revert DecentralizedStableCoin_InsufficientBalance();
        }
        super._burn(msg.sender, amount);
    }

    function mint(
        address _to,
        uint256 _amount
    ) public onlyOwner returns (bool) {
        //In OpenZeppelin’s ERC20, there is a _mint function only.
        if (_to == address(0)) {
            revert DecentralizedStableCoin_MintToZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin_InvalidMintAmount();
        }
        _mint(_to, _amount);
        return true;
    }
}
