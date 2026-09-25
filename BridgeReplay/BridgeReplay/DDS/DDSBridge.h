// 给 Swift 用的精简 C 接口，内部调用 DDS 的 SolveBoard。
#ifndef DDSBridge_h
#define DDSBridge_h

#ifdef __cplusplus
extern "C" {
#endif

/// 某个局面下，轮到出牌的那家每张可出的牌能拿到的墩数（双明手）。
typedef struct {
    int count;
    int suit[13];    // 0=♠ 1=♥ 2=♦ 3=♣
    int rank[13];    // 2...14（A=14）
    int equals[13];  // 与该牌等价的更小的牌（位掩码，bit r 表示点数 r）
    int score[13];   // 出牌方（轮到的那家所在一方）从当前这墩起还能拿的墩数
} DDSCardScores;

/// 设置 DDS 最多占用的内存（MB）。可重复调用。
void dds_bridge_init(int maxMemoryMB);

/// 求解一个局面。
/// - trump: 0=♠ 1=♥ 2=♦ 3=♣ 4=无将
/// - first: 当前这墩的首家 0=北 1=东 2=南 3=西
/// - trickSuit / trickRank: 当前这墩已经出的牌（最多 3 张，rank 2...14，没有则为 0）
/// - remainCards: 16 个元素，下标 seat*4+suit，bit r 表示还在手里的点数 r（2...14）
/// 成功返回 1，否则返回 DDS 的错误码（负数）。
int dds_bridge_solve(int trump,
                     int first,
                     const int *trickSuit,
                     const int *trickRank,
                     const unsigned int *remainCards,
                     DDSCardScores *out);

#ifdef __cplusplus
}
#endif

#endif /* DDSBridge_h */
