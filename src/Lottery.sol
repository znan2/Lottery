// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../src/Random.sol";

contract Lottery{
    // 테스트 코드에서 사용 중인 상수 & 변수들
    uint256 public constant TICKET_PRICE = 0.1 ether; // 티켓 가격
    uint256 public constant SELL_PHASE_LENGTH = 24 hours; // 판매기간
    uint256 public constant DRAW_PHASE_LENGTH = 1 hours; // 추첨기간

    // 예: 테스트 코드가 읽는 상태변수
    uint16 public winningNumber; // 당첨번호
    bool public didDraw; // 추첨 여부

    uint256 public sellPhaseEnd;    // 판매기간 종료 시간
    uint256 public drawPhaseEnd;    // 추첨기간 종료 시간

    struct Ticket {
        address buyer;
        uint16 number;
        bool isClaimed; // 당첨금 수령 여부
    }


    Ticket[] public tickets;    // 티켓 목록
    uint256 public winnerCount; // 당첨자 수
    uint256 public totalPrize;  // 당첨금 총액

    constructor(){
        sellPhaseEnd = block.timestamp + SELL_PHASE_LENGTH;
        didDraw      = false;
    }

    // 간단하게만 구현한 buy, draw, claim
    function buy(uint16 _ticketNumber) external payable {
        if (didDraw) {
            _startNewRound();
        }

        require(msg.value == TICKET_PRICE, "Lottery: invalid ticket price");
        require(block.timestamp < sellPhaseEnd, "Lottery: sell phase has ended");
        require(_ticketNumber < 1000, "Lottery: invalid ticket number");

        // 이미 게임에 참여했는지 확인
        for (uint256 i = 0; i < tickets.length; i++) {
            require(tickets[i].buyer != msg.sender, "Lottery: duplicate ticket");
        }

        tickets.push(Ticket({
            buyer:   msg.sender,
            number:  _ticketNumber,
            isClaimed: false
        }));
    }

    function draw() external {
        require(!didDraw, "Lottery: already drawn");
        require(block.timestamp >= sellPhaseEnd, "Lottery: sell phase not ended yet");

        didDraw = true;
        drawPhaseEnd = block.timestamp + DRAW_PHASE_LENGTH;
        require(block.timestamp < drawPhaseEnd, "Lottery: draw phase ended");
        winningNumber = _performRandomizedDrawning();

        totalPrize = address(this).balance;

        winnerCount = 0;
        for (uint256 i = 0; i < tickets.length; i++) {
            if (tickets[i].number == winningNumber) {
                winnerCount++;
            }
        }
    }

    // 여기서 난수 생성할 때, 난수의 범위를 1~tickets.length로 설정할 수도 있지만
    // rollover를 테스트하기 위해 1~1000으로 설정, 즉 당첨자가 안 나올 수도 있게 해야 한다.
    // 참고로 완벽한 난수는 아니다.. chainlink VRF를 사용하면 되긴 하지만 여기서는 사용하지 않음(유료라..)
    function _performRandomizedDrawning() private returns (uint16) {
        require(tickets.length > 0, "Lottery: no tickets to draw from");
        uint256 randVal = Random.naiveRandInt(1, 1000);
        return uint16(randVal);
    }

    function claim() external {
        require(didDraw, "Lottery: not drawn yet");
        require(block.timestamp >= sellPhaseEnd, "Lottery: still in sell phase");
        bool isWinner;
        uint256 index;

        for (uint256 i = 0; i < tickets.length; i++) {
            if (
                tickets[i].buyer == msg.sender &&
                tickets[i].number == winningNumber &&
                !tickets[i].isClaimed
            ) {
                isWinner = true;
                index = i;
                break;
            }
        }
        if (!isWinner || winnerCount == 0) {
            return;
        }

        // 4) 당첨금 지급
        tickets[index].isClaimed = true;
        uint256 payout = totalPrize / winnerCount;

        totalPrize -= payout;
        winnerCount--;
        
        (bool success,) = payable(msg.sender).call{value: payout}("");
        require(success, "Transfer failed");
    }

    function _startNewRound() internal {
        sellPhaseEnd = block.timestamp + SELL_PHASE_LENGTH;
        drawPhaseEnd = 0;
        didDraw      = false;
        winnerCount  = 0;
        delete tickets;
    }

    // receive() 함수도 테스트 코드에서 쓰므로 정의
    receive() external payable {}
}
