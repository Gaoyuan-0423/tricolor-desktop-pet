package main

import "strconv"

// The menu values indicate when the pet is asleep, after a three-second
// drowsiness transition. The default reproduces the original 60-second timing.
var sleepWaitOptions = [...]int{15, 30, 60, 120, 300, 600}
var sleepAfterSeconds = 60

func validSleepWait(seconds int) bool {
	for _, option := range sleepWaitOptions {
		if option == seconds {
			return true
		}
	}
	return false
}

func parseSleepWait(value string) int {
	seconds, err := strconv.Atoi(value)
	if err != nil || !validSleepWait(seconds) {
		return 60
	}
	return seconds
}

func sleepAfterMilliseconds() int64 { return int64(sleepAfterSeconds) * 1000 }
func drowsyMilliseconds() int64     { return sleepAfterMilliseconds() - 3000 }

// Map a configured quiet interval onto the original choreography's 60-second
// clock, so the same sequence finishes before drowsiness for every option.
func relativeHobbyMilliseconds(idleMS, sleepMS int64) int64 {
	return idleMS - sleepMS + 60000
}

func hobbyMilliseconds(idleMS int64) int64 {
	return relativeHobbyMilliseconds(idleMS, sleepAfterMilliseconds())
}

func hobbyStartMilliseconds() int64 { return sleepAfterMilliseconds() - 15000 }

func ricePose(idleMS int64) string {
	if idleMS < 45000 || idleMS >= 56550 {
		return ""
	}
	for _, beat := range [...]struct {
		until int64
		pose  string
	}{
		{47400, "rice1"}, {48550, "rice2"}, {49400, "rice3"}, {50500, "rice4"},
		{51200, "rice3"}, {52250, "rice2"}, {53100, "rice3"}, {54500, "rice4"},
		{55200, "rice3"}, {55950, "rice2"}, {56550, "rice1"},
	} {
		if idleMS < beat.until {
			return beat.pose
		}
	}
	return ""
}

func bookPose(idle int64) string {
	switch {
	case idle < 46300:
		return "book1"
	case idle < 48700:
		return "book2"
	case idle < 49500:
		return "book3"
	case idle < 52300:
		return "book2"
	case idle < 53100:
		return "book3"
	case idle < 55600:
		return "book2"
	default:
		return "book4"
	}
}
