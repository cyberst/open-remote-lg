import Testing
@testable import OpenRemote

struct TVModelYearTests {
    @Test(arguments: [
        ("55SM8000", 2019), ("55SM8600PLA", 2019), ("43UK6300", 2018), ("49LF6300", 2015), ("49UB8500", 2014),
        ("43UJ6300", 2017), ("55UH6150", 2016), ("50UQ7500", 2022), ("55UR8000", 2023), ("55UT8000", 2024),
        ("55UA7300", 2025), ("50UN7300", 2020), ("65UP7700", 2021),
    ])
    func lcdModels(model: String, year: Int) {
        #expect(TVModelYear.year(modelName: model) == year)
    }

    @Test(arguments: [
        ("OLED65C9PUA", 2019), ("OLED55CX", 2020), ("OLED65CXPUA", 2020), ("OLED65G1PUA", 2021), ("OLED77Z29LA", 2022),
        ("OLED65C3PUA", 2023), ("OLED42C4", 2024), ("OLED65C5PUA", 2025), ("OLED65B7P", 2017), ("OLED55E8PLA", 2018),
        ("OLED65C6P", 2016), ("OLED55B6V", 2016), ("OLED65C6PUA", 2026),
    ])
    func oledModels(model: String, year: Int) {
        #expect(TVModelYear.year(modelName: model) == year)
    }

    @Test(arguments: [
        ("65NANO85UNA", 2020), ("65NANO86TNA", 2020), ("65NANO90UPA", 2021), ("50NANO75UQA", 2022), ("65NANO77SRA", 2023),
        ("65NANO80T6A", 2024), ("65QNED90UPA", 2021), ("65QNED85UQA", 2022), ("65QNED80URA", 2023), ("65QNED85T6A", 2024),
        ("65QNED85AUA", 2025),
    ])
    func nanoAndQNEDModels(model: String, year: Int) {
        #expect(TVModelYear.year(modelName: model) == year)
    }

    @Test func wrappedAndLowercaseNames() {
        #expect(TVModelYear.year(modelName: "[LG] webOS TV OLED55C9PLA") == 2019)
        #expect(TVModelYear.year(modelName: "55sm8600pla.aeu") == 2019)
        #expect(TVModelYear.year(modelName: " 43UK6300MLB ") == 2018)
    }

    @Test func webOSBreaksTheOLED6Tie() {
        #expect(TVModelYear.year(modelName: "OLED65C6PUA", webOSVersion: "3.0") == 2016)
        #expect(TVModelYear.year(modelName: "OLED65C6P", webOSVersion: "26") == 2026)
    }

    @Test func modelNameBeatsWebOS() {
        // A 2022 TV updated to webOS 24 is still a 2022 TV.
        #expect(TVModelYear.year(modelName: "OLED65C2PUA", webOSVersion: "24") == 2022)
    }

    @Test(arguments: [
        ("1.4", 2014), ("2.0", 2015), ("3.0", 2016), ("3.5", 2017), ("4.0", 2018), ("4.5", 2019), ("5.0", 2020),
        ("6.0", 2021), ("22", 2022), ("23", 2023), ("25", 2025),
    ])
    func webOSFallback(version: String, year: Int) {
        #expect(TVModelYear.year(modelName: "LG TV", webOSVersion: version) == year)
    }

    @Test func unknownNames() {
        #expect(TVModelYear.year(modelName: nil) == nil)
        #expect(TVModelYear.year(modelName: "Demo (no TV needed)", webOSVersion: "Demo") == nil)
        #expect(TVModelYear.year(modelName: "LG TV") == nil)
        #expect(TVModelYear.year(modelName: "27ART10AKPL") == nil)
        #expect(TVModelYear.year(modelName: "") == nil)
    }
}
