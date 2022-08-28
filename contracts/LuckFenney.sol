// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "./libraries/TransferHelper.sol";
import "./libraries/RandomNumber.sol";
import "hardhat/console.sol";

contract LuckFenney is ERC721Holder, ERC1155Holder, OwnableUpgradeable {
    using TransferHelper for address;
    uint256 constant QuantityMin = 100;
    uint256 constant QuantityMax = 10000;
    uint256 public currentId = 0;
    mapping(address => uint256[]) public producerLucks;
    mapping(uint256 => Lucky) public lucksMap;
    mapping(uint256 => Reward[]) public luckyRewards;
    uint256[] public runningLucks;
    IERC20 public paltformToken;
    uint public attendRewardAmount; // 用户参与奖励平台token的数量。
    uint public holderRewardAmount; // 用户参与奖励平台token的数量。
    mapping(uint256 => mapping(uint256 => address)) public userAttends; // 用户参与的
    mapping(address => bool) public isManager;
    event SetManager(address manager, bool flag);

    modifier onlyManager() {
        require(isManager[_msgSender()], "Not manager");
        _;
    }

    struct Lucky {
        address producer; // the project
        uint256 id;
        uint256 quantity; //计划该luck参与人数
        uint256 endBlock; //持续时间
        uint256 startBlock;
        LuckyState state;
        uint256 ethAmount; // 奖品eth的数量
        uint256[] erc721TokenIds;
        uint256 participation_cost; // 参与的花费。
        uint256 currentQuantity; //已经参加的用户的个数。
    }

    struct Reward {
        address token;
        RewardType rewardType;
        uint256 amount;
        uint256 tokenId;
    }

    enum RewardType {
        ERC20,
        ERC721,
        ERC1155
    }

    enum LuckyState {
        CREATE,
        OPEN,
        CLOSED,
        CALCULATING_WINNER
    }

    event LuckCreated(uint256 LuckID, address creator);


    function initialize(IERC20 paltformToken_,uint userReward_,uint holderReward_) public initializer {
        __Ownable_init();
        paltformToken = paltformToken_;
        isManager[_msgSender()] = true;
        attendRewardAmount = userReward_;
        holderRewardAmount = holderReward_;
    }

    /// parameters
    /// quantity - max quantity of attend users
    function createLuck(
        uint256 quantity,
        Reward[] memory rewards,
        uint256 duration,
        uint256 participationCost_
    ) public payable returns (Lucky memory luck) {
        // require(rewards.length > 0, "RLBTZ");
        require(quantity >= QuantityMin && quantity <= QuantityMax, "LQBTMBLM");
        require(duration > 0, "duration lt 0");
        luck.quantity = quantity;
        // 设置创建人
        luck.producer = msg.sender;
        uint256 ethAmount = msg.value;
        require(ethAmount == luck.ethAmount, "ethAmount engough");
        luck.startBlock = block.number;
        luck.endBlock = luck.startBlock + duration;
        luck.participation_cost = participationCost_;
        // require(luck.deadline > block.number, "RLBTZ");
        // TODO 收钱，并且确认收钱的数量。注意weth9的收取。
        // TODO 收取eth
        for (uint256 i = 0; i < rewards.length; i++) {
            luckyRewards[currentId].push(rewards[i]);
            Reward memory reward = rewards[i];
            if (reward.rewardType == RewardType.ERC20) {
                IERC20(reward.token).transferFrom(
                    msg.sender,
                    address(this),
                    reward.amount
                );
            } else if (reward.rewardType == RewardType.ERC721) {
                // address from, address to,uint256 tokenId,bytes calldata data
                IERC721(reward.token).safeTransferFrom(
                    msg.sender,
                    address(this),
                    reward.tokenId,
                    new bytes(0)
                );
            } else if (reward.rewardType == RewardType.ERC1155) {
                // address from,address to,uint256 id,uint256 amount,bytes calldata data
                IERC1155(reward.token).safeTransferFrom(
                    msg.sender,
                    address(this),
                    reward.tokenId,
                    reward.amount,
                    new bytes(0)
                );
            }
        }

        luck.id = currentId;
        //添加正在运行抽奖，并且修改状态。
        addRunningLucks(luck);
        console.log("currentId1 is:", currentId);
        producerLucks[msg.sender].push(currentId);
        lucksMap[luck.id] = luck;
        currentId += 1;
    }

    function addRunningLucks(Lucky memory luck) internal {
        luck.state = LuckyState.OPEN;
        console.log("luck.id is:", luck.id);
        runningLucks.push(luck.id);
    }

    // 用户参与luck
    function enter(uint256 luckId) public payable {
        Lucky storage luckFenney = lucksMap[luckId];
        require(luckFenney.state == LuckyState.OPEN, "not open");
        console.log(
            "luckFenney.endBlock,block.number",
            luckFenney.endBlock,
            block.number
        );
        require(block.number < luckFenney.endBlock, "over endBlock");
        uint256 value = msg.value;
        require(
            value > 0 && value / luckFenney.participation_cost > 0,
            "value error"
        );
        console.log("-------------1");
        // 分配用户号给用户。
        uint256 attendAmount = value / luckFenney.participation_cost;
        // 检查是否用户已经满员了。
        require(
            luckFenney.currentQuantity + attendAmount <= luckFenney.quantity,
            "too attends"
        );
        console.log("-------------2");
        for (uint256 i = 0; i < attendAmount; i++) {
            luckFenney.currentQuantity +=1;
            userAttends[luckId][luckFenney.currentQuantity] = msg.sender;
        }
        console.log("-------------3");
        // 奖励用户平台token
        paltformToken.mint(msg.sender,attendAmount*attendRewardAmount);
        //发起者发放代币
        paltformToken.mint(luckFenney.producer,attendAmount*holderRewardAmount);
        
        // 退还用户的多余的资金。
        uint256 leftEth = value % luckFenney.participation_cost;
        console.log("lefEth is: ", leftEth);
        TransferHelper.safeTransferETH(
            msg.sender,
            leftEth
        );
    }

    //Random number generation from block timestamp
    function getRandomNumber() public view returns (uint){
        uint blockTime = block.timestamp;
        return uint(keccak256(abi.encodePacked(blockTime)));
    }
    


    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes memory _data
    ) public override returns (bytes4) {
        // store teh erc721 token
        // check the transfer 721 token is
        //story the tokenId.
        return super.onERC721Received(_operator, _from, _tokenId, _data);
    }

    function onERC1155Received(
        address _operator,
        address _from,
        uint256 _id,
        uint256 _value,
        bytes memory _data
    ) public override returns (bytes4) {
        return super.onERC1155Received(_operator, _from, _id, _value, _data);
    }

    function getProducerLucks(address operater)
        public
        view
        returns (uint256[] memory)
    {
        return producerLucks[operater];
    }

    function getLuckyRewards(uint256 currenctId)
        public
        view
        returns (Reward[] memory rewards)
    {
        return luckyRewards[currenctId];
    }
}
