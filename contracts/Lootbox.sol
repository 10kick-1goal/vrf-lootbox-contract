// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC1155} from '@openzeppelin/contracts/token/ERC1155/IERC1155.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import {ERC721Holder} from '@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol';
import {ERC1155PresetMinterPauser} from '@openzeppelin/contracts/token/ERC1155/presets/ERC1155PresetMinterPauser.sol';
import {ERC1155Holder, ERC1155Receiver} from '@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {Address} from '@openzeppelin/contracts/utils/Address.sol';
import {VRFCoordinatorV2Interface} from '@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol';
import {ERC677ReceiverInterface} from '@chainlink/contracts/src/v0.8/interfaces/ERC677ReceiverInterface.sol';
import {VRFV2WrapperInterface} from '@chainlink/contracts/src/v0.8/interfaces/VRFV2WrapperInterface.sol';
import {VRFV2WrapperConsumerBase} from '@chainlink/contracts/src/v0.8/VRFV2WrapperConsumerBase.sol';
import {ILootboxFactory} from './interfaces/ILootboxFactory.sol';
import {IVRFV2Wrapper, AggregatorV3Interface} from './interfaces/IVRFV2Wrapper.sol';

//  $$$$$$\  $$\   $$\  $$$$$$\  $$$$$$\ $$\   $$\  $$$$$$\   $$$$$$\  $$$$$$$$\ $$$$$$$$\ 
// $$  __$$\ $$ |  $$ |$$  __$$\ \_$$  _|$$$\  $$ |$$  __$$\ $$  __$$\ $$  _____|$$  _____|
// $$ /  \__|$$ |  $$ |$$ /  $$ |  $$ |  $$$$\ $$ |$$ /  \__|$$ /  $$ |$$ |      $$ |      
// $$ |      $$$$$$$$ |$$$$$$$$ |  $$ |  $$ $$\$$ |\$$$$$$\  $$$$$$$$ |$$$$$\    $$$$$\    
// $$ |      $$  __$$ |$$  __$$ |  $$ |  $$ \$$$$ | \____$$\ $$  __$$ |$$  __|   $$  __|   
// $$ |  $$\ $$ |  $$ |$$ |  $$ |  $$ |  $$ |\$$$ |$$\   $$ |$$ |  $$ |$$ |      $$ |      
// \$$$$$$  |$$ |  $$ |$$ |  $$ |$$$$$$\ $$ | \$$ |\$$$$$$  |$$ |  $$ |$$ |      $$$$$$$$\ 
//  \______/ \__|  \__|\__|  \__|\______|\__|  \__| \______/ \__|  \__|\__|      \________|                                                                                                                                                                              
                                                                                        
// $$\       $$$$$$\   $$$$$$\ $$$$$$$$\ $$$$$$$\   $$$$$$\  $$\   $$\ $$$$$$$$\  $$$$$$\  
// $$ |     $$  __$$\ $$  __$$\\__$$  __|$$  __$$\ $$  __$$\ $$ |  $$ |$$  _____|$$  __$$\ 
// $$ |     $$ /  $$ |$$ /  $$ |  $$ |   $$ |  $$ |$$ /  $$ |\$$\ $$  |$$ |      $$ /  \__|
// $$ |     $$ |  $$ |$$ |  $$ |  $$ |   $$$$$$$\ |$$ |  $$ | \$$$$  / $$$$$\    \$$$$$$\  
// $$ |     $$ |  $$ |$$ |  $$ |  $$ |   $$  __$$\ $$ |  $$ | $$  $$<  $$  __|    \____$$\ 
// $$ |     $$ |  $$ |$$ |  $$ |  $$ |   $$ |  $$ |$$ |  $$ |$$  /\$$\ $$ |      $$\   $$ |
// $$$$$$$$\ $$$$$$  | $$$$$$  |  $$ |   $$$$$$$  | $$$$$$  |$$ /  $$ |$$$$$$$$\ \$$$$$$  |
// \________|\______/  \______/   \__|   \_______/  \______/ \__|  \__|\________| \______/ 

/// @title Lootbox
/// @author ChainSafe Systems: Oleksii (Functionality) Sneakz (Natspec assistance)
/// @notice This contract holds lootbox functions used in Chainsafe's SDK, Documentation can be found here: https://docs.gaming.chainsafe.io/current/lootboxes
/// @dev Contract allows users to open a lootbox and receive a random reward. All function calls are tested and have been implemented in ChainSafe's SDK

type RewardInfo is uint248; // 8 bytes unitsAvailable | 23 bytes amountPerUnit
uint constant UNITS_OFFSET = 8 * 23;

contract Lootbox is VRFV2WrapperConsumerBase, ERC721Holder, ERC1155Holder, ERC1155PresetMinterPauser {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;
  using EnumerableSet for EnumerableSet.UintSet;
  using Address for address payable;
  using SafeCast for uint;

  /*//////////////////////////////////////////////////////////////
                                STATE
  //////////////////////////////////////////////////////////////*/

  enum RewardType {
    UNSET,
    ERC20,
    ERC721,
    ERC1155,
    ERC1155NFT
  }

  struct Reward {
    RewardType rewardType;
    RewardInfo rewardInfo;
    EnumerableSet.UintSet ids; // only 721 and 1155
    mapping(uint => RewardInfo) extraInfo; // only for 1155
  }

  struct AllocationInfo {
    EnumerableSet.UintSet ids;
    mapping(uint => uint) amount; // id 0 for ERC20
  }

  ILootboxFactory private immutable FACTORY;
  AggregatorV3Interface private immutable LINK_ETH_FEED;
  address private immutable VIEW;
  uint private constant LINK_UNIT = 1e18;

  uint private unitsSupply; // Supply of units.
  uint private unitsRequested; // Amount of units requested for opening.
  uint private unitsMinted; // Boxed units.
  bool private isEmergencyMode; // State of emergency.
  EnumerableSet.UintSet private lootboxTypes; // Types of lootboxes.
  EnumerableSet.AddressSet private suppliers; // Supplier addresses being used.
  EnumerableSet.AddressSet private allowedTokens; // Tokens allowed for rewards.
  EnumerableSet.AddressSet private inventory; // Tokens available for rewards.
  mapping(address => mapping(uint => uint)) private allocated; // Token => TokenId => Balance. ERC20 and fungible ERC1155 allocated for claiming.
  mapping(address => Reward) private rewards; // Info about reward tokens.
  mapping(address => mapping(address => AllocationInfo)) private allocationInfo; // Claimer => Token => Info.
  mapping(address => EnumerableSet.UintSet) private extraIds; // ERC1155 internal token ids ever touching the lootbox.

  /*//////////////////////////////////////////////////////////////
                             VRF RELATED
  //////////////////////////////////////////////////////////////*/

  /// @notice The number of blocks confirmed before the request is considered fulfilled
  uint16 private constant REQUEST_CONFIRMATIONS = 3;

  /// @notice The number of random words to request
  uint32 private constant NUMWORDS = 1;

  /// @notice The VRF request struct
  struct Request {
    address opener;
    uint96 unitsToGet;
    uint[] lootIds;
    uint[] lootAmounts;
  }

  /// @notice The VRF request IDs and their corresponding parameters as well as the randomness when fulfilled
  mapping(uint256 => Request) private requests;

  /// @notice The VRF request IDs and their corresponding openers
  mapping(address => uint256) private openerRequests;

  /*//////////////////////////////////////////////////////////////
                                EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when a lootbox is openning is requested
  /// @param opener The address of the user that requested the open
  /// @param unitsToGet The amount of lootbox units to receive
  /// @param requestId The ID of the VRF request
  event OpenRequested(address opener, uint256 unitsToGet, uint256 requestId);

  /// @notice Emitted when a randomness request is fulfilled and the lootbox rewards can be claimed
  /// @param requestId The ID of the VRF request
  /// @param randomness The random number that was generated
  event OpenRequestFulfilled(uint256 requestId, uint256 randomness);

  /// @notice Emitted when a randomness request ran out of gas and now must be recovered
  /// @param requestId The ID of the VRF request
  event OpenRequestFailed(uint256 requestId, bytes reason);

  event SupplierAdded(address supplier);

  event SupplierRemoved(address supplier);

  /// @notice Emitted when a new reward token gets whitelisted for supply
  event TokenAdded(address token);

  /// @notice Emitted when a reward token amount per unit changes
  /// @param newSupply The new supply of reward units available
  event AmountPerUnitSet(address token, uint tokenId, uint amountPerUnit, uint newSupply);

  /// @notice Emitted when the lootbox rewards are claimed
  /// @param opener The address of the user that received the rewards
  /// @param token The rewarded token contract address
  /// @param tokenId The internal tokenId for ERC721 and ERC1155
  /// @param amount The amount of claimed tokens
  event RewardsClaimed(address opener, address token, uint tokenId, uint amount);

  /// @notice Emitted when the lootbox rewards are allocated
  /// @param opener The address of the user that received the allocation
  /// @param token The rewarded token contract address
  /// @param tokenId The internal tokenId for ERC721 and ERC1155
  /// @param amount The amount of allocated tokens
  event Allocated(address opener, address token, uint tokenId, uint amount);

  /// @notice Emitted when the lootboxes gets recovered from a failed open request
  /// @param opener The address of the user that received the allocation
  /// @param requestId The ID of the VRF request
  event BoxesRecovered(address opener, uint requestId);

  /// @notice Emitted when the contract stops operation and assets being withdrawn by the admin
  /// @param caller The address of the admin who initiated the emergency
  event EmergencyModeEnabled(address caller);

  /// @notice Emitted when an admin withdraws assets in case of emergency
  /// @param token The token contract address
  /// @param tokenType The type of asset of token contract
  /// @param to The address that received the withdrawn assets
  /// @param ids The internal tokenIds for ERC721 and ERC1155
  /// @param amounts The amounts of withdrawn tokens/ids
  event EmergencyWithdrawal(address token, RewardType tokenType, address to, uint[] ids, uint[] amounts);

  /// @notice Emitted when an admin withdraws ERC20 or native currency
  /// @param token The token contract address or zero for native currency
  /// @param to The address that received the withdrawn assets
  /// @param amount The amount withdrawn
  event Withdraw(address token, address to, uint amount);

  /*//////////////////////////////////////////////////////////////
                                ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice There are no tokens to put in the lootbox
  error NoTokens();

  /// @notice The tokens array length does not match the perUnitAmounts array length
  error InvalidLength();

  /// @notice Supplying 1155NFT with amount > 1
  error InvalidTokenAmount();

  /// @notice The amount to open is zero
  error ZeroAmount();

  /// @notice Token not allowed as reward
  error TokenDenied(address token);

  /// @notice Deposits only allowed from whitelisted addresses
  error SupplyDenied(address from);

  /// @notice The amount to open exceeds the supply
  error SupplyExceeded(uint256 supply, uint256 unitsToGet);

  /// @notice The new supply amount is less than already requested to open
  error InsufficientSupply(uint256 supply, uint256 requested);

  /// @notice Has to finish the open request first
  error PendingOpenRequest(uint256 requestId);

  /// @notice Has to open some lootboxes first
  error NothingToClaim();

  /// @notice Reward type is immutable
  error ModifiedRewardType(RewardType oldType, RewardType newType);

  /// @notice Only LINK could be sent with an ERC677 call
  error AcceptingOnlyLINK();

  /// @notice Not enough pay for a VRF request
  error InsufficientPayment();

  /// @notice Not enough pay for a lootbox opening fee
  error InsufficientFee();

  /// @notice There should be a failed VRF request for recovery
  error NothingToRecover();

  /// @notice LINK price must be positive from an oracle
  error InvalidLinkPrice(int value);

  /// @notice Zero value ERC1155 supplies are not alloved
  error ZeroSupply(address token, uint id);

  /// @notice Function could only be called by this contract itself
  error OnlyThis();

  /// @notice Unexpected reward type for current logic
  error UnexpectedRewardType(RewardType rewardType);

  /// @notice Units should fit in 64 bits
  error UnitsOverflow(uint value);

  /// @notice Amount per unit should fit in 184 bits
  error AmountPerUnitOverflow(uint value);

  /// @notice Token id was already present in the inventory with units set to 0
  error DepositStateCorruption(address token, uint tokenId);

  /// @notice Token was already present in the inventory with units set to 0
  error InventoryStateCorruption(address token);

  /// @notice Not enough gas is provided for opening
  error InsufficientGas();

  /// @notice Lootbox id represents the number of rewrad units it will produce, so it should be > 0 and < 256
  error InvalidLootboxType();

  /// @notice The request is either already failed/fulfilled or was never created
  error InvalidRequestAllocation(uint requestId);

  /// @notice Requested operation is not supported in current version
  error Unsupported();

  /// @notice Token is allowed as reward and cannot be withdrawn
  error RewardWithdrawalDenied(address token);

  /// @notice Contrat was put into emergency mode and stopped operations
  error EndOfService();

  /// @notice Contrat could only be initialized by the factory
  error OnlyFactory();

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Deploys a new Lootbox contract with the given parameters.
  /// @param _link The ChainLink LINK token address.
  /// @param _vrfV2Wrapper The ChainLink VRFV2Wrapper contract address.
  /// @param _linkEthFeed The CHainLink LINK-ETH feed address.
  /// @param _view The LootboxView contract address.
  constructor(
    address _link,
    address _vrfV2Wrapper,
    address _linkEthFeed,
    address _view
  ) VRFV2WrapperConsumerBase(_link, _vrfV2Wrapper) ERC1155PresetMinterPauser('') {
    FACTORY = ILootboxFactory(payable(msg.sender));
    LINK_ETH_FEED = AggregatorV3Interface(_linkEthFeed);
    VIEW = _view;
  }

  /// @notice Deploys a new Lootbox contract with the given parameters.
  /// @param _uri The Lootbox ERC1155 base URI.
  /// @param _owner The admin of the lootbox contract.
  function initialize(string memory _uri, address _owner) external {
    if (msg.sender != address(FACTORY)) revert OnlyFactory();
    _setupRole(DEFAULT_ADMIN_ROLE, _owner);
    _setupRole(MINTER_ROLE, _owner);
    _setupRole(PAUSER_ROLE, _owner);
    _setURI(_uri);
  }

  /*//////////////////////////////////////////////////////////////
                        INVENTORY FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  modifier notEmergency() {
    _notEmergency();
    _;
  }

  modifier onlyAdmin() {
    _checkRole(DEFAULT_ADMIN_ROLE);
    _;
  }

  /// @notice Sets the URI for the contract.
  /// @param _baseURI The base URI being used.
  function setURI(string memory _baseURI) external onlyAdmin() {
    _setURI(_baseURI);
  }

  /// @notice Adds loot suppliers.
  /// @param _suppliers An array of loot suppliers being added.
  function addSuppliers(address[] calldata _suppliers) external onlyAdmin() {
    for (uint i = 0; i < _suppliers.length; ++i) {
      _addSupplier(_suppliers[i]);
    }
  }

  /// @notice Removes contract suppliers.
  /// @param _suppliers An array of suppliers being removed.
  function removeSuppliers(address[] calldata _suppliers) external onlyAdmin() {
    for (uint i = 0; i < _suppliers.length; ++i) {
      _removeSupplier(_suppliers[i]);
    }
  }

  /// @notice Adds tokens for lootbox usage.
  /// @param _tokens An array of tokens being added.
  function addTokens(address[] calldata _tokens) external onlyAdmin() {
    for (uint i = 0; i < _tokens.length; ++i) {
      _addToken(_tokens[i]);
    }
  }

  /// @notice Sets the how much of a token you get per lootbox.
  /// @dev Stops working during the emergency.
  /// @param _tokens An array of tokens being added.
  /// @param _ids An array of ids being added.
  /// @param _amountsPerUnit An array of amounts being added.
  function setAmountsPerUnit(address[] calldata _tokens, uint[] calldata _ids, uint[] calldata _amountsPerUnit) external notEmergency() onlyAdmin() {
    if (_tokens.length != _ids.length || _tokens.length != _amountsPerUnit.length) revert InvalidLength();
    uint currentSupply = unitsSupply;
    for (uint i = 0; i < _tokens.length; ++i) {
      currentSupply = _setAmountPerUnit(currentSupply, _tokens[i], _ids[i], _amountsPerUnit[i]);
    }
    if (currentSupply < unitsRequested) revert InsufficientSupply(currentSupply, unitsRequested);
    unitsSupply = currentSupply;
  }

  function emergencyWithdraw(address _token, RewardType _type, address _to, uint[] calldata _ids, uint[] calldata _amounts) external onlyAdmin() {
    if (_not(isEmergencyMode)) {
      isEmergencyMode = true;
      emit EmergencyModeEnabled(_msgSender());
    }
    if (_to == address(0)) {
      _to = _msgSender();
    }
    uint length = _ids.length;
    if (length != _amounts.length) revert InvalidLength();
    for (uint i = 0; i < length; ++i) {
      _transferToken(_token, _type, _to, _ids[i], _amounts[i]);
    }

    emit EmergencyWithdrawal(_token, _type, _to, _ids, _amounts);
  }

  /// @notice Sets required information when a 721 token is received.
  /// @param from The address the token is coming from.
  /// @param tokenId The id of of the 721 token.
  /// @return onERC721Received if successful.
  function onERC721Received(
    address,
    address from,
    uint256 tokenId,
    bytes memory
  ) public override notEmergency() returns (bytes4) {
    address token = _validateReceive(from);
    Reward storage reward = rewards[token];
    RewardInfo rewardInfo = reward.rewardInfo;
    RewardType rewardType = reward.rewardType;
    bool isFirstTime = rewardType == RewardType.UNSET;
    if (isFirstTime) {
      rewardInfo = toInfo(0, 1);
      reward.rewardInfo = rewardInfo;
      reward.rewardType = RewardType.ERC721;
    } else if (rewardType != RewardType.ERC721) {
      revert ModifiedRewardType(rewardType, RewardType.ERC721);
    }
    _supplyNFT(reward, rewardInfo, token, tokenId);
    return this.onERC721Received.selector;
  }

  /// @notice Sets required information when a 1155 token batch is received.
  /// @param from The address the token is coming from.
  /// @param ids An array of 1155 ids to be added to the account.
  /// @param values An array of values to be added to the account.
  /// @return onERC1155BatchReceived if successful.
  function onERC1155BatchReceived(
    address,
    address from,
    uint256[] memory ids,
    uint256[] memory values,
    bytes memory
  ) public override notEmergency() returns (bytes4) {
    address token = _validateReceive(from);
    uint len = ids.length;
    for (uint i = 0; i < len; ++i) {
      _supply1155(token, ids[i], values[i]);
    }
    return this.onERC1155BatchReceived.selector;
  }

  /// @notice Sets required information when a 1155 token is received.
  /// @param from The address the token is coming from.
  /// @param id The 1155 id to be added to the account.
  /// @param value The value to be added to the account.
  /// @return onERC1155Received if successful.
  function onERC1155Received(
    address,
    address from,
    uint256 id,
    uint256 value,
    bytes memory
  ) public override notEmergency() returns (bytes4) {
    address token = _validateReceive(from);
    _supply1155(token, id, value);
    return this.onERC1155Received.selector;
  }

  /*//////////////////////////////////////////////////////////////
                           OPEN FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Requests a lootbox openning paying with LINK.
  /// @param _opener The payer who wants to open a lootbox.
  /// @param _amount The max amount of LINK to pay.
  /// @param _gasAndLoot List of lootboxes to open and a gas limit for allocation
  ///                    ABI encoded as (uint32, uint[], uint[]), gas, ids, amounts.
  // function onTokenTransfer(address _opener, uint _amount, bytes calldata _gasAndLoot) external notEmergency() override {
    // revert Unsupported();
  //   if (msg.sender != address(LINK)) revert AcceptingOnlyLINK();
  //   (uint32 gas, uint[] memory lootIds, uint[] memory lootAmounts) =
  //     abi.decode(_gasAndLoot, (uint32, uint[], uint[]));
  //   uint vrfPrice = VRF_V2_WRAPPER.calculateRequestPrice(gas);
  //   if (_amount < vrfPrice) revert InsufficientPayment();
  //   _amount -= vrfPrice;
  //   uint unitsToGet = _requestOpen(_opener, gas, lootIds, lootAmounts);
  //   uint feePerUnit = FACTORY.feePerUnit(address(this));
  //   uint feeInLink = feePerUnit * unitsToGet * LINK_UNIT / _getLinkPrice();
  //   if (_amount < feeInLink) revert InsufficientFee();
  //   if (feeInLink > 0) {
  //     LINK.transferAndCall(address(FACTORY), feeInLink, '');
  //   }
  //   if (_amount > feeInLink) {
  //     IERC20(address(LINK)).safeTransfer(_opener, _amount - feeInLink);
  //   }
  // }

  /// @notice Requests a lootbox openning paying with native currency
  /// @param _gas Gas limit for allocation
  /// @param _lootIds Lootbox ids to open
  /// @param _lootAmounts Lootbox amounts to open
  function open(uint32 _gas, uint[] calldata _lootIds, uint[] calldata _lootAmounts) external notEmergency() payable {
    uint vrfPrice = VRF_V2_WRAPPER.calculateRequestPrice(_gas);
    uint vrfPriceNative = vrfPrice * _getLinkPrice() / LINK_UNIT;
    if (msg.value < vrfPriceNative) revert InsufficientPayment();
    uint payment = msg.value - vrfPriceNative;
    address opener = _msgSender();
    uint unitsToGet = _requestOpen(opener, _gas, _lootIds, _lootAmounts);
    uint feePerUnit = FACTORY.feePerUnit(address(this));
    uint feeInNative = feePerUnit * unitsToGet;
    if (payment < feeInNative) revert InsufficientFee();
    if (feeInNative > 0) {
      payable(FACTORY).sendValue(feeInNative);
    }
    if (payment > feeInNative) {
      payable(opener).sendValue(payment - feeInNative);
    }
  }

  // TODO: allow partial claiming to avoid OOG.
  /// @notice Claims the rewards for the lootbox openning.
  /// @dev The user must have some rewards allocated.
  /// @param _opener The address of the user that has an allocation after opening.
  function claimRewards(address _opener) external whenNotPaused() {
    uint ids = allowedTokens.length();
    for (uint i = 0; i < ids; ++i) {
      address token = allowedTokens.at(i);
      AllocationInfo storage info = allocationInfo[_opener][token];
      RewardType rewardType = rewards[token].rewardType;
      if (rewardType == RewardType.ERC20) {
        uint amount = info.amount[0];
        if (amount == 0) {
          continue;
        }
        info.amount[0] = 0;
        _deAllocate(token, 0, amount);
        _transferToken(token, rewardType, _opener, 0, amount);
        _emitClaimed(_opener, token, 0, amount);
      }
      else {
        uint tokenIds = info.ids.length();
        while(tokenIds > 0) {
          uint nextIndex = --tokenIds;
          uint tokenId = info.ids.at(nextIndex);
          info.ids.remove(tokenId);
          uint amount = 1;
          if (rewardType == RewardType.ERC1155) {
            amount = info.amount[tokenId];
            info.amount[tokenId] = 0;
            _deAllocate(token, tokenId, amount);
          }
          _transferToken(token, rewardType, _opener, tokenId, amount);
          _emitClaimed(_opener, token, tokenId, amount);
        }
      }
    }
  }

  /// @notice Used to recover lootboxes for an address.
  /// @param _opener The address that opened the boxes.
  function recoverBoxes(address _opener) external {
    uint requestId = openerRequests[_opener];
    if (requestId == 0) revert NothingToRecover();
    Request storage request = requests[requestId];
    if (request.unitsToGet > 0) revert PendingOpenRequest(requestId);
    uint[] memory ids = request.lootIds;
    uint[] memory amounts = request.lootAmounts;
    delete requests[requestId];
    delete openerRequests[_opener];
    _mintBatch(_opener, ids, amounts, '');
    emit BoxesRecovered(_opener, requestId);
  }

  /*//////////////////////////////////////////////////////////////
                          GETTER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  struct ExtraRewardInfo {
    uint id;
    uint units;
    uint amountPerUnit;
    uint balance;
  }

  struct RewardView {
    address rewardToken;
    RewardType rewardType;
    uint units;
    uint amountPerUnit;
    uint balance;
    ExtraRewardInfo[] extra;
  }

  fallback() external {
    _callView();
  }

  function _callView() internal view {
    uint sig = uint(uint32(this.viewCall.selector));
    bytes memory _data = msg.data;
    uint len = _data.length;
    bool success;
    assembly {
      mstore(_data, sig)
      success := staticcall(gas(), address(), add(_data, 28), add(len, 4), 0, 0)
    }
    _returnReturnData(success);
  }

  function _returnReturnData(bool _success) internal pure {
    assembly {
      let returndatastart := 0
      returndatacopy(returndatastart, 0, returndatasize())
      switch _success case 0 { revert(returndatastart, returndatasize()) }
        default { return(returndatastart, returndatasize()) }
    }
  }

  function viewCall() external {
    if (msg.sender != address(this)) revert OnlyThis();
    bytes memory _data = msg.data[4:];
    address _view = VIEW;
    bool success;
    assembly {
      success := delegatecall(gas(), _view, add(_data, 32), mload(_data), 0, 0)
    }
    _returnReturnData(success);
  }

  /*//////////////////////////////////////////////////////////////
                           OWNER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Transfer the contract balance to the owner.
  /// @dev Allowed for rewards tokens cannot be withdrawn.
  /// @param _token The token contract address or zero for native currency.
  /// @param _to The receiver address or zero for caller address.
  /// @param _amount The amount of token to withdraw or zero for full amount.
  function withdraw(address _token, address payable _to, uint _amount) external onlyAdmin() {
    if (_tokenAllowed(_token)) revert RewardWithdrawalDenied(_token);
    if (_to == payable(0)) {
      _to = payable(_msgSender());
    }
    emit Withdraw(_token, _to, _amount);
    if (_token == address(0)) {
      _to.sendValue(_amount == 0 ? address(this).balance : _amount);
      return;
    }
    _transferToken(_token, RewardType.ERC20, _to, 0, _amount == 0 ? _tryBalanceOfThis(_token) : _amount);
  }

  function mintToMany(address[] calldata _tos, uint[] calldata _lootboxTypes, uint[] calldata _amounts) external onlyRole(MINTER_ROLE) {
    uint len = _tos.length;
    if (len != _lootboxTypes.length || len != _amounts.length) revert InvalidLength();
    for (uint i = 0; i < len; ++i) {
      _mint(_tos[i], _lootboxTypes[i], _amounts[i], '');
    }
  }

  /*//////////////////////////////////////////////////////////////
                              VRF LOGIC
  //////////////////////////////////////////////////////////////*/

  /// @notice Requests randomness from Chainlink VRF.
  /// @dev The VRF subscription must be active and sufficient LINK must be available.
  /// @return requestId The ID of the request.
  function _requestRandomness(uint32 _gas) internal returns (uint256 requestId) {
    return requestRandomness(
      _gas,
      REQUEST_CONFIRMATIONS,
      NUMWORDS
    );
  }

  /// @inheritdoc VRFV2WrapperConsumerBase
  function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
    try this._allocateRewards{gas: gasleft() - 20000}(requestId, randomWords[0]) {
      emit OpenRequestFulfilled(requestId, randomWords[0]);
    } catch (bytes memory reason) {
      Request storage request = requests[requestId];
      unitsRequested = unitsRequested - request.unitsToGet;
      request.unitsToGet = 0;
      emit OpenRequestFailed(requestId, reason);
    }
  }

  /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Removes an authorized supplier for the contract.
  /// @param _address The address being removed.
  function _removeSupplier(address _address) internal {
    if (suppliers.remove(_address)) {
      emit SupplierRemoved(_address);
    }
  }

  /// @notice Adds a supplier for the contract.
  /// @param _address The address being added.
  function _addSupplier(address _address) internal {
    if (suppliers.add(_address)) {
      emit SupplierAdded(_address);
    }
  }

  /// @notice Adds a supplier for the contract.
  /// @param _token The token address being added.
  function _addToken(address _token) internal {
    if (_token == address(0)) revert TokenDenied(_token);
    if (allowedTokens.add(_token)) {
      emit TokenAdded(_token);
    }
  }

  // TODO: Deal with the ERC721 sent through simple transferFrom, instead of safeTransferFrom.
  /// @notice Sets amount per unit.
  /// @param _currentSupply The current supply of units.
  /// @param _token The token being supplied.
  /// @param _id The id being used.
  /// @param _amountPerUnit The amount per unit.
  /// @return uint The new supply of units after calculation.
  function _setAmountPerUnit(uint _currentSupply, address _token, uint _id, uint _amountPerUnit) internal returns (uint) {
    if (_not(_tokenAllowed(_token))) revert TokenDenied(_token);
    Reward storage reward = rewards[_token];
    uint unitsOld = units(reward.rewardInfo);
    uint unitsNew;
    RewardType rewardType = reward.rewardType;
    if (rewardType == RewardType.UNSET) {
      // Assuming ERC20.
      if (_tryBalanceOfThis(_token) == 0) revert NoTokens();
      rewardType = RewardType.ERC20;
      reward.rewardType = rewardType;
    }

    uint newAmountPerUnit = _amountPerUnit;
    if (rewardType == RewardType.ERC20) {
      unitsNew = _amountPerUnit == 0 ? 0 : (_tryBalanceOfThis(_token) - allocated[_token][0]) / _amountPerUnit;
    } else if (rewardType == RewardType.ERC721 || rewardType == RewardType.ERC1155NFT) {
      unitsNew = _amountPerUnit == 0 ? 0 : reward.ids.length() / _amountPerUnit;
    } else if (rewardType == RewardType.ERC1155) {
      uint tokenUnitsOld = units(reward.extraInfo[_id]);
      uint balance = _balanceOfThis1155(_token, _id) - allocated[_token][_id];
      uint tokenUnitsNew = _amountPerUnit == 0 ? 0 : balance / _amountPerUnit;
      reward.extraInfo[_id] = toInfo(tokenUnitsNew, _amountPerUnit);
      newAmountPerUnit = amountPerUnit(reward.rewardInfo);
      unitsNew = unitsOld - tokenUnitsOld + tokenUnitsNew;
      if (tokenUnitsNew > 0) {
        reward.ids.add(_id);
      } else {
        reward.ids.remove(_id);
      }
    }
    reward.rewardInfo = toInfo(unitsNew, newAmountPerUnit);
    uint newSupply = _currentSupply - unitsOld + unitsNew;
    if (unitsNew > 0) {
      inventory.add(_token);
    } else {
      inventory.remove(_token);
    }

    emit AmountPerUnitSet(_token, _id, _amountPerUnit, newSupply);
    return newSupply;
  }

  /// @notice Gets LINK price.
  /// @return uint The link price from wei converted to uint.
  function _getLinkPrice() internal view returns (uint) {
    int256 weiPerUnitLink;
    (, weiPerUnitLink, , , ) = LINK_ETH_FEED.latestRoundData();
    if (weiPerUnitLink <= 0) revert InvalidLinkPrice(weiPerUnitLink);
    return uint(weiPerUnitLink);
  }

  /// @notice Allows specific 1155 tokens to be used in the inventory.
  /// @param token The token address.
  /// @param id The token id.
  /// @param value The token value.
  function _supply1155(address token, uint id, uint value) internal {
    if (value == 0) revert ZeroSupply(token, id);
    Reward storage reward = rewards[token];
    RewardInfo rewardInfo = reward.rewardInfo;
    RewardType rewardType = reward.rewardType;
    bool isFirstTime = rewardType == RewardType.UNSET;
    if (isFirstTime) {
      if (value == 1) {
        // If the value is 1, then we assume token to be distributed as NFT.
        rewardInfo = toInfo(0, 1);
        reward.rewardInfo = rewardInfo;
        rewardType = RewardType.ERC1155NFT;
      } else {
        rewardType = RewardType.ERC1155;
      }
      reward.rewardType = rewardType;
    } else if (rewardType != RewardType.ERC1155 && rewardType != RewardType.ERC1155NFT) {
      revert ModifiedRewardType(reward.rewardType, RewardType.ERC1155);
    }
    if (rewardType == RewardType.ERC1155) {
      _supply1155(reward, rewardInfo, token, id, value);
    } else {
      if (value > 1) revert InvalidTokenAmount();
      _supplyNFT(reward, rewardInfo, token, id);
    }
  }

  /// @notice Allows specific 1155 tokens to be used in the inventory with reward information.
  /// @param rewardInfo The reward information.
  /// @param token The token address.
  /// @param id The token id.
  /// @param value The token value.
  function _supply1155(Reward storage reward, RewardInfo rewardInfo, address token, uint id, uint value) internal {
    RewardInfo extraInfo = reward.extraInfo[id];
    bool isNotConfigured = isEmpty(extraInfo);
    uint unitsOld = units(extraInfo);
    uint unitsNew = unitsOld + (isNotConfigured ? 0 : (value / amountPerUnit(extraInfo)));
    uint unitsAdded = unitsNew - unitsOld;
    if (unitsAdded > 0) {
      unitsSupply = unitsSupply + unitsAdded;
      reward.extraInfo[id] = toInfo(unitsNew, amountPerUnit(extraInfo));
      if (unitsOld == 0) {
        if (_not(reward.ids.add(id))) revert DepositStateCorruption(token, id);
      }
      uint tokenUnitsOld = units(rewardInfo);
      reward.rewardInfo = toInfo(tokenUnitsOld + unitsAdded, amountPerUnit(rewardInfo));
      if (tokenUnitsOld == 0) {
        if (_not(inventory.add(token))) revert InventoryStateCorruption(token);
      }
    }
    if (isNotConfigured) {
      extraIds[token].add(id);
    }
  }

  /// @notice Allows specific NFTs to be used in the inventory with reward information.
  /// @param rewardInfo The reward information.
  /// @param token The token address.
  /// @param id The token id.
  function _supplyNFT(Reward storage reward, RewardInfo rewardInfo, address token, uint id) internal {
    if (_not(reward.ids.add(id))) revert DepositStateCorruption(token, id);
    uint perUnit = amountPerUnit(rewardInfo);
    uint unitsOld = units(rewardInfo);
    uint unitsNew = perUnit == 0 ? 0 : (reward.ids.length() / perUnit);
    uint unitsAdded = unitsNew - unitsOld;
    if (unitsAdded > 0) {
      reward.rewardInfo = toInfo(unitsNew, perUnit);
      unitsSupply = unitsSupply + unitsAdded;
      if (unitsOld == 0) {
        if (_not(inventory.add(token))) revert InventoryStateCorruption(token);
      }
    }
  }

  /// @dev Requests randomness from Chainlink VRF and stores the request data for later use.
  /// @notice Creates a lootbox open request for the given loot.
  /// @param _opener The address requesting to open the lootbox.
  /// @param _gas The gas amount.
  /// @param _lootIds An array of loot ids.
  /// @param _lootAmounts An array of loot amounts.
  /// @return uint The units.
  function _requestOpen(
    address _opener,
    uint32 _gas,
    uint[] memory _lootIds,
    uint[] memory _lootAmounts
  ) internal returns (uint) {
    if (openerRequests[_opener] != 0) revert PendingOpenRequest(openerRequests[_opener]);
    if (_gas < 100000) revert InsufficientGas();
    _burnBatch(_opener, _lootIds, _lootAmounts);
    uint unitsToGet = 0;
    uint ids = _lootIds.length;
    for (uint i = 0; i < ids; ++i) {
      unitsToGet += _lootIds[i] * _lootAmounts[i];
    }
    if (unitsToGet == 0) revert ZeroAmount();
    uint unitsAvailable = unitsSupply - unitsRequested;
    if (unitsAvailable < unitsToGet) revert SupplyExceeded(unitsAvailable, unitsToGet);

    unitsRequested = unitsRequested + unitsToGet;
    uint256 requestId = _requestRandomness(_gas);

    requests[requestId] = Request({
      opener: _opener,
      unitsToGet: unitsToGet.toUint96(),
      lootIds: _lootIds,
      lootAmounts: _lootAmounts
    });

    openerRequests[_opener] = requestId;

    emit OpenRequested(_opener, unitsToGet, requestId);

    return unitsToGet;
  }

  function _allocate(address _token, uint _id, uint _amount) internal {
    allocated[_token][_id] += _amount;
  }

  function _deAllocate(address _token, uint _id, uint _amount) internal {
    allocated[_token][_id] -= _amount;
  }

  function _emitAllocated(address _to, address _token, uint _id, uint _amount) internal {
    emit Allocated(_to, _token, _id, _amount);
  }

  function _emitClaimed(address _claimer, address _token, uint _id, uint _amount) internal {
    emit RewardsClaimed(_claimer, _token, _id, _amount);
  }

  /// @notice Picks the rewards using the given randomness as a seed.
  /// @param _requestId The amount of lootbox units the user is opening.
  /// @param _randomness The random number used to pick the rewards.
  function _allocateRewards(
    uint256 _requestId,
    uint256 _randomness
  ) external {
    if (msg.sender != address(this)) revert OnlyThis();
    address opener = requests[_requestId].opener;
    uint unitsToGet = requests[_requestId].unitsToGet;
    if (unitsToGet == 0) revert InvalidRequestAllocation(_requestId);
    delete requests[_requestId];
    delete openerRequests[opener];
    uint256 totalUnits = unitsSupply;
    unitsSupply = totalUnits - unitsToGet;
    unitsRequested = unitsRequested - unitsToGet;

    for (; unitsToGet > 0; --unitsToGet) {
      uint256 target = uint256(keccak256(abi.encodePacked(_randomness, unitsToGet))) % totalUnits;
      uint256 offset = 0;

      for (uint256 j = 0;; ++j) {
        address token = inventory.at(j);
        AllocationInfo storage openerInfo = allocationInfo[opener][token];
        Reward storage reward = rewards[token];
        RewardType rewardType = reward.rewardType;
        uint256 unitsOfToken = units(reward.rewardInfo);

        if (target < offset + unitsOfToken) {
          --totalUnits;
          uint amount = amountPerUnit(reward.rewardInfo);
          reward.rewardInfo = toInfo(unitsOfToken - 1, amount);
          if (unitsOfToken - 1 == 0) {
            inventory.remove(token);
          }
          if (rewardType == RewardType.ERC20) {
            openerInfo.amount[0] += amount;
            _allocate(token, 0, amount);
            _emitAllocated(opener, token, 0, amount);
          }
          else if (rewardType == RewardType.ERC721 || rewardType == RewardType.ERC1155NFT) {
            uint ids = reward.ids.length();
            for (uint k = 0; k < amount; ++k) {
              target = uint256(keccak256(abi.encodePacked(_randomness, unitsToGet, k))) % ids;
              uint tokenId = reward.ids.at(target);
              reward.ids.remove(tokenId);
              --ids;
              openerInfo.ids.add(tokenId);
              _emitAllocated(opener, token, tokenId, 1);
            }
          }
          else if (rewardType == RewardType.ERC1155) {
            // Reusing variables before inevitable break of the loop.
            target = target - offset;
            offset = 0;
            for (uint k = 0;; ++k) {
              uint id = reward.ids.at(k);
              RewardInfo extraInfo = reward.extraInfo[id];
              unitsOfToken = units(extraInfo);
              if (target < offset + unitsOfToken) {
                amount = amountPerUnit(extraInfo);
                extraInfo = toInfo(unitsOfToken - 1, amount);
                reward.extraInfo[id] = extraInfo;
                openerInfo.ids.add(id);
                openerInfo.amount[id] += amount;
                _allocate(token, id, amount);
                if (units(extraInfo) == 0) {
                  reward.ids.remove(id);
                }
                _emitAllocated(opener, token, id, amount);
                break;
              }

              offset += unitsOfToken;
            }
          }
          else {
            revert UnexpectedRewardType(rewardType);
          }

          break;
        }

        offset += unitsOfToken;
      }
    }
  }

  function _tokenAllowed(address _token) internal view returns (bool) {
    return allowedTokens.contains(_token);
  }

  function _validateReceive(address _from) internal view returns (address) {
    address token = msg.sender;
    if (_not(_tokenAllowed(token))) revert TokenDenied(token);
    if (_not(suppliers.contains(_from))) revert SupplyDenied(_from);
    return token;
  }

  function _transferToken(address _token, RewardType _type, address _to, uint _id, uint _amount) internal {
    if (_type == RewardType.ERC20) {
      IERC20(_token).safeTransfer(_to, _amount);
    } else if (_type == RewardType.ERC721) {
      IERC721(_token).safeTransferFrom(address(this), _to, _id);
    } else if (_type == RewardType.ERC1155 || _type == RewardType.ERC1155NFT) {
      IERC1155(_token).safeTransferFrom(address(this), _to, _id, _amount, '');
    } else {
      revert UnexpectedRewardType(_type);
    }
  }

  /// @notice Checks the balance of an erc20 token.
  /// @param _token The token being checked.
  /// @return uint erc20 token balance, else 0 if not an erc20 token.
  function _tryBalanceOfThis(address _token) internal view returns (uint) {
    try IERC20(_token).balanceOf(address(this)) returns(uint result) {
      return result;
    } catch {
      // not an ERC20 so has to transfer first.
      return 0;
    }
  }

  function _balanceOfThis1155(address _token, uint _id) internal view returns (uint) {
    return IERC1155(_token).balanceOf(address(this), _id);
  }

  /// @notice Checks units by by reward information.
  /// @param _rewardInfo The reward information.
  /// @return RewardInfo Reward information as uint.
  function units(RewardInfo _rewardInfo) internal pure returns (uint) {
    return RewardInfo.unwrap(_rewardInfo) >> UNITS_OFFSET;
  }

  /// @notice Checks amount per unity by reward information.
  /// @param _rewardInfo The reward information.
  /// @return RewardInfo Reward information as uint.
  function amountPerUnit(RewardInfo _rewardInfo) internal pure returns (uint) {
    return uint184(RewardInfo.unwrap(_rewardInfo));
  }

  /// @notice Checks amount per unity by reward information.
  /// @param _units The reward information.
  /// @param _amountPerUnit The amount per unit.
  /// @return RewardInfo Reward information or amounts per unit.
  function toInfo(uint _units, uint _amountPerUnit) internal pure returns (RewardInfo) {
    if (_units > type(uint64).max) revert UnitsOverflow(_units);
    if (_amountPerUnit > type(uint184).max) revert AmountPerUnitOverflow(_amountPerUnit);
    return RewardInfo.wrap(uint248((_units << UNITS_OFFSET) | _amountPerUnit));
  }

  /// @notice Checks if reward information is empty.
  /// @param _rewardInfo The reaward information.
  /// @return RewardInfo Empty reward information.
  function isEmpty(RewardInfo _rewardInfo) internal pure returns (bool) {
    return RewardInfo.unwrap(_rewardInfo) == 0;
  }

  /// @notice Returns value bool.
  /// @param _value Boolean value.
  /// @return bool Opposite bool value.
  function _not(bool _value) internal pure returns (bool) {
    return !_value;
  }

  function _notEmergency() internal view {
    if (isEmergencyMode) revert EndOfService();
  }

  /**
   * @dev See {IERC165-supportsInterface}.
   */
  function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override(ERC1155Receiver, ERC1155PresetMinterPauser)
    returns (bool)
  {
    return ERC1155Receiver.supportsInterface(interfaceId) ||
      ERC1155PresetMinterPauser.supportsInterface(interfaceId);
  }

  /// @notice Fires after token transfer.
  /// @param operator Boolean value.
  /// @param from From address.
  /// @param to To address.
  /// @param ids Id array.
  /// @param amounts Amounts array.
  /// @param data Data in bytes.
  function _afterTokenTransfer(
    address operator,
    address from,
    address to,
    uint256[] memory ids,
    uint256[] memory amounts,
    bytes memory data
  ) internal virtual override {
    if (from == address(0)) {
      uint unitBoxesAdded = 0;
      uint len = ids.length;
      for (uint i = 0; i < len; ++i) {
        uint id = ids[i];
        if (id == 0 || id > type(uint8).max) revert InvalidLootboxType();
        lootboxTypes.add(id);
        unitBoxesAdded = unitBoxesAdded + (id * amounts[i]);
      }
      unitsMinted = unitsMinted + unitBoxesAdded;
    }
    if (to == address(0)) {
      uint unitBoxesRemoved = 0;
      uint len = ids.length;
      for (uint i = 0; i < len; ++i) {
        unitBoxesRemoved = unitBoxesRemoved + (ids[i] * amounts[i]);
      }
      unitsMinted = unitsMinted - unitBoxesRemoved;
    }
    super._afterTokenTransfer(operator, from, to, ids, amounts, data);
  }
}
