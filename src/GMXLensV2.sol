// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable }from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./MarketDataTypes.sol";

import {IReader} from "./Interfaces/IReader.sol";
import {IPriceFeed} from "./Interfaces/IPriceFeed.sol";
import {IDataStore} from "./Interfaces/IDataStore.sol";
import {IOracle} from "./Interfaces/IOracle.sol";
import {MarketPoolValueInfo} from "./MarketPoolValueInfo.sol";
import {Market} from "./Market.sol";
import {Price} from "./Price.sol";
import {Keys} from "./Keys.sol";

interface IVault {
    function poolAmounts(address _token) external view returns (uint256);
}

interface IOrderStoreUtils {
    function IS_LONG() external view returns (bytes32);
}

interface IDepositStoreUtils {
    function INITIAL_LONG_TOKEN() external view returns (bytes32);
    function INITIAL_LONG_TOKEN_AMOUNT() external view returns (bytes32);
    function INITIAL_SHORT_TOKEN() external view returns (bytes32);
    function INITIAL_SHORT_TOKEN_AMOUNT() external view returns (bytes32);
}

interface IMarketStoreUtils {
    function INDEX_TOKEN() external view returns (bytes32);
    function LONG_TOKEN() external view returns (bytes32);
    function SHORT_TOKEN() external view returns (bytes32);
}

interface IPositionStoreUtils {
    function BORROWING_FACTOR() external view returns (bytes32);
}

contract GMXLensV2 is MarketDataTypes, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    address private orderStoreAddr;
    address private depositStoreAddr;
    address private marketStoreAddr;
    address private positionStoreAddr;
    address private dataStoreAddr;
    address private readerAddr;
    address private oracleAddr;

    IReader private reader; 

    address immutable _owner;

    constructor() {
        orderStoreAddr = 0x97BeB5A20FBd4596c8B19a89Ec399a100e57d14d;
        depositStoreAddr = 0x98e86155abf8bCbA566b4a909be8cF4e3F227FAf;
        marketStoreAddr = 0x5a1344252f0CdfDB765DD5ab97C98734f1D7ED6d;
        positionStoreAddr = 0x4a57C9b3d6c96954e397Cc186F98fCD2816A95C7;
        readerAddr = 0xdA5A70c885187DaA71E7553ca9F728464af8d2ad;
        dataStoreAddr = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
        oracleAddr = 0xa11B501c2dd83Acd29F6727570f2502FAaa617F2;

        reader = IReader(readerAddr);

        _disableInitializers();
    }   

    function initialize() public initializer  {
        __Ownable_init(msg.sender);

    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function getMarketData(address marketID) external view returns (MarketDataState memory) {
        // bytes32 borrowingFactor = positionStoreUtils.BORROWING_FACTOR();
        // address borrowingFactorAddress = address(uint160(uint256(borrowingFactor)));
        IDataStore(dataStoreAddr).getUint(Keys.MAX_PNL_FACTOR_FOR_TRADERS);

        Market.Props memory marketProps = reader.getMarket(dataStoreAddr, 0x2b477989A149B17073D9C9C82eC9cB03591e20c6);
                        
        Price.MarketPrices memory marketPrices = Price.MarketPrices(getTokenPrice(marketProps.indexToken), getTokenPrice(marketProps.longToken), getTokenPrice(marketProps.shortToken));

        (,MarketPoolValueInfo.Props memory marketPoolValueInfo) = reader
            .getMarketTokenPrice(
                dataStoreAddr,
                marketProps,
                marketPrices.indexTokenPrice,
                marketPrices.longTokenPrice,
                marketPrices.shortTokenPrice,
                Keys.MAX_PNL_FACTOR_FOR_TRADERS,
                true
            );
        
        
        {
            MarketDataState memory state = MarketDataState({
                marketToken: marketID,
                indexToken: marketProps.indexToken,
                longToken: marketProps.longToken,
                shortToken: marketProps.shortToken,
                poolValue: marketPoolValueInfo.poolValue,
                longTokenAmount: marketPoolValueInfo.longTokenAmount,
                longTokenUsd: marketPoolValueInfo.longTokenUsd,
                shortTokenAmount: marketPoolValueInfo.shortTokenAmount,
                shortTokenUsd: marketPoolValueInfo.shortTokenUsd,
                openInterestLong: getOpenInterest(marketProps, true),
                openInterestShort: getOpenInterest(marketProps, false),
                pnlLong: reader.getPnl(dataStoreAddr, marketProps, marketPrices.indexTokenPrice, true, false),
                pnlShort: reader.getPnl(dataStoreAddr, marketProps, marketPrices.indexTokenPrice, false, false),
                netPnl: reader.getNetPnl(dataStoreAddr, marketProps, marketPrices.indexTokenPrice, false)
                // borrowingFactorPerSecondForLongs: 1e18,
                // borrowingFactorPerSecondForShorts: 1e18,
                // longsPayShorts: true,
                // fundingFactorPerSecond: 1e18,
                // fundingFactorPerSecondLongs: 1e18,
                // fundingFactorPerSecondShorts: -1e18,
                // reservedUsdLong: 100,
                // reservedUsdShort: 100,
                // maxOpenInterestUsdLong: 10000,
                // maxOpenInterestUsdShort: 10000
            });

            return state;
        }
    }

    /** @dev the long and short open interest for a market based on the collateral token used
        @param market the market to check
        @param collateralToken the collateral token to check
        @param isLong whether to check the long or short side
        @param divisor divisor for market
    */
    function getOpenInterest(
        address market,
        address collateralToken,
        bool isLong,
        uint256 divisor
    ) internal view returns (uint256) {
        return
            IDataStore(dataStoreAddr).getUint(
                Keys.openInterestKey(market, collateralToken, isLong)
            ) / divisor;
    }

    /** @dev get either the long or short open interest for a market
     *  @param market the market to check
     *  @param isLong whether to get the long or short open interest
     *  @return the long or short open interest for a market
     */
    function getOpenInterest(
        Market.Props memory market,
        bool isLong
    ) internal view returns (uint256) {
        uint256 divisor = market.longToken == market.shortToken ? 2 : 1;
        uint256 openInterestUsingLongTokenAsCollateral = getOpenInterest(
            market.marketToken,
            market.longToken,
            isLong,
            divisor
        );
        uint256 openInterestUsingShortTokenAsCollateral = getOpenInterest(
            market.marketToken,
            market.shortToken,
            isLong,
            divisor
        );

        return
            openInterestUsingLongTokenAsCollateral +
            openInterestUsingShortTokenAsCollateral;
    }

    /** @dev get the multiplier value to convert the external price feed price to the price of 1 unit of the token
    represented with 30 decimals
    @param token token to get price feed multiplier for
    */
    function getPriceFeedMultiplier(
        address token
    ) public view returns (uint256) {
        uint256 multiplier = IDataStore(dataStoreAddr).getUint(
            Keys.priceFeedMultiplierKey(token)
        );

        return multiplier;
    }


    /** @dev get the token price by fetching token price from token's price feed address in 30 decimals
        @param token token to get price feed multiplier 
    */
    function getTokenPrice(
        address token
    ) internal view returns (Price.Props memory) {
        IPriceFeed priceFeed = IPriceFeed(
            IDataStore(dataStoreAddr).getAddress(Keys.priceFeedKey(token))
        );

        if (address(priceFeed) == address(0)) {
            Price.Props memory primaryPrice = IOracle(oracleAddr).primaryPrices(
                token
            );
            require(
                primaryPrice.min != 0 && primaryPrice.max != 0,
                "Not able to fetch latest price"
            );
            return primaryPrice;
        }

        uint256 multiplier = getPriceFeedMultiplier(token);

        (, int256 tokenPrice, , , ) = priceFeed.latestRoundData();

        uint256 price = Math.mulDiv(
            SafeCast.toUint256(tokenPrice),
            multiplier,
            10 ** 30
        );
        return Price.Props(price, price);
    }

}
