import Foundation
import XCTest
@testable import VigilRuntime

// SessionLock is the plain advisory lock a host app writes into a session dir (live.lock:
// pid + heartbeat) so a SECOND instance won't resume a session the first still drives. These
// cover the on-disk round-trip and every isLive verdict (fresh/stale × pid alive/dead ×
// missing), plus the pid-liveness primitive — all deterministic (clock + pidAlive injected).

final class SessionLockTests: XCTestCase {

    private var tmpDirs: [String] = []

    override func tearDown() {
        for d in tmpDirs { try? FileManager.default.removeItem(atPath: d) }
        tmpDirs.removeAll()
        super.tearDown()
    }

    private func makeDir() throws -> String {
        let d = NSTemporaryDirectory() + "vigil_lock_test_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        tmpDirs.append(d)
        return d
    }

    // MARK: on-disk round-trip

    func testWriteReadRoundTrip() throws {
        let dir = try makeDir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(SessionLock.write(dir: dir, pid: 4242, now: now))
        let lock = try XCTUnwrap(SessionLock.read(dir: dir))
        XCTAssertEqual(lock.pid, 4242)
        XCTAssertEqual(lock.heartbeat.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        // The file lives exactly where a resume check will look for it.
        XCTAssertTrue(FileManager.default.fileExists(atPath: SessionLock.path(dir: dir)))
    }

    func testWriteOverwritesHeartbeat() throws {
        let dir = try makeDir()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        SessionLock.write(dir: dir, pid: 1, now: t0)
        SessionLock.write(dir: dir, pid: 1, now: t0.addingTimeInterval(120))   // heartbeat refresh
        let lock = try XCTUnwrap(SessionLock.read(dir: dir))
        XCTAssertEqual(lock.heartbeat.timeIntervalSince1970,
                       t0.addingTimeInterval(120).timeIntervalSince1970, accuracy: 1)
    }

    func testReadMissingIsNil() throws {
        let dir = try makeDir()
        XCTAssertNil(SessionLock.read(dir: dir))
    }

    func testRemoveDeletesLock() throws {
        let dir = try makeDir()
        SessionLock.write(dir: dir, pid: 1, now: Date())
        SessionLock.remove(dir: dir)
        XCTAssertNil(SessionLock.read(dir: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SessionLock.path(dir: dir)))
    }

    // MARK: isLive — the resume gate's truth table

    func testLiveWhenFreshAndPidAlive() throws {
        let dir = try makeDir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        SessionLock.write(dir: dir, pid: 99, now: now)
        XCTAssertTrue(SessionLock.isLive(dir: dir, now: now.addingTimeInterval(60),
                                         pidAlive: { _ in true }),
                      "pid alive + heartbeat 60s old (< 5min) = held")
    }

    func testStaleHeartbeatSelfHealsEvenIfPidAlive() throws {
        let dir = try makeDir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        SessionLock.write(dir: dir, pid: 99, now: now)
        // Heartbeat older than staleness = holder hung/crashed. Freshness gates FIRST, so a
        // recycled pid that happens to be alive still reads dead (pid-reuse safety).
        XCTAssertFalse(SessionLock.isLive(dir: dir, now: now.addingTimeInterval(301),
                                          pidAlive: { _ in true }),
                       "stale heartbeat → the leftover lock self-heals, even if the pid happens to be alive")
    }

    func testDeadPidIsNotLiveEvenIfFresh() throws {
        let dir = try makeDir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        SessionLock.write(dir: dir, pid: 99, now: now)
        XCTAssertFalse(SessionLock.isLive(dir: dir, now: now.addingTimeInterval(10),
                                          pidAlive: { _ in false }),
                       "process is dead → resume is allowed (no matter how fresh the heartbeat)")
    }

    func testMissingLockIsNotLive() throws {
        let dir = try makeDir()
        XCTAssertFalse(SessionLock.isLive(dir: dir, pidAlive: { _ in true }),
                       "no lock file = not held")
    }

    func testStalenessBoundaryIsExclusive() throws {
        let dir = try makeDir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        SessionLock.write(dir: dir, pid: 1, now: now)
        // exactly at the threshold = NOT fresh (>= staleness → dead).
        XCTAssertFalse(SessionLock.isLive(dir: dir,
                                          now: now.addingTimeInterval(SessionLock.defaultStaleness),
                                          pidAlive: { _ in true }))
        XCTAssertTrue(SessionLock.isLive(dir: dir,
                                         now: now.addingTimeInterval(SessionLock.defaultStaleness - 1),
                                         pidAlive: { _ in true }))
    }

    // MARK: pidAlive primitive (real OS)

    func testPidAliveForSelf() {
        XCTAssertTrue(SessionLock.pidAlive(getpid()), "the current process is certainly alive")
    }

    func testPidAliveForNonPositiveIsFalse() {
        // 0/-1 broadcast to process groups in kill(2) — never a real single holder.
        XCTAssertFalse(SessionLock.pidAlive(0))
        XCTAssertFalse(SessionLock.pidAlive(-1))
    }

    func testPidAliveForVeryLikelyDeadPid() {
        // A pid near the max is exceedingly unlikely to be a running process.
        XCTAssertFalse(SessionLock.pidAlive(999_999), "an almost-certainly-nonexistent pid = dead")
    }
}
