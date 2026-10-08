import Foundation
@testable import IDEProtocol
import Testing

/// omp's names for what it keeps per project, checked against what omp 18.8 (Bun 1.4) computes.
@Suite struct OmpPathsTests {
    static let hashes: [(String, UInt64)] = [
        ("", 290_873_116_282_709_081),
        ("a", 2_941_419_223_392_617_777),
        ("ab", 13_590_985_366_118_106_092),
        ("abc", 190_542_993_387_777_138),
        ("abcd", 5_251_164_938_674_970_899),
        ("hello", 1_019_145_960_556_548_909),
        ("0123456789abcdef", 14_052_610_914_415_071_785),
        ("0123456789abcdef0", 18_191_082_444_834_498_672),
        ("/Users/magicelk235/Desktop/Projects/lantern", 16_847_947_460_173_913_552),
        (String(repeating: "x", count: 47), 5_569_172_624_185_218_984),
        (String(repeating: "y", count: 48), 9_900_064_646_439_298_042),
        (String(repeating: "z", count: 49), 8_550_725_854_191_205_414),
        (String(repeating: "w", count: 96), 7_516_251_212_096_720_373),
        (String(repeating: "v", count: 97), 4_339_358_008_578_469_976),
        ("/tmp/π-ünïcode/プロジェクト", 18_043_235_194_286_286_898),
    ]

    @Test(arguments: hashes)
    func bunHashIsWyhashOfTheUTF8(input: String, expected: UInt64) {
        #expect(OmpPaths.bunHash(input) == expected)
    }

    @Test(arguments: [
        ("/Users/u/Desktop/Projects/Lantern", "-Desktop-Projects-Lantern"),
        ("/Users/u", "-"),
        ("/Users/u/.omp/agent", "-.omp-agent"),
        ("/private/var/folders/x/T/tmp.VTr3", "-tmp-tmp.VTr3"),
        ("/private/var/folders/x/T", "-tmp"),
        ("/private/tmp/oi-work", "--private-tmp-oi-work--"),
        ("/", "----"),
        ("/Users/username", "--Users-username--"),
        ("/Volumes/Disk/a:b", "--Volumes-Disk-a-b--"),
        // Node's path.relative starts with ".." here, so omp takes it for outside the home folder.
        ("/Users/u/..cache", "--Users-u-..cache--"),
    ])
    func sessionFoldersFollowOmpsEncoding(cwd: String, name: String) {
        #expect(OmpPaths.sessionDirectoryName(canonicalCwd: cwd, home: "/Users/u", temporaryDirectory: "/private/var/folders/x/T") == name)
    }

    @Test func aTemporaryFolderInsideTheHomeFolderCountsAsTemporary() {
        #expect(OmpPaths.sessionDirectoryName(canonicalCwd: "/Users/u/tmp/x", home: "/Users/u", temporaryDirectory: "/Users/u/tmp") == "-tmp-x")
    }

    @Test(arguments: [
        ("/Users/magicelk235/Desktop/Projects/lantern", "lantern-3k03mxhhey7rk", "team-lantern-3k03mxhhey7rk"),
        ("/tmp/cf-a", "cf-a-1llsy88u9lgsa", "team-cf-a-1llsy88u9lgsa"),
        (
            "/tmp/close-proj qa second project with a really long name", "close-proj-qa-second-project-with-a-really-long-na-2wf7hklkppy3b",
            "team-close-proj-qa-second-project-with-a-really-lo-34hje8exvoj80"
        ),
        ("/Users/magicelk235/Desktop/Projects/magicelk235.github.io", "magicelk235-github-io-268lq0kihf4eh", "team-magicelk235-github-io-268lq0kihf4eh"),
        ("/", "default-c8rgibd8h0ws", "team-default-c8rgibd8h0ws"),
        ("/tmp/---", "default-2w93h02mg4yh4", "team-default-2w93h02mg4yh4"),
        ("/tmp/π proj", "proj-2xi4c90h6bhkl", "team-proj-2xi4c90h6bhkl"),
        (
            "/Users/u/" + String(repeating: "a", count: 70), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-3a490riziqjlv",
            "team-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-1qk60ddtejijd"
        ),
        ("/Users/u/Ünïcödé Prøject", "n-c-d-Pr-ject-3ghcmgz2t3ojz", "team-n-c-d-Pr-ject-3ghcmgz2t3ojz"),
    ])
    func memoryBanksFollowMnemopisNames(cwd: String, bank: String, withBase: String) {
        #expect(OmpPaths.memoryBank(cwd: cwd, base: nil) == bank)
        #expect(OmpPaths.memoryBank(cwd: cwd, base: "team") == withBase)
        #expect(OmpPaths.memoryBank(cwd: cwd, base: "  ") == bank, "a blank base is no base")
    }

    @Test func aLongBaseIsCutToSixtyFourCharacters() {
        let base = String(repeating: "x", count: 60)
        #expect(OmpPaths.memoryBank(cwd: "/Users/magicelk235/Desktop/Projects/lantern", base: base) == String(repeating: "x", count: 50) + "-1g587mtpxozxq")
        #expect(OmpPaths.memoryBank(cwd: "/tmp/cf-a", base: base) == String(repeating: "x", count: 50) + "-1yorf7f1s6nm7")
    }

    @Test func customSessionRecordsAreNamedByTheFilesHash() {
        #expect(OmpPaths.customSessionRecordName(sessionFile: "/Users/u/.omp/agent/sessions/-x/2026_a.jsonl") == "913ead7")
        #expect(OmpPaths.customSessionRecordName(sessionFile: "/tmp/oa/sessions/a.jsonl") == "392b100")
    }

    @Test func ompNamesATemporaryFolderWithoutPrivate() throws {
        let folder = "/private/tmp/omp-paths-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(OmpPaths.ompCwd(folder) == String(folder.dropFirst("/private".count)))
        #expect(OmpPaths.ompCwd("/Users/u/src") == "/Users/u/src")
        #expect(OmpPaths.ompCwd("/private/nonexistent-\(UUID().uuidString)").hasPrefix("/private/"), "kept when /x is another folder")
    }
}
