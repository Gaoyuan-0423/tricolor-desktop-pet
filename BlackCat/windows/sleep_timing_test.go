package main

import (
	"strconv"
	"testing"
)

func TestSleepWaitSettings(t *testing.T) {
	for _, seconds := range []int{15, 30, 60, 120, 300, 600} {
		if got := parseSleepWait(strconv.Itoa(seconds)); got != seconds {
			t.Errorf("parse %d: got %d", seconds, got)
		}
	}
	for _, value := range []string{"", "-1", "0", "14", "61", "601", "abc", "15.0"} {
		if got := parseSleepWait(value); got != 60 {
			t.Errorf("invalid %q: got %d, want default 60", value, got)
		}
	}
}

func TestSleepAndHobbyBoundaries(t *testing.T) {
	old := sleepAfterSeconds
	t.Cleanup(func() { sleepAfterSeconds = old })
	for _, seconds := range []int{15, 30, 60, 120, 300, 600} {
		sleepAfterSeconds = seconds
		sleep := int64(seconds) * 1000
		if got := sleepAfterMilliseconds(); got != sleep {
			t.Fatalf("%ds: sleep = %d", seconds, got)
		}
		if got := drowsyMilliseconds(); got != sleep-3000 {
			t.Errorf("%ds: drowsiness starts at %d", seconds, got)
		}
		start, end := sleep-15000, sleep-3450
		if hobbyStartMilliseconds() != start || hobbyMilliseconds(start) != 45000 || hobbyMilliseconds(end) != 56550 {
			t.Errorf("%ds: hobby interval not mapped to original choreography", seconds)
		}
		for _, ms := range []int64{end, sleep - 3000, sleep, sleep + 30000} {
			if mapped := hobbyMilliseconds(ms); mapped < 56550 {
				t.Errorf("%ds: hobby could continue after its end at %d (mapped %d)", seconds, ms, mapped)
			}
		}
	}
}

func TestRiceAndBookTimingAcrossSleepChoices(t *testing.T) {
	old := sleepAfterSeconds
	t.Cleanup(func() { sleepAfterSeconds = old })
	for _, seconds := range sleepWaitOptions {
		sleepAfterSeconds = seconds
		sleepMS := int64(seconds) * 1000
		for _, beat := range []struct {
			original int64
			rice     string
			book     string
		}{
			{45000, "rice1", "book1"},
			{46300, "rice1", "book2"},
			{47400, "rice2", "book2"},
			{48700, "rice3", "book3"},
			{50500, "rice3", "book2"},
			{55600, "rice2", "book4"},
			{56549, "rice1", "book4"},
		} {
			idle := sleepMS - 60000 + beat.original
			mapped := hobbyMilliseconds(idle)
			if got := ricePose(mapped); got != beat.rice {
				t.Errorf("%ds at %dms: rice=%q, want %q", seconds, idle, got, beat.rice)
			}
			if got := bookPose(mapped); got != beat.book {
				t.Errorf("%ds at %dms: book=%q, want %q", seconds, idle, got, beat.book)
			}
		}
		if got := ricePose(hobbyMilliseconds(sleepMS - 3450)); got != "" {
			t.Errorf("%ds: rice continues past the end: %q", seconds, got)
		}
	}
}
