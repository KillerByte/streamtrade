// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.7.6;
pragma abicoder v2;

import "hardhat/console.sol";

import {
    ISuperfluid,
    ISuperToken
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
//"@superfluid-finance/ethereum-monorepo/packages/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import {
    IConstantFlowAgreementV1
} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

import "./balancer/BToken.sol";

library StreamSwapLibrary {
    uint public constant BONE              = 10**18;
    uint public constant EXIT_FEE          = 0;
    uint public constant MIN_BPOW_BASE     = 1 wei;
    uint public constant MAX_BPOW_BASE     = (2 * BONE) - 1 wei;
    uint public constant BPOW_PRECISION    = BONE / 10**10;

    struct Context {
        ISuperfluid host; // host
        IConstantFlowAgreementV1 cfa; // the stored constant flow agreement class address
        // output token to input token to receivers
        // only for balancer trade hooks. Limitation for the scalability.

        // use a sparse array to remember changes in the state
        StreamSwapState[] streamSwapState;

        // used for rate updates
        mapping(address => uint64) superTokenToStateIdx;

        // used for getting existing stream configs for accounts
        mapping(address => mapping (address => uint64)) inAccountTokenToStateIdx;

        // used when outgoing stream is deleted, need to delete source streams
        //mapping(address => mapping (address => uint64[])) outAccountTokenToStateIdx;
    }

    struct StreamSwapArgs {
        address destSuperToken;
        uint inAmount;
        uint128 minOut;
    }

    struct StreamSwapState {
        address srcSuperToken;
        address destSuperToken;
        address sender;
        uint inAmount;
        uint128 minOut;
        uint64 active;
        uint64 nextSenderAccount;

        uint64 prevForSrcSuperToken;
        uint64 nextForDestSuperToken;
        uint64 prevForDestSuperToken;
        uint64 nextForSrcSuperToken;
    }

    struct AccountState {
        uint srcBalance;
        uint srcDenom;
        uint destBalance;
        uint destDenom;
    }

    struct Record {
        bool bound;   // is token bound to pool
        uint index;   // private
        uint denorm;  // denormalized weight
        uint balance; // balance (as of last balancer pool operation). this needs to be recorded for remembering relative stream amts
    }

    event SetFlow(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256         tokenRateIn,
        uint128         minOut
    );

    event SetFlowRate(
        address indexed receiver,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256         tokenRateOut
    );

    function decodeStreamSwapData(bytes memory d) internal pure returns (StreamSwapArgs memory ssa) {
        (
            ssa.destSuperToken,
            ssa.inAmount,
            ssa.minOut
        ) = abi.decode(d, (address, uint, uint128));
    }

    function decodeUserData(bytes memory userData) internal pure returns (StreamSwapArgs[] memory) {

        if (userData.length == 0)
            return new StreamSwapArgs[](0);

        (bytes[] memory arr) = abi.decode(userData, (bytes[]));

        StreamSwapArgs[] memory ssas = new StreamSwapArgs[](arr.length);
        for(uint i = 0;i < arr.length;i++) {
            ssas[i] = decodeStreamSwapData(arr[i]);
        }

        return ssas;
    }

    // link entry 1 to entry 2 sequentially in the list for superToken
    function updateSuperTokenPointers(Context storage ctx, address superToken, uint64 idx1, uint64 idx2) internal {

        if (idx1 == 0) {
            ctx.superTokenToStateIdx[superToken] = idx2;
            return;
        }

        if (ctx.streamSwapState[idx1].srcSuperToken == superToken) {
            ctx.streamSwapState[idx1].nextForSrcSuperToken = idx2;
        }
        else {
            ctx.streamSwapState[idx1].nextForDestSuperToken = idx2;
        }

        if (ctx.streamSwapState[idx2].srcSuperToken == superToken) {
            ctx.streamSwapState[idx2].prevForSrcSuperToken = idx1;
        }
        else {
            ctx.streamSwapState[idx2].prevForDestSuperToken = idx1;
        }
    }

    function initialize(Context storage ctx) public {
        ctx.streamSwapState.push(StreamSwapState(address(0), address(0), address(0), 0,0,0,0,0,0,0,0));
    }

    function clearTradeOutWithContext(Context storage ctx, bytes memory newSfCtx, address superToken, address to, uint oldOutRate) private returns (bytes memory) {
        if (superToken != address(0) && oldOutRate > 0) {

            (,int96 prevTokenCurOutFlow,,) = ctx.cfa.getFlow(ISuperToken(superToken), address(this), to);
            console.log("got prev token flow", superToken, uint(prevTokenCurOutFlow), oldOutRate);
            // sanity
            require(uint256(prevTokenCurOutFlow) >= oldOutRate, "ERR_IMPOSSIBLE_RATE");

            if (uint256(prevTokenCurOutFlow) == oldOutRate) {
                console.log("remove previous flow");
                (newSfCtx, ) = ctx.host.callAgreementWithContext(
                    ctx.cfa,
                    abi.encodeWithSelector(
                        ctx.cfa.deleteFlow.selector,
                        superToken,
                        address(this), // for some reason deleteFlow is the only function that takes a sender parameter
                        to,
                        new bytes(0) // placeholder
                    ),
                    "0x",
                    newSfCtx
                );

                console.log("removed");
            }
            else {
                console.log("shrink previous flow");
                (newSfCtx, ) = ctx.host.callAgreementWithContext(
                    ctx.cfa,
                    abi.encodeWithSelector(
                        ctx.cfa.updateFlow.selector,
                        superToken,
                        to,
                        uint256(prevTokenCurOutFlow) - oldOutRate,
                        new bytes(0) // placeholder
                    ),
                    "0x",
                    newSfCtx
                );
            }
        }

        return newSfCtx;
    }

    function adjustTradeOutWithContext(Context storage ctx, bytes memory newSfCtx, address superToken, address to, uint oldOutRate, uint newOutRate) private returns (bytes memory) {
        if (superToken != address(0) && oldOutRate != newOutRate) {

            (,int96 curOutFlow,,) = ctx.cfa.getFlow(ISuperToken(superToken), address(this), to);

            console.log("with context adjust trade out", uint(curOutFlow), oldOutRate, newOutRate);
            (newSfCtx, ) = ctx.host.callAgreementWithContext(
                ctx.cfa,
                abi.encodeWithSelector(
                    curOutFlow == 0 ? ctx.cfa.createFlow.selector : ctx.cfa.updateFlow.selector,
                    superToken,
                    to,
                    uint256(curOutFlow) + newOutRate - oldOutRate,
                    new bytes(0) // placeholder
                ),
                "0x",
                newSfCtx
            );
        }

        return newSfCtx;
    }

    function clearTradeOut(Context storage ctx, address superToken, address to, uint oldOutRate) private {
        if (superToken != address(0) && oldOutRate > 0) {

            (,int96 prevTokenCurOutFlow,,) = ctx.cfa.getFlow(ISuperToken(superToken), address(this), to);
            console.log("got prev token flow", superToken, uint(prevTokenCurOutFlow), oldOutRate);
            // sanity
            require(uint256(prevTokenCurOutFlow) >= oldOutRate, "ERR_IMPOSSIBLE_RATE");

            if (uint256(prevTokenCurOutFlow) == oldOutRate) {
                console.log("remove previous flow");
                ctx.host.callAgreement(
                    ctx.cfa,
                    abi.encodeWithSelector(
                        ctx.cfa.deleteFlow.selector,
                        superToken,
                        address(this), // for some reason deleteFlow is the only function that takes a sender parameter
                        to,
                        new bytes(0) // placeholder
                    ),
                    "0x"
                );

                console.log("removed");
            }
            else {
                console.log("shrink previous flow");
                ctx.host.callAgreement(
                    ctx.cfa,
                    abi.encodeWithSelector(
                        ctx.cfa.updateFlow.selector,
                        superToken,
                        to,
                        uint256(prevTokenCurOutFlow) - oldOutRate,
                        new bytes(0) // placeholder
                    ),
                    "0x"
                );
            }
        }
    }

    function adjustTradeOut(Context storage ctx, address superToken, address to, uint oldOutRate, uint newOutRate) private {
        if (superToken != address(0) && oldOutRate != newOutRate) {

            (,int96 curOutFlow,,) = ctx.cfa.getFlow(ISuperToken(superToken), address(this), to);

            console.log("no context adjust trade out", uint(curOutFlow), newOutRate, oldOutRate);

            ctx.host.callAgreement(
                ctx.cfa,
                abi.encodeWithSelector(
                    curOutFlow == 0 ? ctx.cfa.createFlow.selector : ctx.cfa.updateFlow.selector,
                    superToken,
                    to,
                    uint256(curOutFlow) + newOutRate - oldOutRate,
                    new bytes(0) // placeholder
                ),
                "0x"
            );
        }
    }

    function updateTrade(Context storage ctx, ISuperToken superToken, bytes memory newSfCtx, 
        StreamSwapState memory args, StreamSwapState storage prevArgs,
        AccountState memory state)
        private
        returns (bytes memory)
    {
        if (prevArgs.destSuperToken == address(0) && args.destSuperToken == address(0)) {
            return newSfCtx;
        }

        console.log("state", state.srcBalance, state.destBalance);
        uint oldOutRate = prevArgs.inAmount > 0 ? calcOutGivenIn(
            state.srcBalance, state.srcDenom, 
            state.destBalance, state.destDenom, 
            prevArgs.inAmount, 0) : 0;

        uint newOutRate = args.inAmount > 0 ? calcOutGivenIn(
            state.srcBalance, state.srcDenom, 
            state.destBalance, state.destDenom, 
            args.inAmount, 0) : 0;
        
        // is the trade currently outside its range
        if ((args.minOut != 0 && newOutRate < args.minOut)) {
            console.log("out of range", oldOutRate, newOutRate);
            console.log("rates", uint(args.minOut));
            if (prevArgs.inAmount != args.inAmount || prevArgs.active > 0) {
                console.log("starting inactive");
                if (prevArgs.active > 0) {
                    newSfCtx = clearTradeOutWithContext(ctx, newSfCtx, prevArgs.destSuperToken, prevArgs.sender, oldOutRate);
                }

                newSfCtx = adjustTradeOutWithContext(ctx, newSfCtx, args.srcSuperToken, args.sender, prevArgs.active > 0 ? 0 : prevArgs.inAmount, args.inAmount);

                args.active = 0;
            }

            return newSfCtx;
        }
        else if (prevArgs.active == 0) {
            console.log("starting reactivate");
            newSfCtx = clearTradeOutWithContext(ctx, newSfCtx, prevArgs.srcSuperToken, prevArgs.sender, prevArgs.inAmount);
            oldOutRate = 0;
            args.active = 1;
        }

        if (prevArgs.destSuperToken != args.destSuperToken) {
            console.log("doing replace");
            newSfCtx = clearTradeOutWithContext(ctx, newSfCtx, prevArgs.destSuperToken, prevArgs.sender, oldOutRate);
            if(prevArgs.sender != address(0)) {
                emit SetFlow(prevArgs.sender, address(superToken), prevArgs.destSuperToken, 0, 0);
            }

            newSfCtx = adjustTradeOutWithContext(ctx, newSfCtx, args.destSuperToken, args.sender, 0, newOutRate);
            if(args.sender != address(0)) {
                emit SetFlow(args.sender, address(superToken), args.destSuperToken, args.inAmount, args.minOut);
            }
        }
        else {
            newSfCtx = adjustTradeOutWithContext(ctx, newSfCtx, prevArgs.destSuperToken, prevArgs.sender, oldOutRate, newOutRate);
            emit SetFlow(args.sender, address(superToken), args.destSuperToken, args.inAmount, args.minOut);
        }

        emit SetFlowRate(args.sender, args.srcSuperToken, args.destSuperToken, newOutRate);

        return newSfCtx;
    }

    function makeTrade(Context storage ctx, ISuperToken superToken, bytes memory newSfCtx, mapping(address => StreamSwapLibrary.Record) storage records)
        public
        returns (bytes memory)
    {
        ISuperfluid.Context memory context = ctx.host.decodeCtx(newSfCtx);
        StreamSwapArgs[] memory args = decodeUserData(context.userData);

        console.log("streamswapargs: decoded", args.length);

        uint inSum = 0;

        uint64[2] memory curStateIdx = [ctx.inAccountTokenToStateIdx[context.msgSender][address(superToken)], 0];

        console.log("found existing?", curStateIdx[0] > 0);

        for (uint i = 0;i < args.length;i++) {
            require(args[i].inAmount > 0, "ERR_INVALID_AMOUNT");
            require(args[i].destSuperToken != address(superToken), "ERR_INVALID_OUT_TOKEN");

            inSum += args[i].inAmount;

            AccountState memory state = AccountState(
                records[address(superToken)].balance, records[address(superToken)].denorm, records[address(args[i].destSuperToken)].balance,
                records[address(args[i].destSuperToken)].denorm
            );

            console.log("got super balances", state.srcBalance, state.destBalance);

            if (curStateIdx[0] != 0) {
                // update in place
                StreamSwapState storage entry = ctx.streamSwapState[curStateIdx[0]];
                StreamSwapState memory newEntry = StreamSwapState({
                    srcSuperToken: address(superToken),
                    destSuperToken: args[i].destSuperToken,
                    sender: context.msgSender,
                    inAmount: args[i].inAmount,
                    minOut: args[i].minOut,

                    prevForSrcSuperToken: 0,
                    nextForSrcSuperToken: 0,
                    prevForDestSuperToken: 0,
                    nextForDestSuperToken: 0,
                    nextSenderAccount: 0,
                    active: entry.active
                });
                newSfCtx = updateTrade(ctx, superToken, newSfCtx, newEntry, entry, state);

                // update dest super token if it has changed
                if (args[i].destSuperToken != entry.destSuperToken) {
                    updateSuperTokenPointers(ctx, entry.destSuperToken, entry.prevForDestSuperToken, entry.nextForDestSuperToken);

                    entry.destSuperToken = args[i].destSuperToken;
                    uint64 prevHead = ctx.superTokenToStateIdx[args[i].destSuperToken];
                    updateSuperTokenPointers(ctx, args[i].destSuperToken, curStateIdx[0], prevHead);
                    updateSuperTokenPointers(ctx, args[i].destSuperToken, 0, curStateIdx[0]);
                }

                // update args
                entry.inAmount = args[i].inAmount;
                entry.minOut = args[i].minOut;

                // could be a side effect from the updateTrade function
                entry.active = newEntry.active;

                curStateIdx[1] = curStateIdx[0];
                curStateIdx[0] = entry.nextSenderAccount;
            }
            else {
                // new stream swap

                StreamSwapState memory newEntry = StreamSwapState({
                    srcSuperToken: address(superToken),
                    destSuperToken: args[i].destSuperToken,
                    sender: context.msgSender,
                    inAmount: args[i].inAmount,
                    minOut: args[i].minOut,

                    prevForSrcSuperToken: 0,
                    nextForSrcSuperToken: ctx.superTokenToStateIdx[address(superToken)],
                    prevForDestSuperToken: 0,
                    nextForDestSuperToken: ctx.superTokenToStateIdx[args[i].destSuperToken],
                    nextSenderAccount: 0,
                    active: 1
                });

                StreamSwapState storage emptyEntry = ctx.streamSwapState[0];

                newSfCtx = updateTrade(ctx, superToken, newSfCtx, newEntry, emptyEntry, state);

                ctx.streamSwapState.push(newEntry);

                uint64 pos = uint64(ctx.streamSwapState.length - 1);

                if (curStateIdx[1] > 0) {
                    ctx.streamSwapState[curStateIdx[1]].nextSenderAccount = pos;
                }
                else {
                    ctx.inAccountTokenToStateIdx[context.msgSender][address(superToken)] = pos;
                }

                updateSuperTokenPointers(ctx, address(superToken), pos, newEntry.nextForSrcSuperToken);
                updateSuperTokenPointers(ctx, address(superToken), 0, pos);

                updateSuperTokenPointers(ctx, args[i].destSuperToken, pos, newEntry.nextForDestSuperToken);
                updateSuperTokenPointers(ctx, args[i].destSuperToken, 0, pos);

                curStateIdx[1] = pos;
            }
        }

        console.log("done with existing ids");

        while (curStateIdx[0] != 0) {
            console.log("pop");

            StreamSwapState storage entry = ctx.streamSwapState[curStateIdx[0]];

            AccountState memory state = AccountState(
                records[address(superToken)].balance, records[address(superToken)].denorm, 
                records[address(entry.destSuperToken)].balance, 
                records[address(entry.destSuperToken)].denorm
            );

            newSfCtx = updateTrade(ctx, superToken, newSfCtx, ctx.streamSwapState[0], entry, state);

            // src super token list
            updateSuperTokenPointers(ctx, address(superToken), entry.prevForSrcSuperToken, entry.nextForSrcSuperToken);
            updateSuperTokenPointers(ctx, entry.destSuperToken, entry.prevForDestSuperToken, entry.nextForDestSuperToken);

            uint64 nextStateIdx = entry.nextSenderAccount;
            ctx.streamSwapState[curStateIdx[0]] = ctx.streamSwapState[0];

            if(curStateIdx[1] > 0) {
                ctx.streamSwapState[curStateIdx[1]].nextSenderAccount = 0;
            }
            else {
                ctx.inAccountTokenToStateIdx[context.msgSender][address(superToken)] = 0;
            }

            curStateIdx[0] = nextStateIdx;
        }

        console.log("final check");

        (,int96 inFlow,,) = ctx.cfa.getFlow(superToken, context.msgSender, address(this));
        require(inSum == uint256(inFlow), "ERR_INVALID_SUM");

        return newSfCtx;
    }

    function updateFlowRates(Context storage ctx, address superToken, mapping(address => StreamSwapLibrary.Record) storage records, StreamSwapLibrary.Record memory prevRecord)
        public
    {
        uint curIdx = ctx.superTokenToStateIdx[superToken];

        console.log("update flow rates");

        while (curIdx > 0) {
            console.log("doing one", curIdx);
            StreamSwapState storage entry = ctx.streamSwapState[curIdx];

            // this is basically a shorter version of what happens in the updateTrade above
            // except it just calls raw `callAgreement` and saves gas

            uint oldOutRate;
            uint newOutRate;
            if(superToken == entry.srcSuperToken) {
                oldOutRate = calcOutGivenIn(
                    prevRecord.balance, prevRecord.denorm, 
                    records[entry.destSuperToken].balance, records[entry.destSuperToken].denorm, 
                    entry.inAmount, 0);

                newOutRate = calcOutGivenIn(
                    records[superToken].balance, records[superToken].denorm, 
                    records[entry.destSuperToken].balance, records[entry.destSuperToken].denorm, 
                    entry.inAmount, 0);
                
                curIdx = entry.nextForSrcSuperToken;
            }
            else {
                oldOutRate = calcOutGivenIn(
                    records[entry.srcSuperToken].balance, records[entry.srcSuperToken].denorm, 
                    prevRecord.balance, prevRecord.denorm, 
                    entry.inAmount, 0);

                newOutRate = calcOutGivenIn(
                    records[entry.srcSuperToken].balance, records[entry.srcSuperToken].denorm, 
                    records[superToken].balance, records[superToken].denorm, 
                    entry.inAmount, 0);
                
                curIdx = entry.nextForDestSuperToken;
            }

            // is the trade currently outside its range
            if ((entry.minOut != 0 && newOutRate < entry.minOut)) {
            console.log("out of range", oldOutRate, newOutRate);
            console.log("rates", uint(entry.minOut));
                if (entry.active > 0) {
                    console.log("starting deactivate");
                    clearTradeOut(ctx, entry.destSuperToken, entry.sender, oldOutRate);
                    adjustTradeOut(ctx, entry.srcSuperToken, entry.sender, 0, entry.inAmount);

                    entry.active = 0;
                }

                continue;
            }
            else if (entry.active == 0) {
                console.log("starting reactivate");
                clearTradeOut(ctx, entry.srcSuperToken, entry.sender, entry.inAmount);
                adjustTradeOut(ctx, entry.destSuperToken, entry.sender, 0, newOutRate);
                entry.active = 1;
            }
            else {
                console.log("change out rate", oldOutRate, newOutRate);
                adjustTradeOut(ctx, entry.destSuperToken, entry.sender, oldOutRate, newOutRate);
            }

            emit SetFlowRate(entry.sender, entry.srcSuperToken, entry.destSuperToken, newOutRate);
        }

        console.log("finished update");
    }

    /**********************************************************************************************
    // calcSpotPrice                                                                             //
    // sP = spotPrice                                                                            //
    // bI = tokenBalanceIn                ( bI / wI )         1                                  //
    // bO = tokenBalanceOut         sP =  -----------  *  ----------                             //
    // wI = tokenWeightIn                 ( bO / wO )     ( 1 - sF )                             //
    // wO = tokenWeightOut                                                                       //
    // sF = swapFee                                                                              //
    **********************************************************************************************/
    function calcSpotPrice(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint swapFee
    )
        public pure
        returns (uint spotPrice)
    {
        uint numer = bdiv(tokenBalanceIn, tokenWeightIn);
        uint denom = bdiv(tokenBalanceOut, tokenWeightOut);
        uint ratio = bdiv(numer, denom);
        uint scale = bdiv(BONE, bsub(BONE, swapFee));
        return  (spotPrice = bmul(ratio, scale));
    }

    /**********************************************************************************************
    // calcOutGivenIn                                                                            //
    // aO = tokenAmountOut                                                                       //
    // bO = tokenBalanceOut                                                                      //
    // bI = tokenBalanceIn              /      /            bI             \    (wI / wO) \      //
    // aI = tokenAmountIn    aO = bO * |  1 - | --------------------------  | ^            |     //
    // wI = tokenWeightIn               \      \ ( bI + ( aI * ( 1 - sF )) /              /      //
    // wO = tokenWeightOut                                                                       //
    // sF = swapFee                                                                              //
    **********************************************************************************************/
    function calcOutGivenIn(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint tokenAmountIn,
        uint swapFee
    )
        public pure
        returns (uint tokenAmountOut)
    {
        uint weightRatio = bdiv(tokenWeightIn, tokenWeightOut);
        uint adjustedIn = bsub(BONE, swapFee);
        adjustedIn = bmul(tokenAmountIn, adjustedIn);
        uint y = bdiv(tokenBalanceIn, badd(tokenBalanceIn, adjustedIn));
        uint foo = bpow(y, weightRatio);
        uint bar = bsub(BONE, foo);
        tokenAmountOut = bmul(tokenBalanceOut, bar);
        return tokenAmountOut;
    }

    /**********************************************************************************************
    // calcInGivenOut                                                                            //
    // aI = tokenAmountIn                                                                        //
    // bO = tokenBalanceOut               /  /     bO      \    (wO / wI)      \                 //
    // bI = tokenBalanceIn          bI * |  | ------------  | ^            - 1  |                //
    // aO = tokenAmountOut    aI =        \  \ ( bO - aO ) /                   /                 //
    // wI = tokenWeightIn           --------------------------------------------                 //
    // wO = tokenWeightOut                          ( 1 - sF )                                   //
    // sF = swapFee                                                                              //
    **********************************************************************************************/
    function calcInGivenOut(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint tokenAmountOut,
        uint swapFee
    )
        public pure
        returns (uint tokenAmountIn)
    {
        uint weightRatio = bdiv(tokenWeightOut, tokenWeightIn);
        uint diff = bsub(tokenBalanceOut, tokenAmountOut);
        uint y = bdiv(tokenBalanceOut, diff);
        uint foo = bpow(y, weightRatio);
        foo = bsub(foo, BONE);
        tokenAmountIn = bsub(BONE, swapFee);
        tokenAmountIn = bdiv(bmul(tokenBalanceIn, foo), tokenAmountIn);
        return tokenAmountIn;
    }

    /**********************************************************************************************
    // calcPoolOutGivenSingleIn                                                                  //
    // pAo = poolAmountOut         /                                              \              //
    // tAi = tokenAmountIn        ///      /     //    wI \      \\       \     wI \             //
    // wI = tokenWeightIn        //| tAi *| 1 - || 1 - --  | * sF || + tBi \    --  \            //
    // tW = totalWeight     pAo=||  \      \     \\    tW /      //         | ^ tW   | * pS - pS //
    // tBi = tokenBalanceIn      \\  ------------------------------------- /        /            //
    // pS = poolSupply            \\                    tBi               /        /             //
    // sF = swapFee                \                                              /              //
    **********************************************************************************************/
    function calcPoolOutGivenSingleIn(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint poolSupply,
        uint totalWeight,
        uint tokenAmountIn,
        uint swapFee
    )
        public pure
        returns (uint poolAmountOut)
    {
        // Charge the trading fee for the proportion of tokenAi
        //  which is implicitly traded to the other pool tokens.
        // That proportion is (1- weightTokenIn)
        // tokenAiAfterFee = tAi * (1 - (1-weightTi) * poolFee);
        uint normalizedWeight = bdiv(tokenWeightIn, totalWeight);
        uint zaz = bmul(bsub(BONE, normalizedWeight), swapFee); 
        uint tokenAmountInAfterFee = bmul(tokenAmountIn, bsub(BONE, zaz));

        uint newTokenBalanceIn = badd(tokenBalanceIn, tokenAmountInAfterFee);
        uint tokenInRatio = bdiv(newTokenBalanceIn, tokenBalanceIn);

        // uint newPoolSupply = (ratioTi ^ weightTi) * poolSupply;
        uint poolRatio = bpow(tokenInRatio, normalizedWeight);
        uint newPoolSupply = bmul(poolRatio, poolSupply);
        poolAmountOut = bsub(newPoolSupply, poolSupply);
        return poolAmountOut;
    }

    /**********************************************************************************************
    // calcSingleInGivenPoolOut                                                                  //
    // tAi = tokenAmountIn              //(pS + pAo)\     /    1    \\                           //
    // pS = poolSupply                 || ---------  | ^ | --------- || * bI - bI                //
    // pAo = poolAmountOut              \\    pS    /     \(wI / tW)//                           //
    // bI = balanceIn          tAi =  --------------------------------------------               //
    // wI = weightIn                              /      wI  \                                   //
    // tW = totalWeight                          |  1 - ----  |  * sF                            //
    // sF = swapFee                               \      tW  /                                   //
    **********************************************************************************************/
    function calcSingleInGivenPoolOut(
        uint tokenBalanceIn,
        uint tokenWeightIn,
        uint poolSupply,
        uint totalWeight,
        uint poolAmountOut,
        uint swapFee
    )
        public pure
        returns (uint tokenAmountIn)
    {
        uint normalizedWeight = bdiv(tokenWeightIn, totalWeight);
        uint newPoolSupply = badd(poolSupply, poolAmountOut);
        uint poolRatio = bdiv(newPoolSupply, poolSupply);
      
        //uint newBalTi = poolRatio^(1/weightTi) * balTi;
        uint boo = bdiv(BONE, normalizedWeight); 
        uint tokenInRatio = bpow(poolRatio, boo);
        uint newTokenBalanceIn = bmul(tokenInRatio, tokenBalanceIn);
        uint tokenAmountInAfterFee = bsub(newTokenBalanceIn, tokenBalanceIn);
        // Do reverse order of fees charged in joinswap_ExternAmountIn, this way 
        //     ``` pAo == joinswap_ExternAmountIn(Ti, joinswap_PoolAmountOut(pAo, Ti)) ```
        //uint tAi = tAiAfterFee / (1 - (1-weightTi) * swapFee) ;
        uint zar = bmul(bsub(BONE, normalizedWeight), swapFee);
        tokenAmountIn = bdiv(tokenAmountInAfterFee, bsub(BONE, zar));
        return tokenAmountIn;
    }

    /**********************************************************************************************
    // calcSingleOutGivenPoolIn                                                                  //
    // tAo = tokenAmountOut            /      /                                             \\   //
    // bO = tokenBalanceOut           /      // pS - (pAi * (1 - eF)) \     /    1    \      \\  //
    // pAi = poolAmountIn            | bO - || ----------------------- | ^ | --------- | * b0 || //
    // ps = poolSupply                \      \\          pS           /     \(wO / tW)/      //  //
    // wI = tokenWeightIn      tAo =   \      \                                             //   //
    // tW = totalWeight                    /     /      wO \       \                             //
    // sF = swapFee                    *  | 1 - |  1 - ---- | * sF  |                            //
    // eF = exitFee                        \     \      tW /       /                             //
    **********************************************************************************************/
    function calcSingleOutGivenPoolIn(
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint poolSupply,
        uint totalWeight,
        uint poolAmountIn,
        uint swapFee
    )
        public pure
        returns (uint tokenAmountOut)
    {
        uint normalizedWeight = bdiv(tokenWeightOut, totalWeight);
        // charge exit fee on the pool token side
        // pAiAfterExitFee = pAi*(1-exitFee)
        uint poolAmountInAfterExitFee = bmul(poolAmountIn, bsub(BONE, EXIT_FEE));
        uint newPoolSupply = bsub(poolSupply, poolAmountInAfterExitFee);
        uint poolRatio = bdiv(newPoolSupply, poolSupply);
     
        // newBalTo = poolRatio^(1/weightTo) * balTo;
        uint tokenOutRatio = bpow(poolRatio, bdiv(BONE, normalizedWeight));
        uint newTokenBalanceOut = bmul(tokenOutRatio, tokenBalanceOut);

        uint tokenAmountOutBeforeSwapFee = bsub(tokenBalanceOut, newTokenBalanceOut);

        // charge swap fee on the output token side 
        //uint tAo = tAoBeforeSwapFee * (1 - (1-weightTo) * swapFee)
        uint zaz = bmul(bsub(BONE, normalizedWeight), swapFee); 
        tokenAmountOut = bmul(tokenAmountOutBeforeSwapFee, bsub(BONE, zaz));
        return tokenAmountOut;
    }

    /**********************************************************************************************
    // calcPoolInGivenSingleOut                                                                  //
    // pAi = poolAmountIn               // /               tAo             \\     / wO \     \   //
    // bO = tokenBalanceOut            // | bO - -------------------------- |\   | ---- |     \  //
    // tAo = tokenAmountOut      pS - ||   \     1 - ((1 - (tO / tW)) * sF)/  | ^ \ tW /  * pS | //
    // ps = poolSupply                 \\ -----------------------------------/                /  //
    // wO = tokenWeightOut  pAi =       \\               bO                 /                /   //
    // tW = totalWeight           -------------------------------------------------------------  //
    // sF = swapFee                                        ( 1 - eF )                            //
    // eF = exitFee                                                                              //
    **********************************************************************************************/
    function calcPoolInGivenSingleOut(
        uint tokenBalanceOut,
        uint tokenWeightOut,
        uint poolSupply,
        uint totalWeight,
        uint tokenAmountOut,
        uint swapFee
    )
        public pure
        returns (uint poolAmountIn)
    {

        // charge swap fee on the output token side 
        uint normalizedWeight = bdiv(tokenWeightOut, totalWeight);
        //uint tAoBeforeSwapFee = tAo / (1 - (1-weightTo) * swapFee) ;
        uint zoo = bsub(BONE, normalizedWeight);
        uint zar = bmul(zoo, swapFee); 
        uint tokenAmountOutBeforeSwapFee = bdiv(tokenAmountOut, bsub(BONE, zar));

        uint newTokenBalanceOut = bsub(tokenBalanceOut, tokenAmountOutBeforeSwapFee);
        uint tokenOutRatio = bdiv(newTokenBalanceOut, tokenBalanceOut);

        //uint newPoolSupply = (ratioTo ^ weightTo) * poolSupply;
        uint poolRatio = bpow(tokenOutRatio, normalizedWeight);
        uint newPoolSupply = bmul(poolRatio, poolSupply);
        uint poolAmountInAfterExitFee = bsub(poolSupply, newPoolSupply);

        // charge exit fee on the pool token side
        // pAi = pAiAfterExitFee/(1-exitFee)
        poolAmountIn = bdiv(poolAmountInAfterExitFee, bsub(BONE, EXIT_FEE));
        return poolAmountIn;
    }

    /** math */

    function btoi(uint a)
        internal pure 
        returns (uint)
    {
        return a / BONE;
    }

    function bfloor(uint a)
        internal pure
        returns (uint)
    {
        return btoi(a) * BONE;
    }

    function badd(uint a, uint b)
        internal pure
        returns (uint)
    {
        uint c = a + b;
        require(c >= a, "ERR_ADD_OVERFLOW");
        return c;
    }

    function bsub(uint a, uint b)
        internal pure
        returns (uint)
    {
        (uint c, bool flag) = bsubSign(a, b);
        require(!flag, "ERR_SUB_UNDERFLOW");
        return c;
    }

    function bsubSign(uint a, uint b)
        internal pure
        returns (uint, bool)
    {
        if (a >= b) {
            return (a - b, false);
        } else {
            return (b - a, true);
        }
    }

    function bmul(uint a, uint b)
        internal pure
        returns (uint)
    {
        uint c0 = a * b;
        require(a == 0 || c0 / a == b, "ERR_MUL_OVERFLOW");
        uint c1 = c0 + (BONE / 2);
        require(c1 >= c0, "ERR_MUL_OVERFLOW");
        uint c2 = c1 / BONE;
        return c2;
    }

    function bdiv(uint a, uint b)
        internal pure
        returns (uint)
    {
        require(b != 0, "ERR_DIV_ZERO");
        uint c0 = a * BONE;
        require(a == 0 || c0 / a == BONE, "ERR_DIV_INTERNAL"); // bmul overflow
        uint c1 = c0 + (b / 2);
        require(c1 >= c0, "ERR_DIV_INTERNAL"); //  badd require
        uint c2 = c1 / b;
        return c2;
    }

    // DSMath.wpow
    function bpowi(uint a, uint n)
        internal pure
        returns (uint)
    {
        uint z = n % 2 != 0 ? a : BONE;

        for (n /= 2; n != 0; n /= 2) {
            a = bmul(a, a);

            if (n % 2 != 0) {
                z = bmul(z, a);
            }
        }
        return z;
    }

    // Compute b^(e.w) by splitting it into (b^e)*(b^0.w).
    // Use `bpowi` for `b^e` and `bpowK` for k iterations
    // of approximation of b^0.w
    function bpow(uint base, uint exp)
        internal pure
        returns (uint)
    {
        require(base >= MIN_BPOW_BASE, "ERR_BPOW_BASE_TOO_LOW");
        require(base <= MAX_BPOW_BASE, "ERR_BPOW_BASE_TOO_HIGH");

        uint whole  = bfloor(exp);   
        uint remain = bsub(exp, whole);

        uint wholePow = bpowi(base, btoi(whole));

        if (remain == 0) {
            return wholePow;
        }

        uint partialResult = bpowApprox(base, remain, BPOW_PRECISION);
        return bmul(wholePow, partialResult);
    }

    function bpowApprox(uint base, uint exp, uint precision)
        internal pure
        returns (uint)
    {
        // term 0:
        uint a     = exp;
        (uint x, bool xneg)  = bsubSign(base, BONE);
        uint term = BONE;
        uint sum   = term;
        bool negative = false;


        // term(k) = numer / denom 
        //         = (product(a - i - 1, i=1-->k) * x^k) / (k!)
        // each iteration, multiply previous term by (a-(k-1)) * x / k
        // continue until term is less than precision
        for (uint i = 1; term >= precision; i++) {
            uint bigK = i * BONE;
            (uint c, bool cneg) = bsubSign(a, bsub(bigK, BONE));
            term = bmul(term, bmul(c, x));
            term = bdiv(term, bigK);
            if (term == 0) break;

            if (xneg) negative = !negative;
            if (cneg) negative = !negative;
            if (negative) {
                sum = bsub(sum, term);
            } else {
                sum = badd(sum, term);
            }
        }

        return sum;
    }
}