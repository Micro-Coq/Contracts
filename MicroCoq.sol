// SPDX-License-Identifier: MIT

//                   -===-=-   
//                   :=+++*=++*: 
//                  -+++++++=*+. 
//                  ++++***+++*. 
//     =+-.         .=+++++*=-.  
//   ==+++=.         .+***++.    
//  :=+*++++         =*++++*=    
//  =*+++****-::.:-=+*+++++++    
//  ++++++++*****++**+++++++*:   
//  =**+*+**+++++++++++++++++:   
//   -****++++++**++*++++++++    
//    .+*++++*+++++++*++*++=     
//     +*+++++********+++=.      
//     +***#****+++++++=.        
//      :*+**+++*+++++:          
//        :-=+++++**.            
//            -+++*:             
//             .+:--             
//              .+ =-::.         
//               -++=-::         
//               -..:::         
//    __  ____              _________  ____ 
//   /  |/  (_)__________  / ___/ __ \/ __ \
//  / /|_/ / / __/ __/ _ \/ /__/ /_/ / /_/ /
// /_/  /_/_/\__/_/  \___/\___/\____/\___\_\
//
//
// https://microcoq.meme
// https://twitter.com/microcoq
// https://t.me/microcoq


pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol";
import "./IJoeRouter02.sol";

contract MicroCoq is
    ERC20,
    ERC20Permit,
    Ownable,
    AccessControl,
    VRFV2WrapperConsumerBase
{

    //Events
    event BallsWinner(address winner, uint requestId, uint randomNumber, uint coopSize);
    event DistributedTaxes(uint farmingBurned, uint microAddedToLP);
    event BallsLoser(address player);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    //Addreses
    mapping(address => bool) public taxExampt;
    mapping(address => bool) public liquidityPools;
    address public JoeRouter = 0x60aE616a2155Ee3d9A68541Ba4544862310933d4;
    address public farmingToken = 0x420FcA0121DC28039145009570975747295f2329;
    address public immutable deadAddress =
        0x000000000000000000000000000000000000dEaD;


    //Tax Donamicator
    uint public _taxDonamicator = 100;
    //Buy tax
    uint public _burnBuyTax = 50;
    uint public _LPBuyTax = 150;
    uint public _BallsBuyTax = 100;
    //Buy tax
    uint public _burnSellTax = 50;
    uint public _LPSellTax = 150;
    uint public _BallsSellTax = 100;

    //Tax desctribution cooldown period initialized with 30 minutes
    uint public taxDistributionCooldown = 60 * 30;
    uint public lastTaxDistribution = 0;

    uint _supply = 69420000000000 * 10 ** decimals();

    //totalTaxes
    uint public totalBurnTax;
    uint public totalLPTax;

    uint public ballsSize = 0;
    uint public minTxSizeToDrawBallsLottery = _supply / 10000;

    //Minimum amount of tokens to burn is 0.01% of total supply
    uint public minTokensToDestribute = _supply / 10000;
    //Minimum amount of tokens to burn is 0.1% of total supply
    uint public maxTokensToDestribute = _supply / 1000;
    //Minimum coopSize
    uint public ballStack = _supply / 100000;

    //Chainlink Stuff
    address immutable linkAddress = 0x5947BB275c521040051D82396192181b413227A3;
    address immutable wrapperAddress = 0x721DFbc5Cfe53d32ab00A9bdFa605d3b8E1f3f42;

    uint32 constant CALLBACK_GAS_LIMIT = 300000;
    uint16 constant REQUEST_CONFIRMATIONS = 3;
    uint32 constant NUM_WORDS = 1;
    uint paidLink = 0;
    uint32 drawCount = 0;
    uint32 maxDrawCount = 10;

    //Chance to win the Balls lottery if 1/changeToWin + 1
    uint32 chanceToWin = 99;

    struct TicketStatus {
        uint256 paid; // amount paid in link
        bool fulfilled; // whether the request has been successfully fulfilled
        address requester; // requester of the random words
        uint256 randomNumber; //users randomish number
        uint randonDraw;
        bool winner; //where it's a winner or not
    }

    uint256[] public requestIds;
    mapping(uint256 => TicketStatus) public ballsTickets;

    //Indicate if distributing tax
    bool distributing = false;

    constructor(
        address initialOwner,
        address defaultAdmin
    )
        ERC20("Micro Coq", "MICRO")
        ERC20Permit("MICRO")
        Ownable()
        AccessControl()
        VRFV2WrapperConsumerBase(linkAddress, wrapperAddress)
    {
        _grantRole(ADMIN_ROLE, defaultAdmin);
        _mint(initialOwner, _supply);
        _approve(address(this), JoeRouter, type(uint256).max);
        ERC20(IJoeRouter02(JoeRouter).WAVAX()).approve(JoeRouter,type(uint256).max);
        ERC20(farmingToken).approve(JoeRouter,type(uint256).max);
        taxExampt[initialOwner] = true;
    }

    function _transfer(
        address from,
        address to,
        uint amount
    ) internal override {

        if (distributing) {
            super._transfer(from, to, amount);
            return;
        }

        bool overMinTaxBalance = totalBurnTax + totalLPTax >
            minTokensToDestribute;


        //Distribute tax if we have enough tokens to destribute
        if (overMinTaxBalance && !liquidityPools[from] && liquidityPools[to] && block.timestamp + taxDistributionCooldown >= lastTaxDistribution) {
            distributeTax();
            lastTaxDistribution = block.timestamp;
        }

        

        uint taxAmount = 0;
        //Take tax only is trading is enabled
        if (
            !(taxExampt[from] || taxExampt[to]) && (liquidityPools[from] || liquidityPools[to])
        ) {
            //Buy Tax
            if (liquidityPools[from]) {
                uint burnAmount = (amount / 100) * (_burnBuyTax / _taxDonamicator);
                uint LPAmount = (amount / 100) * (_LPBuyTax / _taxDonamicator);
                uint CoopAmount = (amount / 100) * (_BallsBuyTax / _taxDonamicator);
                ballsSize += CoopAmount;
                totalBurnTax += burnAmount;
                totalLPTax += LPAmount;
                taxAmount = burnAmount + LPAmount + CoopAmount;
            }

            //Buy sell
            if (liquidityPools[to]) {
                uint burnAmount = (amount / 100) * (_burnSellTax / _taxDonamicator);
                uint LPAmount = (amount / 100) * (_LPSellTax / _taxDonamicator);
                uint ballsAmount = (amount / 100) * (_BallsSellTax / _taxDonamicator);
                ballsSize += ballsAmount;
                totalBurnTax += burnAmount;
                totalLPTax += LPAmount;
                taxAmount = burnAmount + LPAmount + ballsAmount;
            }
        }

        //Take taxes if applicable
        if (taxAmount > 0) {
            super._transfer(from, address(this), taxAmount);
        }

        super._transfer(from, to, amount - taxAmount);

        //Too many swimmers in the stack let see if someone wants a fried egg
        if(liquidityPools[from] && ballsSize >= ballStack && amount >= minTxSizeToDrawBallsLottery){
            _ballsLottery();
        }
    }        

    //Destribute tax
    function distributeTax() public {
        distributing = true;
        //Get the amount of tokens to destribute
        uint tokensToDestribute = totalBurnTax + totalLPTax > maxTokensToDestribute
            ? maxTokensToDestribute
            : totalBurnTax + totalLPTax;

        //Amount of tokens to burn
        // 25% to burn Farming Token
        uint tokensToBurn = tokensToDestribute / 4;
        uint tokensToMicroLP = (tokensToDestribute - tokensToBurn) / 2;
        uint tokenToFarmingLP = tokensToDestribute - tokensToMicroLP;


    
        uint farmingBalance = _swapTokenToToken(tokensToBurn, farmingToken);
        //Burn Farming Token
        ERC20(farmingToken).transfer(deadAddress, farmingBalance);


        uint avaxBalance = _swapTokenToAVAX((tokensToMicroLP + tokenToFarmingLP) / 2);
        _addLiquidity(avaxBalance, tokensToMicroLP + tokenToFarmingLP);

        //Buy back Link spent on Coop Lottery.
        if(drawCount >= maxDrawCount){
            _swapMicroToLink(paidLink);
        }

        emit DistributedTaxes(farmingBalance, tokensToMicroLP + tokenToFarmingLP);
        totalLPTax = 0;
        totalBurnTax = 0;
        distributing = false;
    }

    //Swaps Micro for AVAX.
    function _swapTokenToAVAX(uint amount) internal returns (uint) {
        // generate the uniswap pair path of hem -> wavax
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = IJoeRouter02(JoeRouter).WAVAX();

        // make the swap
        IJoeRouter02(JoeRouter)
            .swapExactTokensForAVAXSupportingFeeOnTransferTokens(
                amount,
                0, // accept any amount of AVAX tokens
                path,
                address(this),
                block.timestamp
            );
        return address(this).balance;
    }

    //Swaps Micro for Token.
    function _swapTokenToToken(uint amount, address token) internal returns (uint) {
        // generate the uniswap pair path of Micro -> wavax -> token
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = IJoeRouter02(JoeRouter).WAVAX();
        path[2] = token;

        // make the swap
        IJoeRouter02(JoeRouter).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount,
                0, // accept any amount of AVAX tokens
                path,
                address(this),
                block.timestamp
            );
        return ERC20(farmingToken).balanceOf(address(this));
    }

    //Add to Micro LP from tax revenue
    function _addLiquidity(uint amountAvax, uint amountMicro) internal {

        _swapAvaxForToken(amountAvax / 4, farmingToken);
        uint farmingBalance = ERC20(farmingToken).balanceOf(address(this));

        IJoeRouter02(JoeRouter).addLiquidity(
            address(this),
            farmingToken,
            amountMicro / 2,
            farmingBalance,
            0,
            0,
            deadAddress,
            block.timestamp
        );

        IJoeRouter02(JoeRouter).addLiquidityAVAX{value: amountAvax / 2}(
            address(this),
            amountMicro / 2,
            0,
            0,
            deadAddress,
            block.timestamp
        );
    }

    //Burn COQ Tokens.
    function _swapAvaxForToken(uint amount, address token) internal {

        address[] memory path = new address[](2);
        path[0] = IJoeRouter02(JoeRouter).WAVAX();
        path[1] = token;


        IJoeRouter02(JoeRouter)
            .swapExactAVAXForTokensSupportingFeeOnTransferTokens{value: amount}(
            0, //Accept any amount of COQ
            path,
            address(this),
            block.timestamp
        );
    }

    //Swap Micro for LINK
    function _swapMicroToLink(uint amount) internal {

        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = IJoeRouter02(JoeRouter).WAVAX();
        path[2] = linkAddress;

        uint balanceBefore = balanceOf(address(this));
        try IJoeRouter02(JoeRouter).swapTokensForExactTokens(
            amount,
            ballsSize,
            path,
            address(this),
            block.timestamp
        ) {
            //If we succeed to swap HEN for LINK we will reset the coopSize
            ballsSize -= balanceBefore - balanceOf(address(this));
            paidLink = 0;
            drawCount = 0;
            return;
        } catch {
            //If we fail to swap HEN for LINK we will try again next time
            return;
        } 
    }

    function _ballsLottery() internal {
        uint requiredLink = VRF_V2_WRAPPER.calculateRequestPrice(CALLBACK_GAS_LIMIT);
        if(ERC20(linkAddress).balanceOf(address(this)) < requiredLink){
            return;
        }

        uint requestId = requestRandomness(
            CALLBACK_GAS_LIMIT,
            REQUEST_CONFIRMATIONS,
            NUM_WORDS
        );
        uint randomIshNumber = uint(keccak256(abi.encodePacked(block.timestamp, requestId, msg.sender))) % chanceToWin;
        drawCount += 1;
        ballsTickets[requestId] = TicketStatus({
            paid: requiredLink,
            fulfilled: false,
            requester: msg.sender,
            randomNumber: randomIshNumber,
            randonDraw: 0,
            winner: false
        });

        paidLink += ballsTickets[requestId].paid;
        requestIds.push(requestId);
    }

    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        distributing = true;

        ballsTickets[_requestId].fulfilled = true;
        ballsTickets[_requestId].randonDraw = _randomWords[0] % chanceToWin;
        ballsTickets[_requestId].winner = ballsTickets[_requestId].randonDraw == ballsTickets[_requestId].randomNumber;

        if(ballsTickets[_requestId].winner){
            transfer(ballsTickets[_requestId].requester, ballsSize);
            emit BallsWinner(ballsTickets[_requestId].requester, _requestId, ballsTickets[_requestId].randomNumber, ballsSize);
            ballsSize = 0;
        } else {
            emit BallsLoser(ballsTickets[_requestId].requester);
        }
        distributing = false;
    }

    //################# Admin Controled Functions #################

    // Define the LP address for tax purposes
    function setLiquidityPool(
        address _liquidityPool,
        bool _state
    ) external onlyRole(ADMIN_ROLE) {
        liquidityPools[_liquidityPool] = _state;

    }

    //Allow admin to change the buy tax rates
    function setBuyTaxRates(
        uint burnTax,
        uint LPTax,
        uint CoopTax
    ) external onlyRole(ADMIN_ROLE) {
        require(burnTax + LPTax + CoopTax <= 3, "Total tax cannot exceed 5%");
        _burnBuyTax = burnTax;
        _LPBuyTax = LPTax;
        _BallsBuyTax = CoopTax;
    }

    //Allow admin to change the sell tax rates
    function setSellTaxRates(
        uint burnTax,
        uint LPTax,
        uint CoopTax
    ) external onlyRole(ADMIN_ROLE) {
        require(burnTax + LPTax + CoopTax <= 3, "Total tax cannot exceed 5%");
        _burnSellTax = burnTax;
        _LPSellTax = LPTax;
        _BallsSellTax = CoopTax;
    }

    //Set min TX size to participate in coop lottery
    function setMinTxSizeToDrawCoopLottery(uint _minTxSizeToDrawCoopLottery) external onlyRole(ADMIN_ROLE) {
        require(_minTxSizeToDrawCoopLottery > 0 && _minTxSizeToDrawCoopLottery <= totalSupply() / 100, "Min tx size must be between 0 and 1% of total supply");
        minTxSizeToDrawBallsLottery = _minTxSizeToDrawCoopLottery;
    }

    //Set min TX size to participate in coop lottery
    function setMinTokensToDestribute(uint _minTokensToDestribute) external onlyRole(ADMIN_ROLE) {
        require(_minTokensToDestribute > 0 && _minTokensToDestribute <= totalSupply() / 100, "Min tokens to destribute must be between 0 and 1% of total supply");
        minTokensToDestribute = _minTokensToDestribute;
    }
    //Set min TX size to participate in coop lottery
    function setMaxTokensToDestribute(uint _maxTokensToDestribute) external onlyRole(ADMIN_ROLE) {
        require(_maxTokensToDestribute > 0 && maxTokensToDestribute <= totalSupply() / 100, "Min tokens to destribute must be between 0 and 1% of total supply");
        minTokensToDestribute = _maxTokensToDestribute;
    }

    //Set tax destribution cooldown
    function setTaxDestributionCooldown(uint _taxDistributionCooldown) external onlyRole(ADMIN_ROLE) {
        require(_taxDistributionCooldown > 0, "Cooldown must be greater than 0");
        require(_taxDistributionCooldown <= 60 * 60, "Cooldown cannot be greater than 1 hour");
        taxDistributionCooldown = _taxDistributionCooldown;
    }

    //Set min coop lottery size
    function setMinCoopSize(uint _minCoopSize) external onlyRole(ADMIN_ROLE) {
        require(_minCoopSize > 0 && _minCoopSize <= totalSupply() / 1000, "Min coop size must be between 0 and 0.1% of total supply");
        ballStack = _minCoopSize;
    }

    //Set Link max draw count before buying back Link
    function setMaxDrawCount(uint32 _maxDrawCount) external onlyRole(ADMIN_ROLE) {
        require(_maxDrawCount > 10 && _maxDrawCount < 100, "Max draw count must be between 10 and 100");
        maxDrawCount = _maxDrawCount;
    }

    //Set chance to win coop lottery
    function setChanceToWin(uint32 _chanceToWin) external onlyRole(ADMIN_ROLE) {
        require(_chanceToWin >= 99 && _chanceToWin <= 999, "Chance to win must be between 99 and 999");
        chanceToWin = _chanceToWin;
    }

    //Set tax destribution cooldown
    function setTaxDistributionCooldown(uint _taxDistributionCooldown) external onlyRole(ADMIN_ROLE) {
        taxDistributionCooldown = _taxDistributionCooldown;
    }

    //Set Farming Token
    function setFarmingToken(address _farmingToken) external onlyRole(ADMIN_ROLE) {
        farmingToken = _farmingToken;
    }

    // Rescue ERC20 tokens
    function rescueTokens(address token)external onlyRole(ADMIN_ROLE) {
        require(token != address(this), "Cannot Withdraw MICRO");
        ERC20(token).transfer(msg.sender, ERC20(token).balanceOf(address(this)));
    }

    // Rescue Axax
    function rescueAvax(address payable _to) external onlyRole(ADMIN_ROLE){
        _to.transfer(address(this).balance);
    }
    //Set exampt tax
    function setExamptTax(address _to, bool state) external onlyRole(ADMIN_ROLE){
        taxExampt[_to] = state;
    }

    //Withdraw LINK
    function withrawLink() external onlyRole(ADMIN_ROLE) {
        ERC20(linkAddress).transfer(
            msg.sender,
            ERC20(linkAddress).balanceOf(address(this))
        );
    }

    // ####################### Getter Helper Functions #######################

    function getTotalTax() public view returns (uint) {
        return totalBurnTax + totalLPTax + ballsSize;
    }
    
    receive() external payable {}

    fallback() external payable {}

    
}