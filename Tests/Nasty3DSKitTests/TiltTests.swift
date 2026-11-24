import Testing
@testable import Nasty3DSKit

@Test func theConsoleLiesFlatWhenTheGameStarts() {
    #expect(Tilt.upright == Tilt(x: 0, y: -1, z: 0))
}

/// Upside down = gravity pulls to the hinge (+z) and out of the lower screen (+y): the two readings
/// a game can use to see the turn. The length stays 1 g, as on a console that does not move.
@Test func upsideDownTurnsGravityToTheHingeAndOutOfTheScreen() {
    let t = Tilt.upsideDown
    #expect(t.z > 0.5 && t.y > 0 && t.x == 0)
    #expect(abs((t.x * t.x + t.y * t.y + t.z * t.z).squareRoot() - 1) < 0.01)
}

@Test func theDiagnosisTextGivesThreeNumbers() {
    #expect(Tilt(text: "0,0,1") == Tilt(x: 0, y: 0, z: 1))
    #expect(Tilt(text: " 0.5, -1 ,0.25 ") == Tilt(x: 0.5, y: -1, z: 0.25))
}

@Test func aBadDiagnosisTextGivesNothing() {
    for text in ["", "1,2", "1,2,3,4", "a,b,c", "1,,3", "nan,0,0", "inf,0,0", "0,0,9"] {
        #expect(Tilt(text: text) == nil, "\(text)")
    }
}
