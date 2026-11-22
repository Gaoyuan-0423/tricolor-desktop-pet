#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PetKeyStyle) { PetOrdinaryKey, PetRapidKey, PetKeyFromMouse };
typedef struct {
    NSInteger lastKey, lastMouse, bridgeAt, contactDuration;
    int symbol, quadrant, firstWrist;
    PetKeyStyle style;
    BOOL mouseRequested, bridgeToMouse;
} PetHands;

typedef struct {
    NSInteger first, last, riseAt;
    int riseFrom;
} PetPats;

typedef struct {
    int level;      // 0 open, 64 half closed, 128 closed.
    int heart;      // -1 for none.
    BOOL smiling;
} PetExpression;

FOUNDATION_EXPORT void PetHandsInit(PetHands *state);
FOUNDATION_EXPORT void PetPress(PetHands *state, int symbol, NSInteger now);
FOUNDATION_EXPORT void PetMove(PetHands *state, int quadrant, NSInteger now);
FOUNDATION_EXPORT NSString *PetHandFrame(const PetHands *state, NSInteger now, NSInteger elapsed);
FOUNDATION_EXPORT void PetPatsInit(PetPats *state);
FOUNDATION_EXPORT void PetPat(PetPats *state, NSInteger now);
FOUNDATION_EXPORT PetExpression PetFace(const PetPats *state, NSInteger now, NSInteger elapsed);
FOUNDATION_EXPORT int PetIrisGain(int faceLevel);
