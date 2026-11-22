#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PetKeyStyle) { PetOrdinaryKey, PetRapidKey, PetKeyFromMouse };
typedef struct {
    NSInteger lastKey, lastMouse, bridgeAt, contactDuration;
    int symbol, quadrant, firstWrist;
    PetKeyStyle style;
    BOOL mouseRequested, bridgeToMouse, returning;
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

FOUNDATION_EXPORT int PetMouseLevel(const PetHands *state, NSInteger now);
FOUNDATION_EXPORT void PetHandsInit(PetHands *state);
FOUNDATION_EXPORT void PetPress(PetHands *state, int symbol, NSInteger now);
FOUNDATION_EXPORT void PetMove(PetHands *state, int quadrant, NSInteger now);
FOUNDATION_EXPORT NSString *PetHandFrame(const PetHands *state, NSInteger now, NSInteger elapsed);
FOUNDATION_EXPORT void PetPatsInit(PetPats *state);
FOUNDATION_EXPORT void PetPat(PetPats *state, NSInteger now);
FOUNDATION_EXPORT PetExpression PetFace(const PetPats *state, NSInteger now, NSInteger elapsed);
FOUNDATION_EXPORT int PetIrisGain(int faceLevel);

typedef NS_ENUM(NSInteger, PetHobby) { PetReading, PetRice, PetCloud };
typedef struct {
    NSInteger lastActivity, wakeAt, holdAt, releaseAt;
    NSInteger sleepAfter; // Idle milliseconds before drowsiness; deep sleep starts 3 s later.
    double wakeDrop, wakeGazeLoss, releaseWeight;
    int wakeLids, wakeRestStage;
    BOOL wakingFromSleep;
    PetHobby hobby;
    uint32_t randomState;
    NSInteger nextExpression, expressionAt, expressionEnds, mealActivity;
    int previousExpression, mealReady, mealChew;
} PetInteraction;

typedef struct {
    double gazeGain, headX, headY;
    double nuzzleWeight;
    int lids, heart, zPhase, restRecovery, hobbyPose;
    double flight; // 0..1 during a cloud throw.
    int armFrom, armTo, armBlend; // Cloud hand-off between aligned, transparent arms, Q8.
    BOOL drowsy, sleeping;
} PetMood;

FOUNDATION_EXPORT void PetInteractionInit(PetInteraction *state, NSInteger now);
FOUNDATION_EXPORT void PetNoteActivity(PetInteraction *state, NSInteger now);
FOUNDATION_EXPORT void PetStartHold(PetInteraction *state, NSInteger now);
FOUNDATION_EXPORT void PetEndHold(PetInteraction *state, NSInteger now);
FOUNDATION_EXPORT PetMood PetMoodAt(const PetInteraction *state, NSInteger now, double headU, double headV);
FOUNDATION_EXPORT BOOL PetOffHandKey(int symbol);

typedef struct {
    int number, blend; // 0 disables the local face, blend ranges from 0 to 64.
} PetPaintedFace;
FOUNDATION_EXPORT PetPaintedFace PetPickFace(PetInteraction *state, PetMood mood, NSInteger now, BOOL idleHands);
