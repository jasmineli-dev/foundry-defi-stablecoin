// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "../test/mocks/ERC20Mock.sol";
import {console} from "forge-std/console.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address WETH_PriceFeed;
        address WBTC_PriceFeed;
        address WETH_address;
        address WBTC_address;
        uint256 deployerKey; //type uint256
    }

    NetworkConfig public activeNetworkConfig;

    uint8 constant decimals = 8;
    int256 constant initialAnswer_BTC = 2000e8;
    int256 constant initialAnswer_ETH = 2000e8; //2000 × 10^8 Two thousand times ten to the power of eight
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F3C8B8B8B8B8B8B8B;
    // address constant WBTC =
    //     0x4B1fA0B1fA0B1fA0B1fA0B1fA0B1fA0B1fA0B1fA0B1fA0B1fA0B1fA0B1fA0B1;
    // address constant WETH_PriceFeed =
    //     0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    // address constant WBTC_PriceFeed =
    //     0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

    constructor() {
        if (block.chainid == 11155111) {
            //sepolia
            activeNetworkConfig = getSepoliaNetworkConfig();
        } else {
            //Anvil
            activeNetworkConfig = getOrCreateAnvilNetworkConfig();
        }
    }

    function getSepoliaNetworkConfig() public returns (NetworkConfig memory) {
        return
            NetworkConfig({
                WETH_PriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306, // ETH / USD
                WBTC_PriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
                WETH_address: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
                WBTC_address: 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063,
                deployerKey: vm.envUint("PRIVATE_KEY")
            });
    }

    function getOrCreateAnvilNetworkConfig()
        public
        returns (NetworkConfig memory)
    {
        if (activeNetworkConfig.WETH_address != address(0)) {
            return activeNetworkConfig;
        }

        ERC20Mock MockETH = new ERC20Mock(
            "Mock WETH",
            "WETH",
            msg.sender,
            1000e8
        );
        ERC20Mock MockBTC = new ERC20Mock(
            "Mock WBTC",
            "WBTC",
            msg.sender,
            1000e8
        );
        activeNetworkConfig.WETH_address = address(MockETH);
        activeNetworkConfig.WBTC_address = address(MockBTC);
        activeNetworkConfig.WETH_PriceFeed = createMockPriceFeed(
            decimals,
            initialAnswer_ETH
        );
        activeNetworkConfig.WBTC_PriceFeed = createMockPriceFeed(
            decimals,
            initialAnswer_BTC
        );
        activeNetworkConfig.deployerKey = DEFAULT_ANVIL_PRIVATE_KEY;
        return activeNetworkConfig;
    }

    function createMockPriceFeed(
        uint8 _decimals,
        int256 _initialAnswer
    ) public returns (address) {
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(
            _decimals,
            _initialAnswer
        );
        return address(mockPriceFeed);
    }
}
