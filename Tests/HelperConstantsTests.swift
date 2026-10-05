import XCTest

final class HelperConstantsTests: XCTestCase {
    func testRealServiceIDsAreWellFormed() {
        XCTAssertTrue(HelperConstants.isWellFormedServiceID("DC3DB9BB-06D0-4D5D-A1E4-7C6C499D9A7D"))
        XCTAssertTrue(HelperConstants.isWellFormedServiceID("C7E15396-4978-43DD-B518-F490D5368212"))
    }

    func testIDsThatCouldForgeALogLineAreRefused() {
        XCTAssertFalse(HelperConstants.isWellFormedServiceID(""))
        XCTAssertFalse(HelperConstants.isWellFormedServiceID("SVC\nuid 0 set X on: ok"))
        XCTAssertFalse(HelperConstants.isWellFormedServiceID("SVC\u{0}"))
        XCTAssertFalse(HelperConstants.isWellFormedServiceID("Wi-Fi Network"))
        XCTAssertFalse(HelperConstants.isWellFormedServiceID("Ｄ98EBBFE"))   // full-width letter
        XCTAssertFalse(HelperConstants.isWellFormedServiceID(String(repeating: "A", count: 65)))
        XCTAssertTrue(HelperConstants.isWellFormedServiceID(String(repeating: "A", count: 64)))
    }

    func testBothEndsPinTheTeam() {
        XCTAssertTrue(HelperConstants.clientRequirement.contains("identifier \"com.breed.Crossbar\""))
        XCTAssertTrue(HelperConstants.helperRequirement.contains("identifier \"com.breed.Crossbar.helper\""))
        for requirement in [HelperConstants.clientRequirement, HelperConstants.helperRequirement] {
            XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"YA83Q8FTH3\""))
            XCTAssertTrue(requirement.contains("anchor apple generic"))
        }
    }

    func testHelperErrorCodesReadAsPlainWords() {
        XCTAssertEqual(PrivilegedToggleError.describe(HelperConstants.ErrorCode.unknownServiceID),
                       "that service no longer exists")
        XCTAssertEqual(PrivilegedToggleError.describe("something-new"), "something-new")
    }
}
