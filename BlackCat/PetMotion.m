#import "PetMotion.h"

void PetHandsInit(PetHands *s) {
    *s = (PetHands){.lastKey=-10000,.lastMouse=-10000,.contactDuration=45};
}

static NSInteger keyDuration(PetKeyStyle style) {
    return style == PetRapidKey ? 150 : style == PetKeyFromMouse ? 205 : 220;
}

NSString *PetHandFrame(const PetHands *s, NSInteger now, NSInteger elapsed) {
    NSInteger keyAge = now-s->lastKey, mouseAge = now-s->lastMouse;
    if (s->mouseRequested && now >= s->bridgeAt && mouseAge < 850) {
        NSInteger motion = now-s->bridgeAt;
        if (s->bridgeToMouse && motion < 40)
            return [NSString stringWithFormat:@"wrist%ld", (long)(3-motion/10)];
        int entry = s->bridgeToMouse ? 3 : motion < 40 ? 1 : motion < 95 ? 2 : 3;
        int release = mouseAge > 770 ? 1 : mouseAge > 690 ? 2 : 3;
        return [NSString stringWithFormat:@"mouse%d%d", MIN(entry,release), s->quadrant];
    }
    if (keyAge < keyDuration(s->style)) {
        int phase;
        if (s->style == PetRapidKey) {
            phase = keyAge < s->contactDuration ? 3 : keyAge < 95 ? 4 : 5;
        } else if (s->style == PetKeyFromMouse) {
            if (keyAge < 35) {
                int wrist = s->firstWrist + (int)(keyAge*(4-s->firstWrist)/35);
                return [NSString stringWithFormat:@"wrist%d", MIN(3,wrist)];
            }
            phase = keyAge < 44 ? 2 : keyAge < 105 ? 3 : keyAge < 150 ? 4 : 5;
        } else {
            phase = keyAge < 18 ? 1 : keyAge < 42 ? 2 : keyAge < 100 ? 3 : keyAge < 150 ? 4 : 5;
        }
        return [NSString stringWithFormat:@"key%d-%d",s->symbol,phase];
    }
    return [NSString stringWithFormat:@"idle%ld",(long)((elapsed/240)%7)];
}

void PetPress(PetHands *s, int symbol, NSInteger now) {
    NSInteger interval = now-s->lastKey;
    NSString *shown = PetHandFrame(s,now,now);
    BOOL onMouse = [shown hasPrefix:@"mouse"];
    BOOL leavingKeyboard = s->bridgeToMouse && s->mouseRequested && now >= s->bridgeAt && [shown hasPrefix:@"wrist"];
    s->contactDuration = 45;
    if (interval <= 150) {
        s->style = PetRapidKey;
        if (symbol == s->symbol && interval < 45)
            s->contactDuration = MAX(12,interval/2);
    } else if (onMouse || leavingKeyboard) {
        s->style = PetKeyFromMouse;
        if (onMouse) {
            int level = [shown characterAtIndex:5]-'0';
            s->firstWrist = level == 3 ? 0 : level == 2 ? 1 : 3;
        } else {
            s->firstWrist = [shown characterAtIndex:5]-'0';
        }
    } else {
        s->style = PetOrdinaryKey;
    }
    s->mouseRequested = NO;
    s->bridgeToMouse = NO;
    s->lastKey = now;
    s->symbol = symbol;
}

void PetMove(PetHands *s, int quadrant, NSInteger now) {
    if (!s->mouseRequested || now-s->lastMouse >= 850) {
        NSInteger keyAge = now-s->lastKey;
        s->bridgeToMouse = keyAge < keyDuration(s->style);
        NSInteger earliest = s->style == PetRapidKey ? 45 : s->style == PetKeyFromMouse ? 85 : 90;
        s->bridgeAt = s->bridgeToMouse ? MAX(now,s->lastKey+earliest) : now;
    }
    s->mouseRequested = YES;
    s->lastMouse = now;
    s->quadrant = quadrant;
}

void PetPatsInit(PetPats *s) { *s = (PetPats){.first=-10000,.last=-10000,.riseAt=-10000}; }

static int ramp(int start, int end, NSInteger age, NSInteger duration) {
    NSInteger t = MAX(0, MIN(duration, age));
    return (int)((start*(duration-t)+end*t+duration/2)/duration);
}

static int smileLevel(const PetPats *s, NSInteger now) {
    NSInteger release = now-s->last;
    if (release >= 900) return 0;
    if (release >= 815) return ramp(64,0,release-815,85);
    if (release >= 735) return 64;
    if (release >= 680) return ramp(128,64,release-680,55);
    if (s->riseAt > s->first) return ramp(s->riseFrom,128,now-s->riseAt,80);
    NSInteger attack = now-s->first;
    if (attack < 45) return ramp(0,64,attack,45);
    if (attack < 100) return 64;
    return ramp(64,128,attack-100,60);
}

void PetPat(PetPats *s, NSInteger now) {
    NSInteger age = now-s->last;
    if (age >= 900) {
        s->first = now;
        s->riseAt = now;
        s->riseFrom = 0;
    } else if (age >= 680) {
        s->riseFrom = smileLevel(s,now);
        s->riseAt = now;
    }
    s->last = now;
}

PetExpression PetFace(const PetPats *s, NSInteger now, NSInteger elapsed) {
    NSInteger age = now-s->last;
    if (age < 900) {
        NSInteger active = now-s->first;
        int heart = active < 100 ? 0 : active < 220 ? 1 :
                    age < 500 ? 2+(int)((active-220)/180%2) : age < 680 ? 4 : 5;
        return (PetExpression){.level=smileLevel(s,now), .heart=heart, .smiling=YES};
    }
    NSInteger t = elapsed % 4700;
    int level = 0;
    if (elapsed >= 4700 && t < 185) {
        if (t < 32) level = ramp(0,64,t,32);
        else if (t < 55) level = 64;
        else if (t < 78) level = ramp(64,128,t-55,23);
        else if (t < 110) level = 128;
        else if (t < 135) level = ramp(128,64,t-110,25);
        else if (t < 150) level = 64;
        else level = ramp(64,0,t-150,35);
    }
    return (PetExpression){.level=level,.heart=-1,.smiling=NO};
}

int PetIrisGain(int level) {
    return level <= 64 ? ramp(192,64,level,64) : ramp(64,0,level-64,64);
}
