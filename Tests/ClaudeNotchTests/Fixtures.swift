import Foundation

/// Fixtures JSON inline (evita depender de resources do SPM pra fixture pequena).
enum Fixtures {
    static func usageJSON(fiveHourResetsAt: String = "2099-01-01T00:00:00Z",
                           fiveHourPct: Double = 42,
                           sevenDayPct: Double = 17,
                           includeOpusSonnet: Bool = true,
                           extraUsageJSON: String? = nil) -> Data {
        let opusSonnet = includeOpusSonnet ? """
        ,"seven_day_opus": {"utilization": 5, "resets_at": "2099-01-08T00:00:00Z"},
        "seven_day_sonnet": {"utilization": 12, "resets_at": "2099-01-08T00:00:00Z"}
        """ : ""
        let extraUsage = extraUsageJSON.map { ",\"extra_usage\": \($0)" } ?? ""
        let json = """
        {
            "five_hour": {"utilization": \(fiveHourPct), "resets_at": "\(fiveHourResetsAt)"},
            "seven_day": {"utilization": \(sevenDayPct), "resets_at": "2099-01-08T00:00:00Z"}
            \(opusSonnet)
            \(extraUsage)
        }
        """
        return Data(json.utf8)
    }

    static func profileJSON(tier: String) -> Data {
        let json = """
        {
            "organization": {"rate_limit_tier": "\(tier)"}
        }
        """
        return Data(json.utf8)
    }
}
