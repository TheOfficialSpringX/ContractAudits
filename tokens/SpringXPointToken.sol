// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SpringXPointToken is ERC20, Ownable {

    // Authorized minter addresses (e.g. Farm contract)
    mapping(address => bool) public minters;

    event MinterUpdated(address indexed minter, bool enabled);

    modifier onlyMinter() {
        require(
            msg.sender == owner() || minters[msg.sender],
            "PointToken: caller is not owner or minter"
        );
        _;
    }

    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {}

    /// @notice Add or remove an authorized minter, only callable by owner
    /// @param minter_ Target address (e.g. Farm contract)
    /// @param enabled_ true = grant minting permission, false = revoke
    function setMinter(address minter_, bool enabled_) external onlyOwner {
        require(minter_ != address(0), "PointToken: zero address");
        minters[minter_] = enabled_;
        emit MinterUpdated(minter_, enabled_);
    }

    /// @notice Mint tokens, callable by owner or authorized minters
    /// @param to_ Recipient address
    /// @param amount_ Amount to mint
    function mint(address to_, uint256 amount_) external onlyMinter {
        _mint(to_, amount_);
    }
}
