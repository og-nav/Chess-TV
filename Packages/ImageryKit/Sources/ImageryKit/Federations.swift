import Foundation

/// The FIDE federation codes that appear in Lichess payloads, and the flag to draw for each.
///
/// Lichess sends a three-letter code in `fed` on broadcast players and in `federation` on FIDE
/// records. The codes are IOC-style but are FIDE's own list, so they are neither ISO 3166-1
/// alpha-3 nor pure IOC: `GER` for Germany, `NED` for the Netherlands, `PHI` for the Philippines,
/// `IRI` for Iran, `SUI` for Switzerland, `RSA` for South Africa.
///
/// Flags are built from the ISO 3166-1 **alpha-2** code as a regional-indicator pair, which is
/// what the system emoji font renders, so the table maps FIDE code → (name, alpha-2) rather than
/// storing two hundred emoji literals. Four federations have no alpha-2 code at all and carry a
/// literal instead: England, Scotland and Wales are subdivision tag sequences, and FIDE's own
/// neutral flag is a plain white flag.
///
/// The table is a text blob parsed once rather than a two-hundred-entry dictionary literal:
/// a literal that size costs the type checker seconds on every clean build, and this form is
/// easier to read and to diff when FIDE admits a new federation.
public enum Federations {

    /// The flag emoji for a federation code, or `nil` if the code is not one FIDE uses.
    ///
    /// - Parameter code: case-insensitive, and surrounding whitespace is tolerated because
    ///   broadcast organisers occasionally type `" NOR"`.
    public static func flag(for code: String) -> String? {
        guard let entry = entry(for: code) else { return nil }
        if let literal = entry.literalFlag { return literal }
        guard let alpha2 = entry.alpha2 else { return nil }
        return regionalIndicators(alpha2)
    }

    /// The federation's English name, or `nil` if the code is not one FIDE uses.
    public static func name(for code: String) -> String? {
        entry(for: code)?.name
    }

    /// Every code in the table, for tests and for a settings picker.
    public static var allCodes: [String] { Array(table.keys).sorted() }

    // MARK: - Internals

    struct Entry: Sendable {
        let name: String
        /// ISO 3166-1 alpha-2, when the federation has one.
        let alpha2: String?
        /// Used when no alpha-2 code exists: the three home-nation tag sequences and FIDE's own flag.
        let literalFlag: String?
    }

    static func entry(for code: String) -> Entry? {
        table[code.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /// `"NO"` → `"\u{1F1F3}\u{1F1F4}"`. Each ASCII letter maps to the regional indicator symbol
    /// 0x1F1E6 letters above `A`; a pair of them is what renders as a flag.
    static func regionalIndicators(_ alpha2: String) -> String? {
        let scalars = alpha2.uppercased().unicodeScalars
        guard scalars.count == 2 else { return nil }
        var flag = ""
        for scalar in scalars {
            guard scalar.value >= 0x41, scalar.value <= 0x5A,
                  let indicator = Unicode.Scalar(scalar.value - 0x41 + 0x1F1E6) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    /// Federations with no ISO 3166-1 alpha-2 code of their own.
    ///
    /// England, Scotland and Wales are separate FIDE federations but subdivisions of GB, so their
    /// flags are RFC-style tag sequences (`U+1F3F4` plus `gbeng`/`gbsct`/`gbwls` as tag characters
    /// and a cancel tag). `FID` is the flag players compete under when their federation is
    /// suspended or they have none; `AIN` is the same idea under the current neutral-athlete name.
    private static let literalFlags: [String: String] = [
        "ENG": "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
        "SCO": "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
        "WLS": "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}",
        "FID": "\u{1F3F3}\u{FE0F}",
        "AIN": "\u{1F3F3}\u{FE0F}",
    ]

    static let table: [String: Entry] = {
        var table: [String: Entry] = [:]
        for row in rawTable.split(separator: "\n") {
            let fields = row.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let code = String(fields[0])
            let alpha2 = fields[2] == "-" ? nil : String(fields[2])
            table[code] = Entry(name: String(fields[1]), alpha2: alpha2, literalFlag: literalFlags[code])
        }
        return table
    }()

    /// `FIDE code|English name|ISO 3166-1 alpha-2 or "-"`, from FIDE's federation list.
    private static let rawTable = """
    AFG|Afghanistan|AF
    AIN|Individual Neutral Athletes|-
    ALB|Albania|AL
    ALG|Algeria|DZ
    AND|Andorra|AD
    ANG|Angola|AO
    ANT|Antigua and Barbuda|AG
    ARG|Argentina|AR
    ARM|Armenia|AM
    ARU|Aruba|AW
    AUS|Australia|AU
    AUT|Austria|AT
    AZE|Azerbaijan|AZ
    BAH|Bahamas|BS
    BAN|Bangladesh|BD
    BAR|Barbados|BB
    BDI|Burundi|BI
    BEL|Belgium|BE
    BEN|Benin|BJ
    BER|Bermuda|BM
    BHU|Bhutan|BT
    BIH|Bosnia and Herzegovina|BA
    BIZ|Belize|BZ
    BLR|Belarus|BY
    BOL|Bolivia|BO
    BOT|Botswana|BW
    BRA|Brazil|BR
    BRN|Bahrain|BH
    BRU|Brunei Darussalam|BN
    BUL|Bulgaria|BG
    BUR|Burkina Faso|BF
    CAF|Central African Republic|CF
    CAM|Cambodia|KH
    CAN|Canada|CA
    CAY|Cayman Islands|KY
    CGO|Congo|CG
    CHA|Chad|TD
    CHI|Chile|CL
    CHN|China|CN
    CIV|Cote d'Ivoire|CI
    CMR|Cameroon|CM
    COD|DR Congo|CD
    COL|Colombia|CO
    COM|Comoros|KM
    CPV|Cape Verde|CV
    CRC|Costa Rica|CR
    CRO|Croatia|HR
    CUB|Cuba|CU
    CUR|Curacao|CW
    CYP|Cyprus|CY
    CZE|Czechia|CZ
    DEN|Denmark|DK
    DJI|Djibouti|DJ
    DMA|Dominica|DM
    DOM|Dominican Republic|DO
    ECU|Ecuador|EC
    EGY|Egypt|EG
    ENG|England|-
    ERI|Eritrea|ER
    ESA|El Salvador|SV
    ESP|Spain|ES
    EST|Estonia|EE
    ETH|Ethiopia|ET
    FAI|Faroe Islands|FO
    FID|FIDE|-
    FIJ|Fiji|FJ
    FIN|Finland|FI
    FRA|France|FR
    FSM|Micronesia|FM
    GAB|Gabon|GA
    GAM|Gambia|GM
    GBS|Guinea-Bissau|GW
    GCI|Guernsey|GG
    GEO|Georgia|GE
    GEQ|Equatorial Guinea|GQ
    GER|Germany|DE
    GHA|Ghana|GH
    GIB|Gibraltar|GI
    GRE|Greece|GR
    GRN|Grenada|GD
    GUA|Guatemala|GT
    GUI|Guinea|GN
    GUM|Guam|GU
    GUY|Guyana|GY
    HAI|Haiti|HT
    HKG|Hong Kong|HK
    HON|Honduras|HN
    HUN|Hungary|HU
    IBCA|International Braille Chess Association|-
    ICCD|International Committee of Chess for the Deaf|-
    INA|Indonesia|ID
    IND|India|IN
    IOM|Isle of Man|IM
    IPCA|International Physically Disabled Chess Association|-
    IRI|Iran|IR
    IRL|Ireland|IE
    IRQ|Iraq|IQ
    ISL|Iceland|IS
    ISR|Israel|IL
    ISV|US Virgin Islands|VI
    ITA|Italy|IT
    IVB|British Virgin Islands|VG
    JAM|Jamaica|JM
    JCI|Jersey|JE
    JOR|Jordan|JO
    JPN|Japan|JP
    KAZ|Kazakhstan|KZ
    KEN|Kenya|KE
    KGZ|Kyrgyzstan|KG
    KOR|South Korea|KR
    KOS|Kosovo|XK
    KSA|Saudi Arabia|SA
    KUW|Kuwait|KW
    LAO|Laos|LA
    LAT|Latvia|LV
    LBA|Libya|LY
    LBN|Lebanon|LB
    LBR|Liberia|LR
    LCA|Saint Lucia|LC
    LES|Lesotho|LS
    LIE|Liechtenstein|LI
    LTU|Lithuania|LT
    LUX|Luxembourg|LU
    MAC|Macau|MO
    MAD|Madagascar|MG
    MAR|Morocco|MA
    MAS|Malaysia|MY
    MAW|Malawi|MW
    MDA|Moldova|MD
    MDV|Maldives|MV
    MEX|Mexico|MX
    MGL|Mongolia|MN
    MHL|Marshall Islands|MH
    MKD|North Macedonia|MK
    MLI|Mali|ML
    MLT|Malta|MT
    MNC|Monaco|MC
    MNE|Montenegro|ME
    MOZ|Mozambique|MZ
    MRI|Mauritius|MU
    MTN|Mauritania|MR
    MYA|Myanmar|MM
    NAM|Namibia|NA
    NCA|Nicaragua|NI
    NED|Netherlands|NL
    NEP|Nepal|NP
    NGR|Nigeria|NG
    NIG|Niger|NE
    NOR|Norway|NO
    NZL|New Zealand|NZ
    OMA|Oman|OM
    PAK|Pakistan|PK
    PAN|Panama|PA
    PAR|Paraguay|PY
    PER|Peru|PE
    PHI|Philippines|PH
    PLE|Palestine|PS
    PLW|Palau|PW
    PNG|Papua New Guinea|PG
    POL|Poland|PL
    POR|Portugal|PT
    PRK|North Korea|KP
    PUR|Puerto Rico|PR
    QAT|Qatar|QA
    ROU|Romania|RO
    RSA|South Africa|ZA
    RUS|Russia|RU
    RWA|Rwanda|RW
    SCO|Scotland|-
    SEN|Senegal|SN
    SEY|Seychelles|SC
    SGP|Singapore|SG
    SKN|Saint Kitts and Nevis|KN
    SLE|Sierra Leone|SL
    SLO|Slovenia|SI
    SMR|San Marino|SM
    SOL|Solomon Islands|SB
    SOM|Somalia|SO
    SRB|Serbia|RS
    SRI|Sri Lanka|LK
    SSD|South Sudan|SS
    STP|Sao Tome and Principe|ST
    SUD|Sudan|SD
    SUI|Switzerland|CH
    SUR|Suriname|SR
    SVK|Slovakia|SK
    SWE|Sweden|SE
    SWZ|Eswatini|SZ
    SYR|Syria|SY
    TAN|Tanzania|TZ
    TGA|Tonga|TO
    THA|Thailand|TH
    TJK|Tajikistan|TJ
    TKM|Turkmenistan|TM
    TLS|Timor-Leste|TL
    TOG|Togo|TG
    TPE|Chinese Taipei|TW
    TTO|Trinidad and Tobago|TT
    TUN|Tunisia|TN
    TUR|Turkiye|TR
    UAE|United Arab Emirates|AE
    UGA|Uganda|UG
    UKR|Ukraine|UA
    URU|Uruguay|UY
    USA|United States of America|US
    UZB|Uzbekistan|UZ
    VAN|Vanuatu|VU
    VEN|Venezuela|VE
    VIE|Vietnam|VN
    VIN|Saint Vincent and the Grenadines|VC
    WLS|Wales|-
    YEM|Yemen|YE
    ZAM|Zambia|ZM
    ZIM|Zimbabwe|ZW
    """
}
