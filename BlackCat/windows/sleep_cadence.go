package main

// Preserve full-speed closing and waking transitions. At rest, 25 Hz keeps
// breathing smooth while still sampling external mouse movement every 40 ms.
func sleepTimerPeriod(idleMS, sleepAfterMS int64, interacting bool) uint32 {
	if !interacting && idleMS >= sleepAfterMS+600 {
		return 40
	}
	return 16
}
