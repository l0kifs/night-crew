import Testing
@testable import NightCrewCore

@Test("§7 SleepDisabled from pmset -g", arguments: [
    // Captured on macOS 27.0: 2026-10-02 (set) and 2026-10-04 (cleared). Leading space and two tabs as printed.
    ("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby              1\n sleep                1 (sleep prevented by powerd)\n", true),
    ("System-wide power settings:\n SleepDisabled\t\t0\nCurrently in use:\n standby              1\n", false),
    // The line missing or garbled reads as "not 1".
    ("Currently in use:\n standby              1\n sleep                1\n", false),
    ("System-wide power settings:\n SleepDisabled\n", false),
    ("", false),
])
func sleepDisabledLine(_ c: (String, Bool)) {
    #expect(Pmset.sleepDisabled(in: c.0) == c.1)
}
