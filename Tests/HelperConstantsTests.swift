import XCTest

final class HelperConstantsTests: XCTestCase {
    func testRealServiceIDsAreWellFormed() {
        XCTAssertTrue(HelperConstants.isWellFormedServiceID("D98EBBFE-336E-40B0-966C-81AA31D60CDF"))
        XCTAssertTrue(HelperConstants.isWellFormedServiceID("558da122-9f8f-4878-a395-ee68948176a5"))
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
