// SPDX-License-Identifier: MIT
pragma solidity ^0.5.4;

interface ITRC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract P2PExchange {
    ITRC20 public usdtToken;
    address public owner;
    bool public paused = false;
    bool internal locked;

    uint256 public offerCount;
    uint256 public orderCount;

    enum OfferStatus { Active, Completed, Cancelled }
    enum OrderStatus { Pending, Paid, Released, Cancelled, Disputed }
    enum TradeType { FIAT_FOR_USDT, USDT_FOR_FIAT }

    struct User {
        bool approved;
        uint256 reputation;
    }

    struct Offer {
        address seller;
        string instructions;
        string fiatCurrency;
        uint256 minQty;
        uint256 maxQty;
        uint256 rate;    // USDT per 1 fiat unit
        uint256 amount;  // USDT remaining in escrow
        uint256 deadline;
        OfferStatus status;
        TradeType tradeType;
    }

    struct Order {
        uint256 offerId;
        address buyer;
        uint256 fiatQuantity;
        uint256 usdtAmount;
        string paymentReceipt;
        OrderStatus status;
        bool appealRequested;
    }

    mapping(address => User) public users;
    mapping(uint256 => Offer) public offers;
    mapping(uint256 => Order) public orders;
    mapping(address => bool) public admins;

    // Events
    event OfferCreated(uint256 offerId, address seller, string fiatCurrency, uint256 rate, uint256 amount, TradeType tradeType);
    event OrderCreated(uint256 orderId, uint256 offerId, address buyer, uint256 fiatQuantity, uint256 usdtAmount);
    event OrderMarkedPaid(uint256 orderId, string paymentReceipt);
    event OrderReleased(uint256 orderId);
    event OrderCancelled(uint256 orderId);
    event AppealRequested(uint256 orderId);
    event DisputeResolved(uint256 orderId, bool releasedToBuyer);
    event Paused();
    event Unpaused();

    // Modifiers
    modifier noReentrancy() {
        require(!locked, "Reentrant call");
        locked = true;
        _;
        locked = false;
    }

    modifier onlyApproved() {
        require(users[msg.sender].approved, "Not approved");
        _;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "Not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "Contract is not paused");
        _;
    }

    // Constructor
    constructor(address _usdtToken) public {
        usdtToken = ITRC20(_usdtToken);
        owner = msg.sender;
        admins[msg.sender] = true;
    }

    // Pause/Unpause
    function pause() external onlyAdmin whenNotPaused {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyAdmin whenPaused {
        paused = false;
        emit Unpaused();
    }

    // Admin functions
    function setAdmin(address _admin, bool _status) external {
        require(msg.sender == owner, "Only owner");
        admins[_admin] = _status;
    }

    function approveUser(address _user) external onlyAdmin {
        users[_user].approved = true;
        users[_user].reputation = 100;
    }

    // --------------------
    // Offer creation
    // --------------------

    function createOfferFIATForUSDT(
        string calldata _instructions,
        string calldata _fiatCurrency,
        uint256 _minQty,
        uint256 _maxQty,
        uint256 _rate,
        uint256 _usdtAmount,
        uint256 _duration
    ) external onlyApproved whenNotPaused {
        require(_usdtAmount >= _minQty * _rate && _usdtAmount <= _maxQty * _rate, "Amount out of range");
        require(usdtToken.transferFrom(msg.sender, address(this), _usdtAmount), "Deposit failed");

        offerCount++;
        offers[offerCount] = Offer({
            seller: msg.sender,
            instructions: _instructions,
            fiatCurrency: _fiatCurrency,
            minQty: _minQty,
            maxQty: _maxQty,
            rate: _rate,
            amount: _usdtAmount,
            deadline: block.timestamp + _duration,
            status: OfferStatus.Active,
            tradeType: TradeType.FIAT_FOR_USDT
        });

        emit OfferCreated(offerCount, msg.sender, _fiatCurrency, _rate, _usdtAmount, TradeType.FIAT_FOR_USDT);
    }

    function createOfferUSDTForFiat(
        string calldata _instructions,
        string calldata _fiatCurrency,
        uint256 _minQty,
        uint256 _maxQty,
        uint256 _rate,
        uint256 _usdtAmount,
        uint256 _duration
    ) external onlyApproved whenNotPaused {
        require(_usdtAmount >= _minQty * _rate && _usdtAmount <= _maxQty * _rate, "Amount out of range");
        require(usdtToken.transferFrom(msg.sender, address(this), _usdtAmount), "Deposit failed");

        offerCount++;
        offers[offerCount] = Offer({
            seller: msg.sender,
            instructions: _instructions,
            fiatCurrency: _fiatCurrency,
            minQty: _minQty,
            maxQty: _maxQty,
            rate: _rate,
            amount: _usdtAmount,
            deadline: block.timestamp + _duration,
            status: OfferStatus.Active,
            tradeType: TradeType.USDT_FOR_FIAT
        });

        emit OfferCreated(offerCount, msg.sender, _fiatCurrency, _rate, _usdtAmount, TradeType.USDT_FOR_FIAT);
    }

    // --------------------
    // Buyer creates order (partial fills supported)
    // --------------------
    function createOrder(uint256 _offerId, uint256 _fiatQuantity) external onlyApproved whenNotPaused {
        Offer storage offer = offers[_offerId];
        require(offer.status == OfferStatus.Active, "Offer not active");
        require(_fiatQuantity >= offer.minQty && _fiatQuantity <= offer.maxQty, "Quantity out of bounds");

        uint256 usdtAmount = _fiatQuantity * offer.rate;
        require(usdtAmount <= offer.amount, "Insufficient USDT in offer");

        orderCount++;
        orders[orderCount] = Order({
            offerId: _offerId,
            buyer: msg.sender,
            fiatQuantity: _fiatQuantity,
            usdtAmount: usdtAmount,
            paymentReceipt: "",
            status: OrderStatus.Pending,
            appealRequested: false
        });

        // Deduct from offer escrow
        offer.amount -= usdtAmount;
        if (offer.amount == 0) offer.status = OfferStatus.Completed;

        emit OrderCreated(orderCount, _offerId, msg.sender, _fiatQuantity, usdtAmount);
    }

    // --------------------
    // Mark paid
    // --------------------
    function markPaid(uint256 _orderId, string calldata _receipt) external onlyApproved whenNotPaused {
        Order storage order = orders[_orderId];
        require(order.buyer == msg.sender, "Not your order");
        require(order.status == OrderStatus.Pending, "Cannot mark paid");

        order.paymentReceipt = _receipt;
        order.status = OrderStatus.Paid;

        emit OrderMarkedPaid(_orderId, _receipt);
    }

    // --------------------
    // Release USDT
    // --------------------
    function release(uint256 _orderId) external onlyApproved noReentrancy whenNotPaused {
        Order storage order = orders[_orderId];
        Offer storage offer = offers[order.offerId];

        require(msg.sender == offer.seller, "Not seller");
        require(order.status == OrderStatus.Paid, "Order not paid");

        order.status = OrderStatus.Released;
        usdtToken.transfer(order.buyer, order.usdtAmount);

        users[order.buyer].reputation += 5;
        users[offer.seller].reputation += 5;

        emit OrderReleased(_orderId);
    }

    // --------------------
    // Cancel order
    // --------------------
    function cancelOrder(uint256 _orderId) external noReentrancy whenNotPaused {
        Order storage order = orders[_orderId];
        Offer storage offer = offers[order.offerId];

        require(msg.sender == order.buyer || msg.sender == offer.seller || admins[msg.sender], "Not authorized");
        require(order.status == OrderStatus.Pending || order.status == OrderStatus.Paid, "Cannot cancel");

        order.status = OrderStatus.Cancelled;
        offer.amount += order.usdtAmount;

        users[order.buyer].reputation -= 2;
        users[offer.seller].reputation -= 2;

        emit OrderCancelled(_orderId);
    }

    // --------------------
    // Appeal request
    // --------------------
    function requestAppeal(uint256 _orderId) external onlyApproved whenNotPaused {
        Order storage order = orders[_orderId];
        Offer storage offer = offers[order.offerId];
        require(msg.sender == order.buyer || msg.sender == offer.seller, "Not allowed");

        order.appealRequested = true;
        order.status = OrderStatus.Disputed;

        emit AppealRequested(_orderId);
    }

    // --------------------
    // Resolve dispute
    // --------------------
    function resolveDispute(uint256 _orderId, bool releaseToBuyer) external onlyAdmin noReentrancy whenNotPaused {
        Order storage order = orders[_orderId];
        Offer storage offer = offers[order.offerId];
        require(order.status == OrderStatus.Disputed, "Not disputed");

        if (releaseToBuyer) {
            order.status = OrderStatus.Released;
            usdtToken.transfer(order.buyer, order.usdtAmount);
            users[order.buyer].reputation += 5;
        } else {
            order.status = OrderStatus.Cancelled;
            offer.amount += order.usdtAmount;
            users[offer.seller].reputation += 5;
        }

        emit DisputeResolved(_orderId, releaseToBuyer);
    }
}
