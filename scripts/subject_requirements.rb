require_relative 'research_data'
require 'tmpdir'
gem 'roo', '2.8.3'
require 'roo'

module SubjectRequirements
  SOURCE_ID = 'SRC-LN-SELECT-XLSX'.freeze
  SUBJECTS = %w[物理 历史 化学 生物 思想政治 地理].freeze
  HEADERS = %w[院校代码 院校名称 招生专业代码 招生专业名称 层次 选考科目要求].freeze
  FIELDS = %w[record_id source_id source_sheet source_row institution_code institution_name admission_major_code admission_major_name level subject_requirements_raw selected_subjects eligibility_status eligibility_reason missing_subjects].freeze

  def self.classify(raw, selected)
    text = raw.to_s.strip
    return { status: 'eligible', reason: '原表不提科目要求', missing: [] } if text == '不提科目要求'
    match = /\A(?<subjects>[^()]+)\((?<count>[123])门科目考生(?<clause>必须|均须)选考方可报考\)\z/.match(text)
    if match
      required = match[:subjects].split(',')
      count = match[:count].to_i
      valid = required.length == count && required.uniq.length == count && (required - SUBJECTS).empty?
      valid &&= match[:clause] == (count == 1 ? '必须' : '均须')
      if valid
        missing = required - selected
        return { status: missing.empty? ? 'eligible' : 'ineligible', reason: missing.empty? ? '已选齐原表必选科目' : '缺少原表必选科目', missing: missing }
      end
    end
    { status: 'review_required', reason: '选科要求为空或不是已支持的原文规则，需人工核实', missing: [] }
  end

  def self.selected_subjects(arguments)
    selected = arguments.empty? ? %w[物理 化学 生物] : arguments
    valid = selected.length == 3 && selected.uniq.length == 3 && (selected - SUBJECTS).empty?
    valid &&= (selected & %w[物理 历史]).length == 1
    raise 'Choose physics or history plus two other subjects; use three separate subject arguments.' unless valid
    selected
  end

  def self.rows_from(path, selected)
    workbook = Roo::Excelx.new(path)
    raise 'Expected exactly Sheet1 in the official workbook' unless workbook.sheets == ['Sheet1']
    rows = []
    header_seen = false
    workbook.sheet('Sheet1').each_row_streaming(pad_cells: true) do |cells|
      values = Array.new(HEADERS.length) { |index| cells[index]&.value&.to_s }
      next if values.all? { |value| value.to_s.empty? }
      source_row = cells.compact.first.coordinate.first
      unless header_seen
        raise 'Unexpected official worksheet header' unless source_row == 1 && values == HEADERS
        header_seen = true
        next
      end
      raise "Unexpected extra columns at row #{source_row}" if cells.drop(HEADERS.length).any? { |cell| !cell&.value.to_s.empty? }
      raise "Missing institution, major or level at row #{source_row}" if values.first(5).any? { |value| value.to_s.empty? }
      result = classify(values[5], selected)
      rows << {
        'record_id' => "LN-SELECT-R#{source_row}", 'source_id' => SOURCE_ID,
        'source_sheet' => 'Sheet1', 'source_row' => source_row.to_s,
        'institution_code' => values[0], 'institution_name' => values[1],
        'admission_major_code' => values[2], 'admission_major_name' => values[3],
        'level' => values[4], 'subject_requirements_raw' => values[5],
        'selected_subjects' => selected.join('|'), 'eligibility_status' => result[:status],
        'eligibility_reason' => result[:reason], 'missing_subjects' => result[:missing].join('|')
      }
    end
    raise 'No subject requirement data found' if rows.empty?
    rows
  ensure
    workbook.close if workbook
  end

  def self.write_csv(path, fields, rows)
    CSV.open(path, 'w', encoding: 'UTF-8') do |csv|
      csv << fields
      rows.each { |row| csv << fields.map { |field| row[field] } }
    end
  end

  def self.run(arguments)
    selected = selected_subjects(arguments)
    check
    entry = archive_entries.reverse.find { |item| item['source_id'] == SOURCE_ID }
    raise 'Archive the official workbook first' unless entry
    source_path = local_path(entry.fetch('path'))
    rows = rows_from(source_path, selected)
    eligible = rows.select { |row| row['eligibility_status'] == 'eligible' }
    schools = rows.group_by { |row| [row['institution_code'], row['institution_name']] }.map do |identity, school_rows|
      counts = school_rows.group_by { |row| row['eligibility_status'] }
      {
        'institution_code' => identity[0], 'institution_name' => identity[1],
        'total_records' => school_rows.length, 'eligible_records' => counts.fetch('eligible', []).length,
        'ineligible_records' => counts.fetch('ineligible', []).length,
        'review_required_records' => counts.fetch('review_required', []).length
      }
    end
    rule_counts = rows.group_by { |row| row['subject_requirements_raw'] }.map do |rule, rule_rows|
      { rule: rule, count: rule_rows.length, status: rule_rows.first['eligibility_status'] }
    end
    stamp = Time.now.utc
    relative_directory = "data/derived/subject-requirements-#{stamp.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}"
    directory = local_path(relative_directory)
    raise 'Refusing to overwrite an existing import' if File.exist?(directory)
    parent = File.dirname(directory)
    FileUtils.mkdir_p(parent)
    summary = {
      source_id: SOURCE_ID, source_path: entry.fetch('path'), source_sha256: entry.fetch('sha256'),
      generated_at: stamp.iso8601, applicable_region: '辽宁', applicable_from_year: 2027,
      selected_subjects: selected, total_records: rows.length, eligible_records: eligible.length,
      ineligible_records: rows.count { |row| row['eligibility_status'] == 'ineligible' },
      review_required_records: rows.count { |row| row['eligibility_status'] == 'review_required' },
      institutions: schools.length, eligible_institutions: schools.count { |school| school['eligible_records'] > 0 },
      rule_counts: rule_counts, level_counts: rows.group_by { |row| row['level'] }.transform_values(&:length),
      versions: { ruby: RUBY_VERSION, roo: Roo::VERSION },
      limitations: ['仅核查选科要求，不核查批次、艺体或其他资格', '不是2028招生计划或正式志愿代码表', '条目可能是专业类或试验班，不等于独立专业数量', '未作跨校区或跨项目合并，不提供录取概率']
    }
    files = []
    staging = Dir.mktmpdir('subject-import-', parent)
    begin
      write_csv(File.join(staging, 'all.csv'), FIELDS, rows)
      write_csv(File.join(staging, 'eligible.csv'), FIELDS, eligible)
      write_csv(File.join(staging, 'institutions.csv'), schools.first.keys, schools)
      File.write(File.join(staging, 'summary.json'), JSON.pretty_generate(summary) + "\n")
      files = %w[all.csv eligible.csv institutions.csv summary.json].map do |name|
        { path: "#{relative_directory}/#{name}", sha256: Digest::SHA256.file(File.join(staging, name)).hexdigest }
      end
      FileUtils.mv(staging, directory)
    ensure
      FileUtils.remove_entry(staging) if File.directory?(staging)
    end
    manifest = summary.reject { |key, _value| %i[rule_counts level_counts versions limitations].include?(key) }.merge(files: files)
    File.open(File.join(parent, 'manifest.jsonl'), 'a') { |file| file.puts(JSON.generate(manifest)) }
    puts JSON.pretty_generate(summary.reject { |key, _value| key == :rule_counts })
    puts "Output: #{relative_directory}"
    summary
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    SubjectRequirements.run(ARGV)
  rescue StandardError => error
    warn error.message
    exit 1
  end
end