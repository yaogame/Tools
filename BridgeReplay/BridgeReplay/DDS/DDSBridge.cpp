#include "DDSBridge.h"
#include "include/dll.h"

#include <cstring>

void dds_bridge_init(int maxMemoryMB)
{
    SetResources(maxMemoryMB, 1);
}

int dds_bridge_solve(int trump,
                     int first,
                     const int *trickSuit,
                     const int *trickRank,
                     const unsigned int *remainCards,
                     DDSCardScores *out)
{
    struct deal dl;
    std::memset(&dl, 0, sizeof(dl));
    dl.trump = trump;
    dl.first = first;
    for (int i = 0; i < 3; i++) {
        dl.currentTrickSuit[i] = trickSuit[i];
        dl.currentTrickRank[i] = trickRank[i];
    }
    for (int h = 0; h < DDS_HANDS; h++)
        for (int s = 0; s < DDS_SUITS; s++)
            dl.remainCards[h][s] = remainCards[h * 4 + s];

    struct futureTricks fut;
    std::memset(&fut, 0, sizeof(fut));
    // target = -1, solutions = 3：返回所有可出的牌以及各自的墩数。
    int res = SolveBoard(dl, -1, 3, 1, &fut, 0);
    if (res != RETURN_NO_FAULT)
        return res;

    out->count = fut.cards;
    for (int i = 0; i < 13; i++) {
        out->suit[i] = fut.suit[i];
        out->rank[i] = fut.rank[i];
        out->equals[i] = fut.equals[i];
        out->score[i] = fut.score[i];
    }
    return 1;
}
