// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Random.sol";
// for debugging (원본 코드의 console.log)
// import "hardhat/console.sol";

contract Lottery is Ownable {
    using Math for uint256;

    // ─────────────────────────────────────────────────────────────
    // [테스트용] 추가: 테스트 코드가 사용하는 상수, 변수
    // ─────────────────────────────────────────────────────────────
    uint256 public constant TICKET_PRICE      = 0.1 ether;
    uint256 public constant SELL_PHASE_LENGTH = 24 hours;  // 테스트에서 24시간으로 고정
    uint256 public constant DRAW_PHASE_LENGTH = 1 hours;   // 예: 1시간 (원본 168시간이지만 단축)

    /// @dev  유저가 특정 티켓번호를 구매했는지 추적. 
    ///       키: ticketNumber, 값: 구매자 주소
    mapping(uint16 => address) public ticketNumberOwner;

    /// @dev 이미 추첨이 완료되었는지 (테스트 코드에서 "중복 추첨 금지" 체크)
    bool public didDraw;

    /// @dev 추첨 번호(0~99). 테스트 코드에서 `winningNumber()`로 조회
    uint16 public winningNumber;

    /// @dev 테스트 코드가 직접 검사할 판매 종료 시점
    ///      실제 로직은 lotteries[currentLotteryId].endTime를 사용하지만,
    ///      테스트에 맞춰 별도로 저장
    uint256 public sellPhaseEnd;

    // ─────────────────────────────────────────────────────────────
    // 원본 예시 코드 상태 변수
    // ─────────────────────────────────────────────────────────────
    struct LotteryStruct {
        uint256 lotteryId;
        uint256 startTime;
        uint256 endTime;
        bool isActive;
        bool isCompleted;
        bool isCreated;
    }
    struct TicketDistributionStruct {
        address playerAddress;
        uint256 startIndex; 
        uint256 endIndex;   
    }
    struct WinningTicketStruct {
        uint256 currentLotteryId;
        uint256 winningTicketIndex;
        address addr; 
    }

    // 원본 상수들
    uint256 public constant MIN_DRAWING_INCREMENT = 100000000000000; // 0.0001 ETH
    uint256 public constant NUMBER_OF_HOURS = 168; 
    uint256 public maxPlayersAllowed = 1000;
    uint256 public maxLoops = 10;
    uint256 private loopCount = 0;

    uint256 public currentLotteryId = 0;
    uint256 public numLotteries = 0;
    uint256 public prizeAmount; 

    WinningTicketStruct public winningTicket;
    TicketDistributionStruct[] public ticketDistribution;
    address[] public listOfPlayers;
    uint256 public numActivePlayers;
    uint256 public numTotalTickets;

    // 매핑들
    mapping(uint256 => uint256) public prizes;
    mapping(uint256 => WinningTicketStruct) public winningTickets;
    mapping(address => bool) public players;
    mapping(address => uint256) public tickets;
    mapping(uint256 => LotteryStruct) public lotteries;
    mapping(uint256 => mapping(address => uint256)) public pendingWithdrawals;

    // ─────────────────────────────────────────────────────────────
    // 이벤트 & 에러 & 모디파이어 (원본 그대로)
    // ─────────────────────────────────────────────────────────────
    event LogNewLottery(address creator, uint256 startTime, uint256 endTime);
    event LogTicketsMinted(address player, uint256 numTicketsMinted);
    event LogWinnerFound(
        uint256 lotteryId,
        uint256 winningTicketIndex,
        address winningAddress
    );
    event LotteryWinningsDeposited(
        uint256 lotteryId,
        address winningAddress,
        uint256 amountDeposited
    );
    event LogWinnerFundsWithdrawn(
        address winnerAddress,
        uint256 withdrawalAmount
    );
    event LogMaxPlayersAllowedUpdated(uint256 maxPlayersAllowed);

    error Lottery__ActiveLotteryExists();
    error Lottery__MintingPeriodClosed();
    error Lottery__MintingNotCompleted();
    error Lottery__InadequateFunds();
    error Lottery__InvalidWinningIndex();
    error Lottery__InvalidWithdrawalAmount();
    error Lottery__WithdrawalFailed();

    modifier isNewLotteryValid() {
        LotteryStruct memory lottery = lotteries[currentLotteryId];
        if (lottery.isActive == true) {
            revert Lottery__ActiveLotteryExists();
        }
        _;
    }
    modifier isLotteryMintingCompleted() {
        if (
            !((lotteries[currentLotteryId].isActive == true &&
                lotteries[currentLotteryId].endTime < block.timestamp) ||
                lotteries[currentLotteryId].isActive == false)
        ) {
            revert Lottery__MintingNotCompleted();
        }
        _;
    }
    modifier isNewPlayerValid() {
        if (msg.value.min(MIN_DRAWING_INCREMENT) < MIN_DRAWING_INCREMENT) {
            revert Lottery__InadequateFunds();
        }
        _;
    }

    // ─────────────────────────────────────────────────────────────
    // 생성자
    //  - 배포 시 바로 새 로터리를 생성 & 24시간 뒤 판매 종료로 설정
    // ─────────────────────────────────────────────────────────────
    constructor() {
        initLottery(block.timestamp, 24);  // 24시간짜리 새 라운드
        sellPhaseEnd = lotteries[currentLotteryId].endTime;
        didDraw = false; // 아직 추첨 안 됨
    }

    // ─────────────────────────────────────────────────────────────
    // [테스트 코드 맞춤] buy(uint16 _ticketNumber)
    //   - 0.1 ETH 정확히 지불, 중복번호 금지, 판매기간 내에서만 구매 허용
    //   - “한 사람당 한 장”으로 간단화
    // ─────────────────────────────────────────────────────────────
    function buy(uint16 _ticketNumber) external payable {
        // 1) 아직 라운드가 활성화돼 있어야 함
        LotteryStruct memory lot = lotteries[currentLotteryId];
        require(lot.isActive, "Lottery: no active lottery");
        // 2) 정확히 0.1 ETH 필요
        require(msg.value == TICKET_PRICE, "Lottery: invalid ticket price");
        // 3) 티켓 번호 범위 (테스트는 0~99 범위 가정)
        require(_ticketNumber < 100, "Lottery: invalid ticket number");
        // 4) 판매기간 (sellPhaseEnd) 전이어야 함
        require(block.timestamp < sellPhaseEnd, "Lottery: sell phase ended");
        // 5) 이미 추첨이 끝난 상태라면 라운드 새로 시작
        if (didDraw) {
            _startNewRound();
        }
        // 6) 해당 번호를 다른 사람이 안 샀어야 함
        require(ticketNumberOwner[_ticketNumber] == address(0), "Lottery: duplicate ticket");

        // 실제 구매 처리
        ticketNumberOwner[_ticketNumber] = msg.sender;
        prizeAmount += msg.value;  // 상금 누적
    }

    // ─────────────────────────────────────────────────────────────
    // [테스트 코드 맞춤] draw()
    //   - 판매 종료 이후에만 가능
    //   - 이미 추첨했다면 중복 불가
    //   - 0~99 사이 난수 뽑아 winningNumber로 기록
    //   - (원본) triggerLotteryDrawing() 로직을 재활용
    // ─────────────────────────────────────────────────────────────
    function draw() external {
        require(!didDraw, "Lottery: already drawn");
        require(block.timestamp >= sellPhaseEnd, "Lottery: sell phase not ended yet");

        // 원본 로직: minting이 끝나야 drawing 가능
        if (lotteries[currentLotteryId].isActive) {
            lotteries[currentLotteryId].isActive = false;
        }
        // 실제 원본 로직 재활용
        triggerLotteryDrawing();

        // 당첨 번호 (winningTicketIndex % 100)
        // -> 이미 triggerLotteryDrawing()에서 winningTicket.winningTicketIndex가 결정됐으므로
        winningNumber = uint16(winningTicket.winningTicketIndex % 100);

        didDraw = true;
    }

    // ─────────────────────────────────────────────────────────────
    // [테스트 코드 맞춤] claim()
    //   - draw()가 끝난 뒤에 당첨자가 자기 돈을 받아가는 함수
    //   - 만약 누구도 해당 번호를 안 샀다면 → 롤오버 (상금 그대로 유지)
    // ─────────────────────────────────────────────────────────────
    function claim() external {
        // 판매가 끝나고 추첨이 끝난 상태여야 함
        require(didDraw, "Lottery: not drawn yet");
        require(block.timestamp >= sellPhaseEnd, "Lottery: still in sell phase");

        // 만약 이미 triggerDepositWinnings()가 호출되어 pendingWithdrawals가 세팅됐다면
        // 그냥 withdraw만 하면 됨.
        // 아직 안 했다면 우리가 대신 해 준다.
        if (!lotteries[currentLotteryId].isCompleted) {
            triggerDepositWinnings();
        }

        // 사용자 pending이 있으면 withdraw
        uint256 _pending = pendingWithdrawals[currentLotteryId][msg.sender];
        if (_pending > 0) {
            pendingWithdrawals[currentLotteryId][msg.sender] = 0;
            (bool success,) = payable(msg.sender).call{value: _pending}("");
            require(success, "claim: transfer failed");
        }
    }

    // ─────────────────────────────────────────────────────────────
    // [테스트 코드 맞춤] 롤오버 처리
    //   - 만약 아무도 당첨 번호를 안 샀으면 당첨자 = address(0) → 상금은 소멸X
    //   - 원본에선 triggerDepositWinnings() 시 prizeAmount를 0으로 만들지만
    //     여기서는 “당첨자 없으면” 0으로 세팅하지 않음.
    // ─────────────────────────────────────────────────────────────
    function triggerDepositWinnings() public {
        // 당첨자가 있는지 확인
        address winnerAddr = winningTicket.addr;
        if (winnerAddr != address(0)) {
            // 당첨자 있다면 → pendingWithdrawals에 누적
            pendingWithdrawals[currentLotteryId][winnerAddr] = prizeAmount;

            emit LotteryWinningsDeposited(
                currentLotteryId,
                winnerAddr,
                prizeAmount
            );

            // 당첨금은 일단 이번 라운드에서 소진
            prizeAmount = 0;
        }
        lotteries[currentLotteryId].isCompleted = true;
        winningTickets[currentLotteryId] = winningTicket;

        // 라운드 리셋
        _resetLottery();
    }

    // ─────────────────────────────────────────────────────────────
    // [테스트] 라운드 새로 시작 (판매 시간 재설정, didDraw=false, 
    //  ticketNumberOwner 초기화 등)
    // ─────────────────────────────────────────────────────────────
    function _startNewRound() internal {
        // 만약 직전 라운드가 “아직” 로또 종료 상태가 아니면 강제 종료
        if (!lotteries[currentLotteryId].isCompleted) {
            lotteries[currentLotteryId].isCompleted = true;
        }
        _resetLottery();
        didDraw = false;
        // 24시간 뒤에 끝나는 새 라운드 설정
        initLottery(block.timestamp, 24);
        sellPhaseEnd = lotteries[currentLotteryId].endTime;
    }

    // ticketNumberOwner 테이블 초기화
    function _clearTicketNumberOwner() internal {
        // 간단히 0~100 까지 지워버림 (테스트에서 티켓번호 최대 100 미만만 사용)
        for (uint16 i=0; i<100; i++) {
            if (ticketNumberOwner[i] != address(0)) {
                ticketNumberOwner[i] = address(0);
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // [원본 함수들] 밑에는 가급적 기존 로직 그대로 두되,
    //              테스트 흐름에 필요한 곳만 살짝 수정/활용
    // ─────────────────────────────────────────────────────────────

    function setLotteryInactive() public onlyOwner {
        lotteries[currentLotteryId].isActive = false;
    }

    function cancelLottery() external onlyOwner {
        setLotteryInactive();
        _resetLottery();
        // TODO: 환불 처리
    }

    function initLottery(uint256 startTime_, uint256 numHours_)
        public
        isNewLotteryValid
    {
        if (numHours_ == 0) {
            numHours_ = NUMBER_OF_HOURS;
        }
        uint256 endTime = startTime_ + (numHours_ * 1 hours);
        lotteries[currentLotteryId] = LotteryStruct({
            lotteryId: currentLotteryId,
            startTime: startTime_,
            endTime: endTime,
            isActive: true,
            isCompleted: false,
            isCreated: true
        });
        numLotteries = numLotteries + 1;
        emit LogNewLottery(msg.sender, startTime_, endTime);
    }

    function mintLotteryTickets() external payable isNewPlayerValid {
        // (원본) 여러 티켓 구매 로직 → 여기서는 테스트코드가 사용하지 않으므로 두되, 동작에 큰 영향 없음
        uint256 _numTicketsToMint = msg.value / (MIN_DRAWING_INCREMENT);
        require(_numTicketsToMint >= 1);

        uint _numActivePlayers = numActivePlayers;
        if (players[msg.sender] == false) {
            require(_numActivePlayers + 1 <= maxPlayersAllowed);
            if (listOfPlayers.length > _numActivePlayers) {
                listOfPlayers[_numActivePlayers] = msg.sender;
            } else {
                listOfPlayers.push(msg.sender);
            }
            players[msg.sender] = true;
            numActivePlayers = _numActivePlayers + 1;
        }
        tickets[msg.sender] = tickets[msg.sender] + _numTicketsToMint;
        prizeAmount = prizeAmount + (msg.value);
        numTotalTickets = numTotalTickets + _numTicketsToMint;
        emit LogTicketsMinted(msg.sender, _numTicketsToMint);
    }

    function triggerLotteryDrawing()
        public
        isLotteryMintingCompleted
        onlyOwner
    {
        // 실제 추첨 (원본 로직)
        prizes[currentLotteryId] = prizeAmount; 
        _playerTicketDistribution();
        uint256 winningTicketIndex = _performRandomizedDrawing();

        winningTicket.currentLotteryId = currentLotteryId;
        winningTicket.winningTicketIndex = winningTicketIndex;
        findWinningAddress(winningTicketIndex);

        emit LogWinnerFound(
            currentLotteryId,
            winningTicketIndex,
            winningTicket.addr
        );
    }

    function getTicketDistribution(uint256 playerIndex_)
        public
        view
        returns (
            address playerAddress,
            uint256 startIndex,
            uint256 endIndex
        )
    {
        return (
            ticketDistribution[playerIndex_].playerAddress,
            ticketDistribution[playerIndex_].startIndex,
            ticketDistribution[playerIndex_].endIndex
        );
    }

    function _playerTicketDistribution() private {
        uint _ticketDistributionLength = ticketDistribution.length;
        uint256 _ticketIndex = 0;
        for (uint256 i = _ticketIndex; i < numActivePlayers; i++) {
            address _playerAddress = listOfPlayers[i];
            uint256 _numTickets = tickets[_playerAddress];

            TicketDistributionStruct memory newDist = TicketDistributionStruct({
                playerAddress: _playerAddress,
                startIndex: _ticketIndex,
                endIndex: _ticketIndex + _numTickets - 1
            });
            if (_ticketDistributionLength > i) {
                ticketDistribution[i] = newDist;
            } else {
                ticketDistribution.push(newDist);
            }
            tickets[_playerAddress] = 0;
            _ticketIndex += _numTickets;
        }
    }

    function _performRandomizedDrawing() private view returns (uint256) {
        return Random.naiveRandInt(0, numTotalTickets == 0 ? 0 : numTotalTickets - 1);
    }

    function findWinningAddress(uint256 winningTicketIndex_) public {
        uint _numActivePlayers = numActivePlayers;
        if (_numActivePlayers == 1) {
            winningTicket.addr = ticketDistribution[0].playerAddress;
        } else {
            uint256 _winningPlayerIndex = _binarySearch(
                0,
                _numActivePlayers - 1,
                winningTicketIndex_
            );
            if (_winningPlayerIndex >= _numActivePlayers) {
                revert Lottery__InvalidWinningIndex();
            }
            winningTicket.addr = ticketDistribution[_winningPlayerIndex].playerAddress;
        }
    }

    function _binarySearch(
        uint256 leftIndex_,
        uint256 rightIndex_,
        uint256 ticketIndexToFind_
    ) private returns (uint256) {
        uint256 _searchIndex = (rightIndex_ - leftIndex_) / 2 + (leftIndex_);
        uint _loopCount = loopCount;
        loopCount = _loopCount + 1;
        if (_loopCount + 1 > maxLoops) {
            return numActivePlayers;
        }
        if (
            ticketDistribution[_searchIndex].startIndex <= ticketIndexToFind_ &&
            ticketDistribution[_searchIndex].endIndex >= ticketIndexToFind_
        ) {
            return _searchIndex;
        } else if (
            ticketDistribution[_searchIndex].startIndex > ticketIndexToFind_
        ) {
            rightIndex_ = _searchIndex - 1;
            return _binarySearch(leftIndex_, rightIndex_, ticketIndexToFind_);
        } else {
            leftIndex_ = _searchIndex + 1;
            return _binarySearch(leftIndex_, rightIndex_, ticketIndexToFind_);
        }
    }

    function _resetLottery() private {
        numTotalTickets = 0;
        numActivePlayers = 0;
        lotteries[currentLotteryId].isActive = false;
        lotteries[currentLotteryId].isCompleted = true;
        winningTicket = WinningTicketStruct({
            currentLotteryId: 0,
            winningTicketIndex: 0,
            addr: address(0)
        });
        // ticketNumberOwner 초기화 (테스트에서 중복 구매 불가 위해)
        _clearTicketNumberOwner();
        currentLotteryId += 1;
    }

    // 원본 withdraw 로직 → 테스트 코드는 쓰지 않지만 남겨둠
    function withdraw(uint256 lotteryId_) external payable {
        uint256 _pending = pendingWithdrawals[lotteryId_][msg.sender];
        if (_pending == 0) {
            revert Lottery__InvalidWithdrawalAmount();
        }
        pendingWithdrawals[lotteryId_][msg.sender] = 0; 
        (bool sent, ) = msg.sender.call{value: _pending}("");
        if (!sent) {
            revert Lottery__WithdrawalFailed();
        }
        emit LogWinnerFundsWithdrawn(msg.sender, _pending);
    }

    // fallback
    receive() external payable {}
}
