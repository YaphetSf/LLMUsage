import Foundation
import LLMUsagePreferences
import Testing

struct LLMEnvFileTests {
    private func writeFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-env-\(UUID().uuidString).env")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func parsesTheShellSourcedShape() {
        let values = LLMEnvFile.parse("""
        # Secrets only. NOTE=this is not a value

        export DOUBLE="double-value" # Z.ai key, renewed monthly
        export SINGLE='single-value'   # note
        export  SPACED="spaced-value"
        BARE=bare-value # note
        export WITH_EQUALS="a=b=c"
        export EMPTY=""
        export NO_ASSIGNMENT
        """)
        #expect(values == [
            "DOUBLE": "double-value",
            "SINGLE": "single-value",
            "SPACED": "spaced-value",
            "BARE": "bare-value",
            "WITH_EQUALS": "a=b=c",
            "EMPTY": ""
        ])
    }

    @Test func lastAssignmentWinsLikeSourcing() {
        #expect(LLMEnvFile.parse("export KEY=\"old\"\nexport KEY=\"new\"\n") == ["KEY": "new"])
    }

    @Test func fileBeatsTheProcessEnvironment() throws {
        let file = try writeFile("export ZAI_API_KEY=\"from-file\" # note\n")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(LLMEnvFile.value("ZAI_API_KEY", file: file, environment: ["ZAI_API_KEY": "from-env"]) == "from-file")
    }

    @Test func fileBeatsAnEarlierNameInTheEnvironment() throws {
        let file = try writeFile("export GLM_API_KEY=\"from-file\"\n")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(LLMEnvFile.value("ZAI_API_KEY", "GLM_API_KEY", file: file, environment: ["ZAI_API_KEY": "from-env"])
            == "from-file")
    }

    @Test func missingFileFallsBackToTheEnvironment() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).env")
        #expect(LLMEnvFile.value("ZAI_API_KEY", file: file, environment: ["ZAI_API_KEY": "from-env"]) == "from-env")
        #expect(LLMEnvFile.value("ZAI_API_KEY", file: file, environment: [:]) == nil)
    }

    @Test func blankValuesCountAsMissing() throws {
        let file = try writeFile("export ZAI_API_KEY=\"  \"\n")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(LLMEnvFile.value("ZAI_API_KEY", file: file, environment: ["ZAI_API_KEY": " "]) == nil)
    }
}
