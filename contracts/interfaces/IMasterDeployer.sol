// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.0;

/// @notice Interface for Trident pool master deployer.
interface IMasterDeployer {
    function barFee() external view returns (uint256);
    
    function barFeeTo() external view returns (address);
    
    function bento() external view returns (address);
}
