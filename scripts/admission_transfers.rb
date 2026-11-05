require_relative 'research_data'
require 'tmpdir'
require 'set'
gem 'roo', '2.8.3'
gem 'rubyzip', '2.3.2'
gem 'spreadsheet', '1.3.5'
gem 'ruby-ole', '1.2.13.1'
require 'roo'
require 'zip'
require 'spreadsheet'
require 'ole/storage'

module AdmissionTransfers
  TRANSFER_YEARS = {
    '2024' => {
      notice_source_id: 'SRC-LN-TRANSFER-NOTICE-2024',
      phys_source_id: 'SRC-LN-TRANSFER-PHYS-2024',
      record_prefix: 'LN-T2024-'
    },
    '2025' => {
      notice_source_id: 'SRC-LN-TRANSFER-NOTICE-2025',
      phys_source_id: 'SRC-LN-TRANSFER-PHYS-2025',
      record_prefix: 'LN-T2025-'
    },
    '2026' => {
      notice_source_id: 'SRC-LN-TRANSFER-NOTICE-2026',
      phys_source_id: 'SRC-LN-TRANSFER-PHYS-2026',
      record_prefix: 'LN-T2026-'
    }
  }.freeze

  HEADER_FIELDS = {
    institution_code: '院校编号',
    institution_name: '招生院校',
    major_code: '专业编号',
    major_name: '招生专业',
    score: '投档最低分'
  }.freeze

  DERIVED_FIELDS = %w[
    record_id source_id admission_year source_sheet source_row institution_code institution_name major_code major_name
    score tie_1 tie_2 tie_3 tie_4 tie_5 tie_6 tie_7
  ].freeze

  ADMISSIONS_FIELDS = SCHEMAS.fetch('data/admissions.csv')

  def self.normalize_text(value)
    value.to_s.gsub(/[\u00A0\s]/, '')
  end

  def self.load_manifest_entry(source_id)
    entry = archive_entries.reverse.find { |item| item['source_id'] == source_id }
    raise "Archive missing for #{source_id}" unless entry
    path = local_path(entry.fetch('path'))
    raise "Archived file missing: #{entry['path']}" unless File.file?(path)
    actual_sha = Digest::SHA256.file(path).hexdigest
    raise "Archived SHA mismatch for #{source_id}" unless actual_sha == entry.fetch('sha256')
    entry
  end

  def self.first_excel_entry(zip)
    candidates = zip.entries.select do |entry|
      entry.file? && entry.name.downcase.match?(/\.(xlsx|xls)\z/)
    end
    raise 'ZIP has no Excel attachment' if candidates.empty?
    raise 'ZIP has multiple Excel attachments' if candidates.length > 1
    candidates.first
  end

  def self.read_2024_sheet(path)
    Zip::File.open(path) do |zip|
      excel_entry = first_excel_entry(zip)
      Dir.mktmpdir('admission-transfer-2024-') do |tmpdir|
        extracted = File.join(tmpdir, 'transfer-2024.xlsx')
        File.binwrite(extracted, excel_entry.get_input_stream.read)
        workbook = Roo::Spreadsheet.open(extracted)
        sheets = workbook.sheets
        raise 'Expected exactly one worksheet in 2024 workbook' unless sheets.length == 1
        sheet_name = sheets.first
        sheet = workbook.sheet(sheet_name)
        rows = parse_rows_from_roo(sheet, sheet_name, '2024')
        workbook.close if workbook.respond_to?(:close)
        rows
      end
    end
  end

  def self.encrypted_ole_package?(path)
    storage = Ole::Storage.open(path)
    names = storage.dirents.map(&:name)
    names.include?('EncryptedPackage') && names.include?('EncryptionInfo') && !names.include?('Workbook') && !names.include?('Book')
  rescue StandardError
    false
  end

  def self.read_2025_sheet(path)
    workbook = Spreadsheet.open(path)
    raise 'Expected at least one worksheet in 2025 workbook' if workbook.worksheets.empty?
    sheet = workbook.worksheet(0)
    parse_rows_from_spreadsheet(sheet, '2025')
  rescue RuntimeError => error
    if encrypted_ole_package?(path)
      raise 'Unsupported encrypted 2025 attachment structure: EncryptedPackage/EncryptionInfo found, cannot read raw Spreadsheet cell values without decryption key'
    end
    raise error
  end

  def self.read_2026_sheet(path)
    workbook = Roo::Spreadsheet.open(path)
    sheets = workbook.sheets
    raise 'Expected exactly one worksheet in 2026 workbook' unless sheets.length == 1
    sheet_name = sheets.first
    sheet = workbook.sheet(sheet_name)
    rows = parse_rows_from_roo(sheet, sheet_name, '2026')
    workbook.close if workbook.respond_to?(:close)
    rows
  end

  def self.extract_tie_headers(row3, row4, row5)
    raise 'Header row 3 missing tie-break section label' unless normalize_text(row3[5]).include?('投档最低分相同考生排序项')
    labels = row5.first(12).drop(5).map { |item| normalize_text(item) }
    raise 'Header row 5 tie-break fields are incomplete' unless labels.length == 7 && labels.all? { |item| !item.empty? }
    ordinals = row4.first(12).drop(5).map { |item| normalize_text(item) }
    unless ordinals == %w[（一） （二） （三） （四） （五） （六） （七）]
      raise 'Header row 4 tie-break ordinals are unexpected'
    end
    labels
  end

  def self.validate_primary_headers(row3)
    expected = [
      HEADER_FIELDS[:institution_code],
      HEADER_FIELDS[:institution_name],
      HEADER_FIELDS[:major_code],
      HEADER_FIELDS[:major_name],
      HEADER_FIELDS[:score]
    ]
    actual = row3.first(5).map { |item| normalize_text(item) }
    raise "Unexpected primary headers: #{actual.join('|')}" unless actual == expected
  end

  def self.validate_title_year!(title_value, expected_year)
    title = normalize_text(title_value)
    raise 'Worksheet title does not mention 物理学科类' unless title.include?('物理学科类')
    raise "Worksheet title year does not match #{expected_year}" unless title.include?(expected_year)
  end

  def self.parse_rows_from_roo(sheet, sheet_name, expected_year)
    row1 = (1..12).map { |column| sheet.cell(1, column) }
    validate_title_year!(row1[0], expected_year)
    row3 = (1..12).map { |column| sheet.cell(3, column) }
    row4 = (1..12).map { |column| sheet.cell(4, column) }
    row5 = (1..12).map { |column| sheet.cell(5, column) }
    validate_primary_headers(row3)
    tie_headers = extract_tie_headers(row3, row4, row5)

    records = []
    row_width = [sheet.last_column.to_i, 12].max
    (6..sheet.last_row).each do |row_index|
      values = (1..row_width).map { |column| sheet.cell(row_index, column)&.to_s }
      next if values.all? { |item| item.to_s.strip.empty? }
      validate_data_row!(values, row_index)
      records << to_transfer_row(values, row_index, sheet_name, tie_headers)
    end
    raise 'No data rows found in worksheet' if records.empty?
    { tie_headers: tie_headers, rows: records }
  end

  def self.parse_rows_from_spreadsheet(sheet, expected_year)
    row1 = sheet.row(0).first(12)
    validate_title_year!(row1[0], expected_year)
    row3 = sheet.row(2).first(12)
    row4 = sheet.row(3).first(12)
    row5 = sheet.row(4).first(12)
    validate_primary_headers(row3)
    tie_headers = extract_tie_headers(row3, row4, row5)

    records = []
    (5..sheet.last_row_index).each do |row_index|
      row = sheet.row(row_index)
      values = row.map { |item| item&.to_s }
      next if values.all? { |item| item.to_s.strip.empty? }
      validate_data_row!(values, row_index + 1)
      records << to_transfer_row(values, row_index + 1, sheet.name.to_s, tie_headers)
    end
    raise 'No data rows found in worksheet' if records.empty?
    { tie_headers: tie_headers, rows: records }
  end

  def self.validate_data_row!(values, source_row)
    raise "Row #{source_row} has unexpected extra columns" if values.drop(12).any? { |item| !item.to_s.strip.empty? }
    required = values.first(5)
    raise "Row #{source_row} is missing primary fields" if required.any? { |item| item.to_s.strip.empty? }
    raise "Row #{source_row} has non-integer score" unless values[4].to_s.strip.match?(/\A\d+\z/)
    score = values[4].to_i
    raise "Row #{source_row} score out of range 0..750" unless score >= 0 && score <= 750
    tie_values = values.first(12).drop(5)
    raise "Row #{source_row} has incomplete tie-break fields" unless tie_values.length == 7 && tie_values.all? { |item| !item.to_s.strip.empty? }
    tie_values.each_with_index do |item, index|
      unless item.to_s.strip.match?(/\A\d+\z/)
        raise "Row #{source_row} tie-break field #{index + 1} is not an integer"
      end
    end
  end

  def self.to_transfer_row(values, source_row, sheet_name, tie_headers)
    {
      source_sheet: sheet_name,
      source_row: source_row.to_i,
      institution_code: values[0].to_s.strip,
      institution_name: values[1].to_s.strip,
      major_code: values[2].to_s.strip,
      major_name: values[3].to_s.strip,
      score: values[4].to_s.sub(/\.0+\z/, ''),
      tie_headers: tie_headers,
      tie_values: values.first(12).drop(5).map { |item| item.to_s.strip }
    }
  end

  def self.to_admissions_record(year, transfer_row)
    config = TRANSFER_YEARS.fetch(year)
    {
      'record_id' => "#{config[:record_prefix]}#{transfer_row[:source_row]}",
      'recorded_on' => Date.today.iso8601,
      'admission_year' => year,
      'province' => '辽宁',
      'candidate_category' => '物理类',
      'batch' => '本科批',
      'plan_type' => '普通类',
      'institution_code' => transfer_row[:institution_code],
      'institution_name' => transfer_row[:institution_name],
      'campus' => nil,
      'group_code' => nil,
      'group_members' => nil,
      'major_code' => transfer_row[:major_code],
      'major_name' => transfer_row[:major_name],
      'subject_requirements' => nil,
      'plan_count' => nil,
      'score' => transfer_row[:score],
      'rank' => nil,
      'statistic_type' => '专业投档最低分',
      'value_origin' => '官方附件直接值',
      'verification_status' => '已核实附件原表',
      'source_ids' => "#{config[:notice_source_id]}|#{config[:phys_source_id]}",
      'notes' => '同分排序字段见派生CSV；该值为投档最低分，不等于院校最终录取最低分'
    }
  end

  def self.load_admissions_rows
    path = local_path('data/admissions.csv')
    rows = CSV.read(path, headers: true, encoding: 'bom|utf-8')
    raise 'Admissions header mismatch' unless rows.headers == ADMISSIONS_FIELDS
    rows
  end

  def self.append_admissions_records(records)
    table = load_admissions_rows
    by_id = {}
    table.each { |row| by_id[row['record_id']] = row }
    additions = []

    records.each do |record|
      identifier = record.fetch('record_id')
      existing = by_id[identifier]
      if existing
        same = (ADMISSIONS_FIELDS - ['recorded_on']).all? { |field| existing[field].to_s == record[field].to_s }
        raise "Existing admissions record conflict: #{identifier}" unless same
        next
      end
      additions << record
      by_id[identifier] = record
    end

    return { added: 0, skipped: records.length } if additions.empty?

    path = local_path('data/admissions.csv')
    CSV.open(path, 'w', encoding: 'UTF-8') do |csv|
      csv << ADMISSIONS_FIELDS
      table.each { |row| csv << ADMISSIONS_FIELDS.map { |field| row[field] } }
      additions.each { |row| csv << ADMISSIONS_FIELDS.map { |field| row[field] } }
    end
    { added: additions.length, skipped: records.length - additions.length }
  end

  def self.derived_row(year, source_id, transfer_row)
    {
      'record_id' => "#{TRANSFER_YEARS.fetch(year)[:record_prefix]}#{transfer_row[:source_row]}",
      'source_id' => source_id,
      'admission_year' => year,
      'source_sheet' => transfer_row[:source_sheet],
      'source_row' => transfer_row[:source_row].to_s,
      'institution_code' => transfer_row[:institution_code],
      'institution_name' => transfer_row[:institution_name],
      'major_code' => transfer_row[:major_code],
      'major_name' => transfer_row[:major_name],
      'score' => transfer_row[:score],
      'tie_1' => transfer_row[:tie_values][0],
      'tie_2' => transfer_row[:tie_values][1],
      'tie_3' => transfer_row[:tie_values][2],
      'tie_4' => transfer_row[:tie_values][3],
      'tie_5' => transfer_row[:tie_values][4],
      'tie_6' => transfer_row[:tie_values][5],
      'tie_7' => transfer_row[:tie_values][6]
    }
  end

  def self.write_csv(path, fields, rows)
    CSV.open(path, 'w', encoding: 'UTF-8') do |csv|
      csv << fields
      rows.each { |row| csv << fields.map { |field| row[field] } }
    end
  end

  def self.build_summary(year_results)
    summary_by_year = {}
    year_results.each do |year, payload|
      rows = payload.fetch(:rows)
      institutions = rows.group_by { |item| [item[:institution_code], item[:institution_name]] }
      scores = rows.map { |item| item[:score].to_i }
      summary_by_year[year] = {
        records: rows.length,
        institution_groups: institutions.length,
        score_range: { min: scores.min, max: scores.max },
        tie_break_fields: payload.fetch(:tie_headers),
        sample_institutions: institutions.keys.first(3).map { |code, name| { institution_code: code, institution_name: name } }
      }
    end
    summary_by_year
  end

  def self.write_derived_outputs(year_results)
    stamp = Time.now.utc
    relative_root = "data/derived/admission-transfers/admission-transfers-#{stamp.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}"
    root = local_path(relative_root)
    raise 'Refusing to overwrite an existing derived transfer directory' if File.exist?(root)
    FileUtils.mkdir_p(root)

    files = []
    year_results.keys.sort.each do |year|
      payload = year_results.fetch(year)
      source_id = payload.fetch(:source_id)
      rows = payload.fetch(:rows).map { |row| derived_row(year, source_id, row) }
      file_name = "all-#{year}.csv"
      absolute = File.join(root, file_name)
      write_csv(absolute, DERIVED_FIELDS, rows)
      files << { path: "#{relative_root}/#{file_name}", sha256: Digest::SHA256.file(absolute).hexdigest }
    end

    summary = {
      generated_at: stamp.iso8601,
      years: year_results.keys.sort,
      source_ids: year_results.values.map { |item| item.fetch(:source_id) },
      notice_source_ids: year_results.values.map { |item| item.fetch(:notice_source_id) },
      by_year: build_summary(year_results),
      limitations: ['结果为普通类本科批投档最低分，不等于最终录取最低分', '未核校区、选科细分、计划人数与位次，rank留空', '同分排序完整字段保存在派生CSV']
    }
    summary_path = File.join(root, 'summary.json')
    File.write(summary_path, JSON.pretty_generate(summary) + "\n")
    files << { path: "#{relative_root}/summary.json", sha256: Digest::SHA256.file(summary_path).hexdigest }

    run_manifest = {
      generated_at: stamp.iso8601,
      years: year_results.keys.sort,
      files: files,
      sources: year_results.transform_values do |item|
        {
          notice_source_id: item.fetch(:notice_source_id),
          source_id: item.fetch(:source_id),
          source_path: item.fetch(:source_path),
          source_sha256: item.fetch(:source_sha256)
        }
      end
    }
    run_manifest_path = File.join(root, 'manifest.json')
    File.write(run_manifest_path, JSON.pretty_generate(run_manifest) + "\n")
    files << { path: "#{relative_root}/manifest.json", sha256: Digest::SHA256.file(run_manifest_path).hexdigest }

    shared_manifest_path = local_path('data/derived/admission-transfers/manifest.jsonl')
    FileUtils.mkdir_p(File.dirname(shared_manifest_path))
    File.open(shared_manifest_path, 'a') { |file| file.puts(JSON.generate(run_manifest)) }

    { relative_root: relative_root, summary: summary, files: files }
  end

  def self.load_year_result(year)
    config = TRANSFER_YEARS.fetch(year)
    notice_entry = load_manifest_entry(config[:notice_source_id])
    phys_entry = load_manifest_entry(config[:phys_source_id])
    path = local_path(phys_entry.fetch('path'))
    parsed = case year
         when '2024' then read_2024_sheet(path)
         when '2025' then read_2025_sheet(path)
         when '2026' then read_2026_sheet(path)
         else raise "Unsupported year: #{year}"
         end
    {
      source_id: config[:phys_source_id],
      notice_source_id: config[:notice_source_id],
      source_path: phys_entry.fetch('path'),
      source_sha256: phys_entry.fetch('sha256'),
      notice_path: notice_entry.fetch('path'),
      rows: parsed.fetch(:rows),
      tie_headers: parsed.fetch(:tie_headers)
    }
  end

  def self.run(arguments)
    years = arguments.empty? ? %w[2024 2025 2026] : arguments
    unknown = years - TRANSFER_YEARS.keys
    raise "Unknown years: #{unknown.join(',')}" unless unknown.empty?

    check

    year_results = {}
    years.each do |year|
      year_results[year] = load_year_result(year)
    end

    all_records = year_results.flat_map do |year, payload|
      payload.fetch(:rows).map { |row| to_admissions_record(year, row) }
    end
    duplicate_ids = all_records.map { |item| item['record_id'] }.group_by { |item| item }.select { |_k, v| v.length > 1 }.keys
    raise "Duplicate generated record IDs: #{duplicate_ids.join(',')}" unless duplicate_ids.empty?

    admissions_result = append_admissions_records(all_records)
    derived_result = write_derived_outputs(year_results)

    puts JSON.pretty_generate(
      admissions: admissions_result,
      derived_root: derived_result[:relative_root],
      by_year: derived_result[:summary][:by_year]
    )
    { admissions: admissions_result, derived: derived_result }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    AdmissionTransfers.run(ARGV)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end