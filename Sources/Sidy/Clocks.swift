import AppKit
import Observation
import UserNotifications

/// A countdown timer and a daily alarm. Both ring with a looping sound and a notification until stopped.
@Observable
final class Clocks {
    enum Ringing { case timer, alarm }

    // Timer: `duration` is the length it starts from. While running `timerEnd` is set; while paused `pausedLeft` is.
    var duration: TimeInterval { didSet { defaults.set(duration, forKey: "timer.duration") } }
    private(set) var timerEnd: Date? { didSet { defaults.set(timerEnd, forKey: "timer.end") } }
    private(set) var pausedLeft: TimeInterval? { didSet { defaults.set(pausedLeft, forKey: "timer.paused") } }

    // Alarm: rings every day at hour:minute while on.
    var alarmHour: Int { didSet { defaults.set(alarmHour, forKey: "alarm.hour"); schedule() } }
    var alarmMinute: Int { didSet { defaults.set(alarmMinute, forKey: "alarm.minute"); schedule() } }
    var alarmOn: Bool { didSet { defaults.set(alarmOn, forKey: "alarm.on"); schedule() } }
    private(set) var alarmNext: Date?

    private(set) var ringing: Ringing?
    /// Advances every second so countdowns redraw.
    private(set) var now = Date()

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var sound: NSSound?
    @ObservationIgnored private var silence: DispatchWorkItem?

    static let presets: [TimeInterval] = [60, 5 * 60, 15 * 60, 25 * 60]

    init() {
        duration = defaults.object(forKey: "timer.duration") as? TimeInterval ?? 5 * 60
        timerEnd = defaults.object(forKey: "timer.end") as? Date
        pausedLeft = defaults.object(forKey: "timer.paused") as? TimeInterval
        alarmHour = defaults.object(forKey: "alarm.hour") as? Int ?? 7
        alarmMinute = defaults.object(forKey: "alarm.minute") as? Int ?? 30
        alarmOn = defaults.bool(forKey: "alarm.on")
        schedule()
    }

    func start() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    // MARK: Timer

    var timerRunning: Bool { timerEnd != nil }
    var timerActive: Bool { timerEnd != nil || pausedLeft != nil }

    var timeLeft: TimeInterval {
        if let timerEnd { return max(0, timerEnd.timeIntervalSince(now)) }
        return pausedLeft ?? duration
    }

    func startTimer() {
        askPermission()
        timerEnd = now.addingTimeInterval(pausedLeft ?? duration)
        pausedLeft = nil
    }

    func pauseTimer() {
        pausedLeft = timeLeft
        timerEnd = nil
    }

    func resetTimer() {
        timerEnd = nil
        pausedLeft = nil
        if ringing == .timer { stop() }
    }

    func addTime(_ seconds: TimeInterval) {
        if let end = timerEnd { timerEnd = end.addingTimeInterval(seconds) }
        else if let left = pausedLeft { pausedLeft = left + seconds }
        else { duration = min(duration + seconds, 24 * 3600) }
    }

    // MARK: Alarm

    var alarmTime: String { String(format: "%02d:%02d", alarmHour, alarmMinute) }

    func stepAlarm(hours: Int = 0, minutes: Int = 0) {
        let total = ((alarmHour * 60 + alarmMinute + hours * 60 + minutes) % 1440 + 1440) % 1440
        alarmHour = total / 60
        alarmMinute = total % 60
        if !alarmOn { alarmOn = true }
        askPermission()
    }

    func snooze() {
        stop()
        alarmNext = now.addingTimeInterval(5 * 60)
    }

    private func schedule() {
        alarmNext = alarmOn
            ? Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: alarmHour, minute: alarmMinute, second: 0), matchingPolicy: .nextTime)
            : nil
    }

    // MARK: Ringing

    func isRinging(_ module: Module) -> Bool {
        switch (ringing, module) {
        case (.timer, .timer), (.alarm, .alarm): true
        default: false
        }
    }

    func stop() {
        ringing = nil
        sound?.stop()
        sound = nil
        silence?.cancel()
    }

    private func tick() {
        now = Date()
        if let timerEnd, now >= timerEnd {
            self.timerEnd = nil
            ring(.timer, "Timer done", Format.clock(duration) + " is up")
        }
        if let alarmNext, now >= alarmNext {
            // After a long sleep a stale alarm is skipped rather than going off hours late.
            let late = now.timeIntervalSince(alarmNext) > 10 * 60
            schedule()
            if !late { ring(.alarm, "Alarm", alarmTime) }
        }
    }

    private func ring(_ kind: Ringing, _ title: String, _ body: String) {
        stop()
        ringing = kind
        sound = NSSound(named: "Glass")
        sound?.loops = true
        sound?.play()
        // Nobody around: go quiet after a minute, but keep the tile lit until it's stopped.
        let work = DispatchWorkItem { [weak self] in self?.sound?.stop() }
        silence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sidy.\(kind)", content: content, trigger: nil))
    }

    private func askPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
}
