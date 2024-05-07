// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {
    Ownable,
    Pausable,
    SafeERC20,
    IERC20,
    Address
} from "./Base.sol";

/**
 * @title SoulBounds
 * @notice This contract allows minting, burning, and updating soul-bound assets with unique identities.
 * @dev The contract relies on Ownable and Pausable modifiers and uses SafeERC20 and Address libraries.
 */
contract SoulBounds is Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Address for address;

    IERC20 private _baseAsset;

    /**
     * @dev Represents an individual's soul, consisting of their identity, associated URL, and metadata.
     */
    struct Soul {
        string identity;
        string url;
        uint256 mintedAt;
        uint256 lastUpdate;
        bytes16 uuid;
    }

    uint256 private constant _THOUSAND = 1_000;
    uint256 private constant _MAX_RETRIES = 2;
    uint256 private _soulTicker;
    bytes32 private _baseHash;

    mapping(address => Soul) private _souls;
    mapping(bytes32 => bool) private _identityTicker;
    mapping(bytes16 => bool) private _uuidTicker;
    mapping(bytes32 => bool) private _allowedKeys;
    mapping(address => mapping(bytes32 => bytes)) private _soulMetadata;
    mapping(address => bytes32[]) private _metadataKeys;

    /**
     * @dev Emitted when a new soul is minted.
     * @param _soul Address associated with the newly minted soul.
     */
    event Mint(address indexed _soul);

    /**
     * @dev Emitted when an existing soul is burned.
     * @param _soul Address associated with the burned soul.
     */
    event Burn(address indexed _soul);

    /**
     * @dev Emitted when a soul's data is updated.
     * @param _soul Address of the updated soul.
     */
    event Update(address indexed _soul);

    /**
     * @dev Emitted when tokens are withdrawn.
     * @param _owner Address initiating the withdrawal.
     * @param _destination Address receiving the withdrawn tokens.
     * @param _amount Amount of tokens withdrawn.
     */
    event Withdrawal(address indexed _owner, address indexed _destination, uint256 indexed _amount);

    // Errors
    error MetadataKeyNotAllowed();
    error SoulAlreadyExist();
    error IdentityIsNotUnique();
    error EmptyUrl();
    error UnauthorizedBurning();
    error SoulDoesNotExist();
    error MaxRetriesReached();
    error InvalidAddressInteraction();
    error InvalidContractInteraction();
    error TokenAmountIsZero();
    error NotPermitted();

    // Modifiers

    /**
     * @dev Ensures that the caller is either the owner or the specified soul address.
     * @param _soul Address of the soul being validated.
     */
    modifier onlyOwnerOrUser(address _soul) {
        if (msg.sender != _soul && msg.sender != owner()) revert UnauthorizedBurning();
        _;
    }

    /**
     * @dev Validates that the provided address is a smart contract.
     * @param _address Address to validate.
     */
    modifier validContract(address _address) {
        if (!_address.isContract()) {
            revert InvalidContractInteraction();
        }
        _;
    }

    /**
     * @dev Validates that the provided address is not the zero address.
     * @param _address Address to validate.
     */
    modifier validAddress(address _address) {
        if (_address == address(0)) {
            revert InvalidAddressInteraction();
        }
        _;
    }

    /* setup -------------------------------------------------------------------------------------- */

    /**
     * @dev Sets up the base asset and computes the initial base hash.
     * @param _token Address of the base asset token.
     */
    constructor(address _token) {
        if (!_token.isContract()) revert InvalidContractInteraction();
        _baseAsset = IERC20(_token);
        _baseHash = keccak256(abi.encodePacked(_token));
    }

    receive() external payable {
        revert NotPermitted();
    }

    fallback() external payable {
        revert NotPermitted();
    }

    /* mechanics -----------------------------------------------------------------------------------*/

    /**
     * @notice Mints a new soul with specified data.
     * @dev Only the owner can mint new souls.
     * @param _soul Address of the new soul to be minted.
     * @param _identity Identity field of the soul to be minted.
     * @param _url URL field of the soul to be minted.
     */
    function mint(address _soul, bytes calldata _identity, bytes calldata _url)
        external
        validAddress(_soul)
        onlyOwner
        whenNotPaused
    {
        _sanitizeAndValidate(_soul, _identity, _url);

        // Register the new soul
        Soul memory newSoul = Soul({
            identity: string(_identity),
            url: string(_url),
            mintedAt: block.timestamp,
            lastUpdate: block.timestamp,
            uuid: _generateUUID(_soul, 1)
        });

        _souls[_soul] = newSoul;
        _identityTicker[keccak256(_identity)] = true;
        _uuidTicker[newSoul.uuid] = true;
        _soulTicker += 1;

        emit Mint(_soul);
    }

    /**
     * @notice Burns an existing soul.
     * @param _soul Address of the soul to be burned.
     */
    function burn(address _soul)
        external
        validAddress(_soul)
        onlyOwnerOrUser(_soul)
        whenNotPaused
    {
        bytes16 uuidToClear = _souls[_soul].uuid;
        delete _souls[_soul];
        _uuidTicker[uuidToClear] = false;
        emit Burn(_soul);
    }

    /**
     * @dev Validates and sanitizes the Soul data fields, considering only specific fields.
     * @param _soul Address associated with the Soul.
     * @param _identity Identity field of the Soul to validate, represented as bytes.
     * @param _url URL field of the Soul to validate, represented as bytes.
     */
    function _sanitizeAndValidate(address _soul, bytes calldata _identity, bytes calldata _url) internal view {
        // Check if the identity is unique
        if (_identityTicker[keccak256(_identity)]) {
            revert IdentityIsNotUnique();
        }

        // Check if the URL is empty
        if (_url.length == 0) {
            revert EmptyUrl();
        }

        bool soulExists = keccak256(bytes(_souls[_soul].identity)) != _baseHash;

        if (!soulExists && msg.sig == this.mint.selector) {
            revert SoulAlreadyExist();
        }
    }

    /* getters ------------------------------------------------------------------------------------ */

    /**
     * @notice Returns the address of the base asset token.
     * @return address Address of the base asset token.
     */
    function getBaseAsset() external view returns (address) {
        return address(_baseAsset);
    }

    /**
    * @notice Returns the data of a specified soul with optional metadata.
    * @param _soul Address of the soul.
    * @param _includeMetadata If true, includes all metadata in the returned data.
    * @return soulData Memory representation of the soul data.
    * @return keys Array of all metadata keys (if requested).
    * @return values Array of associated values (if requested).
    */
    function getSoul(address _soul, bool _includeMetadata)
    external
    view
    validAddress(_soul)
    returns (Soul memory soulData, bytes32[] memory keys, bytes[] memory values)
    {

        bool soulExists = keccak256(bytes(_souls[_soul].identity)) != _baseHash;
        if (!soulExists) revert SoulDoesNotExist();

        soulData = _souls[_soul];

        if (_includeMetadata) {
            (keys, values) = _getAllMetadata(_soul);
        }

        return (soulData, keys, values);
    }

    /**
     * @dev Checks if a given metadata key is allowed.
     * @param _key Key identifier of the metadata field.
     * @return bool True if the key is allowed, otherwise false.
     */
    function isMetadataKeyAllowed(bytes32 _key) external view returns (bool) {
        return _allowedKeys[_key];
    }

    /**
     * @dev Returns the metadata value for a given soul address and key.
     * @param _soul Address of the soul.
     * @param _key Key identifier of the metadata field.
     * @return Value of the requested metadata field as bytes.
     */
    function getMetadata(address _soul, bytes32 _key) external view returns (bytes memory) {
        return _soulMetadata[_soul][_key];
    }

    /**
     * @notice Returns the current soul ticker (nonce).
     * @return uint256 Current soul ticker value.
     */
    function getNounce() external view returns (uint256) {
        return _soulTicker;
    }

    /**
     * @dev Returns the current chain ID.
     * @return uint256 Current chain ID.
     */
    function _chainID() private view returns (uint256) {
        uint256 chainID;
        /* solhint-disable */
        assembly {
            chainID := chainid()
        }
         /* solhint-enable */
        return chainID;
    }

    /* setter ------------------------------------------------------------------------------------- */

    /**
     * @dev Adds a new metadata key to the whitelist.
     * @param _key The key to be added to the whitelist.
     */
     function allowMetadataKey(bytes32 _key) external onlyOwner {
        _allowedKeys[_key] = true;
    }

    /**
     * @dev Removes a metadata key from the whitelist.
     * @param _key The key to be removed from the whitelist.
     */
    function disallowMetadataKey(bytes32 _key) external onlyOwner {
        _allowedKeys[_key] = false;
    }

    /**
     * @dev Sets or updates metadata for a given soul address if the key is allowed.
     * @param _soul Address of the soul to update.
     * @param _key Key identifier of the metadata field.
     * @param _value New value of the metadata field.
     */
    function setMetadata(address _soul, bytes32 _key, bytes calldata _value) external onlyOwner whenNotPaused {
        if (!_allowedKeys[_key]) revert MetadataKeyNotAllowed();

        // Track the key if it's a new entry for this soul
        if (_soulMetadata[_soul][_key].length == 0) {
            _metadataKeys[_soul].push(_key);
        }

        _soulMetadata[_soul][_key] = _value;
    }

    /**
     * @dev Deletes metadata for a given soul address and key.
     * @param _soul Address of the soul.
     * @param _key Key identifier of the metadata field.
     */
    function deleteMetadata(address _soul, bytes32 _key) external onlyOwner whenNotPaused {
        if (!_allowedKeys[_key]) revert MetadataKeyNotAllowed();
        delete _soulMetadata[_soul][_key];
    }

    /* internal ------------------------------------------------------------------------------------- */

    /**
    * @notice Returns all metadata for a specified soul as arrays of keys and values.
    * @param _soul Address of the soul.
    * @return keys Array of all metadata keys.
    * @return values Array of associated values.
    */
    function _getAllMetadata(address _soul) internal view returns (bytes32[] memory keys, bytes[] memory values) {
        uint256 count = _metadataKeys[_soul].length;
        keys = new bytes32[](count);
        values = new bytes[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 key = _metadataKeys[_soul][i];
            keys[i] = key;
            values[i] = _soulMetadata[_soul][key];
        }

        return (keys, values);
    }

    /**
     * @dev Returns the starting token ID for minting.
     * @return uint256 The starting token ID.
     */
    function _startTokenId() internal pure returns (uint256) {
        return _THOUSAND;
    }

    /**
     * @dev Generates a unique UUID for a given soul.
     * @param _soul Address of the soul.
     * @param _retry Number of retries attempted so far.
     * @return bytes16 Generated UUID.
     */
    function _generateUUID(address _soul, uint256 _retry) internal view returns (bytes16) {
        bytes16 uuid = bytes16(keccak256(abi.encodePacked(
            block.timestamp, _soul, _soulTicker, _baseHash, _chainID())));
        if (_uuidTicker[uuid]) {
            if (_retry > _MAX_RETRIES) revert MaxRetriesReached();
            return _generateUUID(_soul, _retry + 1);
        } else {
            return uuid;
        }
    }

    /* administrator -------------------------------------------------------------------------------- */

    /**
     * @notice Withdraws tokens from the contract.
     * @dev Only the owner can withdraw tokens.
     * @param _tokenAddress Address of the token to withdraw.
     * @param _to Address to receive the withdrawn tokens.
     * @param _amount Amount of tokens to withdraw.
     */
    function rescueTokens(address _tokenAddress, address _to, uint256 _amount)
        external
        validContract(_tokenAddress)
        validAddress(_to)
        onlyOwner
    {
        if (_amount == 0) revert TokenAmountIsZero();
        SafeERC20.safeTransfer(IERC20(_tokenAddress), _to, _amount);
        emit Withdrawal(_tokenAddress, _to, _amount);
    }

    /**
     * @notice Pauses the contract, disabling state-changing functions.
     * @dev Only the owner can pause the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract, enabling state-changing functions.
     * @dev Only the owner can unpause the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}
