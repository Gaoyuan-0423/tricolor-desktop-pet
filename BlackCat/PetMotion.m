#import "PetMotion.h"

void PetHandsInit(PetHands *s) {
    *s = (PetHands){.lastKey=-10000,.lastMouse=-10000,.contactDuration=45};
}

static NSInteger keyDuration(PetKeyStyle style) {
    return style == PetRapidKey ? 150 : style == PetKeyFromMouse ? 205 : 220;
}

int PetMouseLevel(const PetHands *s, NSInteger now) {
    NSInteger motion=now-s->bridgeAt, age=now-s->lastMouse;
    if (!s->mouseRequested || motion<0 || age>=850 || (s->bridgeToMouse && motion<40)) return 0;
    int entry=s->bridgeToMouse ? 3 : motion<40 ? 1 : motion<95 ? 2 : 3;
    int release=age>770 ? 1 : age>690 ? 2 : 3;
    return MIN(entry,release);
}

NSString *PetHandFrame(const PetHands *s, NSInteger now, NSInteger elapsed) {
    NSInteger keyAge=now-s->lastKey;
    BOOL freeHandTyping=PetOffHandKey(s->symbol) && keyAge<keyDuration(s->style);
    if (!freeHandTyping && s->mouseRequested && now>=s->bridgeAt && now-s->lastMouse<850) {
        NSInteger motion=now-s->bridgeAt;
        if (s->bridgeToMouse && motion<40)
            return [NSString stringWithFormat:@"wrist%ld",(long)(3-motion/10)];
        return [NSString stringWithFormat:@"mouse%d%d",PetMouseLevel(s,now),s->quadrant];
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
    int grip=PetMouseLevel(s,now);
    BOOL onMouse=grip>0, offHand=PetOffHandKey(symbol);
    BOOL leavingKeyboard = s->bridgeToMouse && s->mouseRequested && now >= s->bridgeAt && [shown hasPrefix:@"wrist"];
    s->contactDuration = 45;
    if (interval <= 150 && (offHand || !PetOffHandKey(s->symbol) || (!onMouse && !leavingKeyboard))) {
        s->style = PetRapidKey;
        if (symbol == s->symbol && interval < 45)
            s->contactDuration = MAX(12,interval/2);
    } else if (!offHand && (onMouse || leavingKeyboard)) {
        s->style = PetKeyFromMouse;
        if (onMouse) {
            int level=grip;
            s->firstWrist = level == 3 ? 0 : level == 2 ? 1 : 3;
        } else {
            s->firstWrist = [shown characterAtIndex:5]-'0';
        }
    } else {
        s->style = PetOrdinaryKey;
    }
    if (!offHand) {
        BOOL returnToMouse = s->mouseRequested && now-s->lastMouse<850;
        s->returning=returnToMouse;
        s->mouseRequested=returnToMouse;
        s->bridgeToMouse=returnToMouse;
        s->bridgeAt=now+keyDuration(s->style);
    }
    s->lastKey = now;
    s->symbol = symbol;
}

void PetMove(PetHands *s, int quadrant, NSInteger now) {
    if (s->returning && now>=s->bridgeAt) s->returning=NO;
    if (s->returning || !s->mouseRequested || now-s->lastMouse >= 850) {
        s->returning=NO;
        NSInteger keyAge = now-s->lastKey;
        s->bridgeToMouse = !PetOffHandKey(s->symbol) && keyAge < keyDuration(s->style);
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

static double unitInterval(double n) { return fmax(0,fmin(1,n)); }

BOOL PetOffHandKey(int symbol) {
    return symbol==32 || (symbol>0 && symbol<128 && strchr("12345QWERTASDFGZXCVB",symbol));
}

void PetInteractionInit(PetInteraction *s, NSInteger now) {
    *s=(PetInteraction){.lastActivity=now,.sleepAfter=57000,.wakeAt=-10000,.holdAt=-1,.releaseAt=-10000,
        .randomState=arc4random_uniform(UINT32_MAX-1)+1,.nextExpression=-1,.expressionEnds=-1,.mealActivity=-1};
}

static double holdWeight(const PetInteraction *s, NSInteger now) {
    if (s->holdAt<0) return 0;
    if (s->releaseAt<s->holdAt) return unitInterval((now-s->holdAt)/180.0);
    return s->releaseWeight*(1-unitInterval((now-s->releaseAt)/220.0));
}

// Blue's painted chopsticks, rice and lips stay aligned in each whole pose.
static int ricePose(NSInteger idle) {
    static const NSInteger until[]={47400,48550,49400,50500,51200,52250,53100,54500,55200,55950,56550};
    static const int poses[]={1,2,3,4,3,2,3,4,3,2,1};
    if (idle<45000) return 0;
    for (size_t i=0;i<sizeof(poses)/sizeof(*poses);i++) if (idle<until[i]) return poses[i];
    return 0;
}

static int bookPose(NSInteger idle) {
    if (idle<45000 || idle>=56550) return 0;
    if (idle<46300) return 1;
    if (idle<48700 || (idle>=49500 && idle<52300) || (idle>=53100 && idle<55600)) return 2;
    return idle<55600 ? 3 : 4;
}

static int cloudPose(NSInteger idle, PetMood *m) {
    if (idle<45000 || idle>=56550) return 0;
    if (idle<46200 || idle>=55200) return 1;
    NSInteger t=(idle-46200)%3000;
    m->flight=unitInterval((t-380)/1290.0);
    if (t<380 || (t>=1670 && t<1940)) {
        m->armFrom=t<380 ? 1 : 4;
        m->armTo=t<380 ? 2 : 1;
        double ratio=t<380 ? t/380.0 : (t-1670)/270.0;
        m->armBlend=(int)lround(256*ratio*ratio*(3-2*ratio));
    }
    return t<380 ? 1 : t<620 ? 2 : t<1550 ? 3 : t<1940 ? 4 : 1;
}

PetMood PetMoodAt(const PetInteraction *s, NSInteger now, double headU, double headV) {
    PetMood m={.gazeGain=1,.heart=-1,.zPhase=-1};
    BOOL held=s->holdAt>=0 && s->releaseAt<s->holdAt;
    NSInteger idle=held ? 0 : now-s->lastActivity;
    // Hobby choreography ends just before drowsiness, regardless of the chosen delay.
    NSInteger hobbyTime=idle-s->sleepAfter+57000;
    if (!held) switch (s->hobby) {
        case PetRice: m.hobbyPose=ricePose(hobbyTime); break;
        case PetReading: m.hobbyPose=bookPose(hobbyTime); break;
        case PetCloud: m.hobbyPose=cloudPose(hobbyTime,&m); break;
    }
    double drowsy=unitInterval((idle-s->sleepAfter)/3000.0);
    double sleep=unitInterval((idle-s->sleepAfter-3000)/600.0);
    m.drowsy=idle>=s->sleepAfter;
    m.sleeping=idle>=s->sleepAfter+3000;
    m.lids=(int)lround(64*(drowsy+sleep));
    m.gazeGain=m.hobbyPose ? 0 : 1-drowsy;
    m.headY=.65*drowsy+.07*sleep*sin(2*M_PI*(idle-s->sleepAfter-3000)/3200.0);
    if (m.sleeping) m.zPhase=(int)((idle-s->sleepAfter-3000)%2000)/80;

    NSInteger wake=now-s->wakeAt;
    if (wake>=0 && wake<480) {
        double recover=1-unitInterval(wake/180.0);
        m.restRecovery=s->hobby==PetRice ? 0 : (int)lround(s->wakeRestStage*64*(1-unitInterval(wake/300.0)));
        m.headY+=s->wakeDrop*recover;
        m.gazeGain-=s->wakeGazeLoss*recover;
        m.lids=MAX(m.lids,(int)lround(s->wakeLids*recover));
        if (s->wakingFromSleep) {
            double t=wake/480.0;
            m.headX+=.55*sin(4*M_PI*t)*(1-t);
        }
    }
    double w=holdWeight(s,now);
    if (w>0) {
        double t=2*M_PI*(now-s->holdAt)/900.0;
        headU=fmax(-1,fmin(1,headU)); headV=fmax(-1,fmin(1,headV));
        m.gazeGain*=1-w;
        m.headX+=w*(.65*headU+.12*sin(t));
        m.headY+=w*(.45*headV+.08*(cos(t)-1));
        m.nuzzleWeight=w;
        NSInteger age=now-s->holdAt;
        m.heart=held ? (age<100 ? 0 : age<220 ? 1 : 2+(int)((age-220)/180%2)) :
                       (now-s->releaseAt<110 ? 4 : 5);
    }
    return m;
}

void PetNoteActivity(PetInteraction *s, NSInteger now) {
    if (now-s->lastActivity>=s->sleepAfter && !(s->holdAt>=0 && s->releaseAt<s->holdAt)) {
        PetMood m=PetMoodAt(s,now,0,0);
        s->wakeRestStage=s->hobby==PetRice ? 0 : MIN(4,1+(int)((now-s->lastActivity-s->sleepAfter)/750));
        s->wakeAt=now;
        s->wakeLids=m.lids;
        s->wakeDrop=m.headY;
        s->wakeGazeLoss=1-m.gazeGain;
        s->wakingFromSleep=m.sleeping;
    }
    s->lastActivity=now;
    s->nextExpression=-1; s->expressionEnds=-1; s->mealActivity=-1;
}

void PetStartHold(PetInteraction *s, NSInteger now) {
    s->holdAt=now;
    s->releaseAt=-10000;
}

void PetEndHold(PetInteraction *s, NSInteger now) {
    if (s->holdAt>=0 && s->releaseAt<s->holdAt) {
        s->releaseWeight=holdWeight(s,now);
        s->releaseAt=now;
    }
}

// Each pet keeps its own generator. Animation ticks reuse a selected expression
// until the pose or mouthful ends, so repaint frequency cannot cause flicker.
static uint32_t nextRandom(PetInteraction *s) {
    uint32_t v=s->randomState;
    v^=v<<13; v^=v>>17; v^=v<<5;
    return s->randomState=v;
}

PetPaintedFace PetPickFace(PetInteraction *s, PetMood mood, NSInteger now, BOOL idleHands) {
    PetPaintedFace none={0};
    NSInteger quiet=now-s->lastActivity;
    NSInteger hobbyTime=quiet-s->sleepAfter+57000;
    if (mood.hobbyPose) {
        if (s->hobby==PetReading) {
            int expression=mood.hobbyPose==3 ? 3 : mood.hobbyPose==4 || (mood.hobbyPose==2 && hobbyTime>=51000) ? 2 : 1;
            return (PetPaintedFace){expression,64};
        }
        if (s->hobby==PetCloud)
            return (PetPaintedFace){mood.hobbyPose==1 ? 1 : mood.hobbyPose==4 ? 3 : 2,64};
        if (s->mealActivity!=s->lastActivity) {
            s->mealActivity=s->lastActivity;
            s->mealReady=(nextRandom(s)&1) ? 1 : 5;
            s->mealChew=(nextRandom(s)&1) ? 4 : 6;
        }
        if (mood.hobbyPose==3) return none;
        BOOL second=hobbyTime>=50500;
        int number=mood.hobbyPose==4 ? (second ? 10-s->mealChew : s->mealChew) :
                                  (second ? 6-s->mealReady : s->mealReady);
        return (PetPaintedFace){number,64};
    }
    if (!idleHands || quiet<1000 || hobbyTime>=45000 || mood.drowsy || mood.nuzzleWeight>0) return none;
    if (s->nextExpression<0) s->nextExpression=s->lastActivity+4000+nextRandom(s)%4001;
    if (now>=s->nextExpression) {
        int options=s->hobby==PetRice ? 5 : 3;
        int choice=1+nextRandom(s)%(options-(s->previousExpression ? 1 : 0));
        if (s->previousExpression && choice>=s->previousExpression) choice++;
        s->previousExpression=choice;
        s->expressionAt=now;
        s->expressionEnds=now+1200+nextRandom(s)%801;
        s->nextExpression=s->expressionEnds+4000+nextRandom(s)%4001;
    }
    if (now>=s->expressionEnds) return none;
    double amount=unitInterval(fmin((now-s->expressionAt)/150.0,(s->expressionEnds-now)/150.0));
    return (PetPaintedFace){s->previousExpression,(int)lround(amount*64)};
}
